"""Metrics for a real-time pitch track against a ground truth.

A track is (t_avail, midi): each output becomes visible at t_avail (seconds of file time)
and stays until the next one. NaN = nothing shown.
"""
import numpy as np

GRID = 0.002


def held(t_avail, midi, end, delivery=0.001):
    g = np.arange(GRID / 2, end, GRID)
    idx = np.searchsorted(t_avail + delivery, g, side="right") - 1
    v = np.where(idx >= 0, midi[np.clip(idx, 0, None)], np.nan)
    return g, v


def gt_on(gt_t, gt_m, times):
    """Nearest GT value at `times` (NaN outside)."""
    idx = np.searchsorted(gt_t, times)
    idx = np.clip(idx, 1, len(gt_t) - 1)
    left = gt_t[idx - 1]; right = gt_t[idx]
    use = np.where(np.abs(times - left) <= np.abs(right - times), idx - 1, idx)
    out = gt_m[use].copy()
    step = np.median(np.diff(gt_t))
    out[(times < gt_t[0] - step) | (times > gt_t[-1] + step)] = np.nan
    return out


def window_any(mask, w):
    """True where `mask` is true anywhere within ±w grid points."""
    if w <= 0: return mask.copy()
    c = np.concatenate([[0], np.cumsum(mask.astype(np.int64))])
    n = len(mask)
    i = np.arange(n)
    lo = np.clip(i - w, 0, n); hi = np.clip(i + w + 1, 0, n)
    return (c[hi] - c[lo]) > 0


def window_min_dist(y, ref, w):
    """min over j in [i-w, i+w] of |y[i] - ref[j]| (NaN-aware), via shifts."""
    best = np.full(len(y), np.inf)
    for s in range(-w, w + 1):
        r = np.roll(ref, s)
        if s > 0: r[:s] = np.nan
        elif s < 0: r[s:] = np.nan
        d = np.abs(y - r)
        d[np.isnan(d)] = np.inf
        best = np.minimum(best, d)
    return best


def stable_mask(p, w, tol=0.3):
    ok = ~np.isnan(p)
    res = ok.copy()
    for s in range(-w, w + 1):
        r = np.roll(p, s)
        if s > 0: r[:s] = np.nan
        elif s < 0: r[s:] = np.nan
        res &= ~np.isnan(r) & (np.abs(r - p) <= tol)
    return res


def best_lag(g, y, gt_t, gt_m, lags=np.arange(0, 0.2005, 0.002)):
    vo = ~np.isnan(y)
    best = (np.inf, 0.0)
    for L in lags:
        r = gt_on(gt_t, gt_m, g - L)
        both = vo & ~np.isnan(r)
        if both.sum() < 50: continue
        e = np.mean(np.minimum(np.abs(y[both] - r[both]), 1))
        if e < best[0]: best = (e, L)
    return best[1]


def runs(mask):
    """(start, end) index pairs of true runs."""
    if not mask.any(): return []
    d = np.diff(np.concatenate([[0], mask.astype(np.int8), [0]]))
    return list(zip(np.where(d == 1)[0], np.where(d == -1)[0]))


def count_events(mask, merge=5):
    rs = runs(mask)
    n = 0; last_end = -10**9
    for s, e in rs:
        if s - last_end > merge: n += 1
        last_end = e
    return n


def evaluate(t_avail, midi, gt_t, gt_m, lag=None, notes=None, texts=None, loose=None):
    end = min(t_avail[-1], gt_t[-1]) if len(t_avail) else 0
    g, y = held(t_avail, midi, end)
    if lag is None:
        lag = best_lag(g, y, gt_t, gt_m)
    p = gt_on(gt_t, gt_m, g - lag)
    pl = gt_on(gt_t, loose, g - lag) if loose is not None else p
    V = ~np.isnan(p)
    O = ~np.isnan(y)
    w30 = int(0.03 / GRID); w40 = int(0.04 / GRID)
    S = stable_mask(p, w30)
    NV = window_any(V | ~np.isnan(pl), w40)
    near = np.minimum(window_min_dist(y, p, w30), window_min_dist(y, pl, w30))
    m = {}
    m["lag"] = lag * 1000
    voiced_min = V.sum() * GRID / 60
    m["voiced_s"] = V.sum() * GRID
    m["recall50"] = np.mean(O[V] & (np.abs(y[V] - p[V]) <= 0.5)) if V.any() else np.nan
    m["recallS"] = np.mean(O[S]) if S.any() else np.nan
    m["vr"] = np.mean(O[V]) if V.any() else np.nan
    ov = O & NV
    outl = ov & (near > 1)
    spur = O & ~NV
    m["outl_pct"] = 100 * outl.sum() / max(1, O.sum())
    m["gross_pct"] = 100 * (ov & (near > 3)).sum() / max(1, O.sum())
    m["spur_pct"] = 100 * spur.sum() / max(1, O.sum())
    m["spur_ev"] = count_events(spur)
    m["spur_pm"] = m["spur_ev"] / max(1e-9, voiced_min)
    m["gross_ev"] = count_events(ov & (near > 3))
    m["gross_pm"] = m["gross_ev"] / max(1e-9, voiced_min)
    bad = outl | spur
    m["glitch_ev"] = count_events(bad)
    m["glitch_pm"] = m["glitch_ev"] / max(1e-9, voiced_min)
    so = S & O
    err = np.abs(y[so] - p[so]) * 100
    m["med_c"] = np.median(err) if len(err) else np.nan
    m["p95_c"] = np.percentile(err, 95) if len(err) else np.nan
    # jumps of more than a semitone between 10 ms samples that the truth doesn't make
    k = 5
    y10 = y[::k]; p10 = p[::k]
    dy = np.abs(np.diff(y10)); dp = np.abs(np.diff(p10))
    jump = (dy > 1) & ~(dp > 0.5)
    m["jumps_ev"] = int(np.nansum(jump))
    m["jumps_pm"] = m["jumps_ev"] / max(1e-9, voiced_min)
    # fragmentation: voiced stretches the line breaks into, per stretch the truth has
    m["runs_out"] = len(runs(O)); m["runs_gt"] = len(runs(V))
    m.update(onset_and_steps(g, y, gt_t, gt_m))
    if notes is not None:
        m.update(intended(g, y, lag, gt_t, gt_m, notes, texts))
    return m


def onset_and_steps(g, y, gt_t, gt_m):
    """Delay (from the sound) before a new note shows, and before a note change shows."""
    step = np.median(np.diff(gt_t))
    V = ~np.isnan(gt_m)
    quiet = int(round(0.06 / step)); hold = int(round(0.08 / step))
    delays = []
    k = quiet
    while k < len(gt_m) - hold:
        if V[k] and not V[k - 1] and not V[k - quiet:k].any() and V[k:k + hold].all():
            t_on = gt_t[k]
            i0 = np.searchsorted(g, t_on - 0.03)
            i1 = np.searchsorted(g, t_on + 0.3)
            for i in range(i0, i1):
                if not np.isnan(y[i]):
                    r = gt_on(gt_t, gt_m, np.array([max(t_on, g[i] - 0.02)]))[0]
                    if not np.isnan(r) and abs(y[i] - r) <= 1:
                        delays.append((g[i] - t_on) * 1000); break
            k += hold
        else:
            k += 1
    st = stable_mask(gt_m, max(1, int(round(0.03 / step))))
    plats = []
    k = 0
    while k < len(gt_m):
        if st[k]:
            e = k
            while e + 1 < len(gt_m) and st[e + 1] and abs(gt_m[e + 1] - gt_m[k]) < 0.5: e += 1
            if (e - k) * step >= 0.01: plats.append((k, e, gt_m[(k + e) // 2]))
            k = e + 1
        else:
            k += 1
    sd = []
    for a, b in zip(plats, plats[1:]):
        if (b[0] - a[1]) * step > 0.2 or abs(b[2] - a[2]) < 1.5: continue
        if np.isnan(gt_m[a[1]:b[0] + 1]).any(): continue
        mid = (a[2] + b[2]) / 2; up = b[2] > a[2]
        kc = a[1]
        while kc < b[0] and ((gt_m[kc] < mid) if up else (gt_m[kc] > mid)): kc += 1
        t_ref = gt_t[kc]
        i0 = np.searchsorted(g, t_ref - 0.03); i1 = np.searchsorted(g, t_ref + 0.3)
        for i in range(i0, i1):
            v = y[i]
            if not np.isnan(v) and ((v >= mid) if up else (v <= mid)) and abs(v - b[2]) < 3:
                sd.append((g[i] - t_ref) * 1000); break
    return dict(onset_med=np.median(delays) if delays else np.nan, onset_p90=np.percentile(delays, 90) if delays else np.nan,
                n_onsets=len(delays), step_med=np.median(sd) if sd else np.nan, step_p90=np.percentile(sd, 90) if sd else np.nan,
                n_steps=len(sd))


def singing_offset(gt_t, gt_m, notes):
    """How late the singer sings against the notes (s), by where the reference sits on them best."""
    best = (-1, 0.0)
    for off in np.arange(-0.1, 0.301, 0.01):
        hit = tot = 0
        for pitch, a, b in notes:
            sel = (gt_t >= a + off) & (gt_t < b + off)
            v = gt_m[sel]; v = v[~np.isnan(v)]
            tot += len(v); hit += np.sum(np.abs(v - pitch) <= 1)
        if tot and hit / tot > best[0]: best = (hit / tot, off)
    return best[1]


def sung_pitches(gt_t, gt_m, notes, off):
    """The pitch the singer settled on for each note: the reference's median over its middle."""
    sung = []
    for pitch, a, b in notes:
        L = b - a
        sel = (gt_t >= a + off + 0.3 * L) & (gt_t < b + off - 0.15 * L)
        v = gt_m[sel]; v = v[~np.isnan(v)]
        sung.append(np.median(v) if len(v) >= 5 else np.nan)
    return sung


def intended(g, y, lag, gt_t, gt_m, notes, texts):
    """Output that leaves the pitch the singer settled on for the notes around it by more than
    a semitone ('off-note'), the share of those near a sung syllable's start ('cons', where
    its consonant is), and how much of each note's settled middle the line covers."""
    off = singing_offset(gt_t, gt_m, notes)
    sung = sung_pitches(gt_t, gt_m, notes, off)
    ts = g - lag - off     # sound time of each output point, in note time
    lo = np.full(len(g), np.inf); hi = np.full(len(g), -np.inf)
    covered = np.zeros(len(g), bool)
    for (pitch, a, b), s in zip(notes, sung):
        if np.isnan(s): continue
        i0 = np.searchsorted(ts, a - 0.06); i1 = np.searchsorted(ts, b + 0.06)
        lo[i0:i1] = np.minimum(lo[i0:i1], s - 1)
        hi[i0:i1] = np.maximum(hi[i0:i1], s + 1)
        covered[i0:i1] = True
    O = ~np.isnan(y)
    judged = O & covered
    off_note = judged & ((y < lo) | (y > hi))
    res = {"offnote_pct": 100 * off_note.sum() / max(1, judged.sum()), "offnote_ev": count_events(off_note)}
    minutes = covered.sum() * GRID / 60
    res["offnote_pm"] = res["offnote_ev"] / max(1e-9, minutes)
    if texts:
        near = np.zeros(len(g), bool)
        for _, t in texts:
            i0 = np.searchsorted(ts, t - 0.1); i1 = np.searchsorted(ts, t + 0.1)
            near[i0:i1] = True
        res["cons_ev"] = count_events(off_note & near)
        res["cons_pm"] = res["cons_ev"] / max(1e-9, minutes)
    good = tot = 0
    for (pitch, a, b), s in zip(notes, sung):
        if np.isnan(s): continue
        L = b - a
        i0 = np.searchsorted(ts, a + 0.3 * L); i1 = np.searchsorted(ts, b - 0.15 * L)
        seg = y[i0:i1]
        tot += len(seg); good += np.sum(np.abs(seg - s) <= 0.5)
    res["notecov"] = 100 * good / max(1, tot)
    return res
