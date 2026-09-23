"""Prototype of a look-ahead stage on top of the analyzer's per-analysis frames.

The frame shown when analysis i arrives is j = i - K: everything up to i is known.

  la.py sweep name='{"K":16,...}' ...      build each variant's tracks and print a summary
"""
import sys, json
import numpy as np
from concurrent.futures import ProcessPoolExecutor
import data, run, metrics

HOP = 0.005


def weighted_median_windows(vals, wts, lo, hi):
    """For each j: weighted median of vals[lo[j]:hi[j]] (weights wts)."""
    n = len(vals)
    out = np.full(n, np.nan)
    for j in range(n):
        a, b = lo[j], hi[j]
        v = vals[a:b]; w = wts[a:b]
        ok = ~np.isnan(v)
        v = v[ok]; w = w[ok]
        if len(v) == 0: continue
        if len(v) == 1: out[j] = v[0]; continue
        o = np.argsort(v)
        cw = np.cumsum(w[o])
        k = np.searchsorted(cw, cw[-1] / 2)
        out[j] = v[o[min(k, len(v) - 1)]]
    return out


def smooth(fr, P):
    t = fr["t"]; lvl = fr["level"].astype(float)
    val = fr["shown"].copy()
    K = P["K"]
    n = len(t)
    raw = fr["midi"]; clar = fr["clarity"]
    if P.get("backfill"):
        # a run the fast path confirmed at c: the analyses just before it that already
        # heard the same note join it, as far back as the look-ahead reaches
        for s0_, e0_ in metrics.runs(~np.isnan(val)):
            b = s0_ - 1
            while b >= max(0, s0_ - min(K, P["backfill"])) and not np.isnan(raw[b]) and clar[b] >= 0.4 \
                    and abs(raw[b] - val[s0_]) <= 1.5:
                val[b] = raw[b]; b -= 1
    if P.get("gapfill"):
        # a dropout of at most `gapfill` analyses between two stretches of the same note
        G = min(K, P["gapfill"])
        rr = metrics.runs(~np.isnan(val))
        for (a1, b1), (a2, b2) in zip(rr, rr[1:]):
            if a2 - b1 <= G and abs(val[a2] - val[b1 - 1]) <= 1:
                val[b1:a2] = np.linspace(val[b1 - 1], val[a2], a2 - b1 + 2)[1:-1]
    V = ~np.isnan(val)
    out = np.full(n, np.nan)
    Wb, Wf = P.get("Wb", 0), min(P.get("Wf", 0), K)
    Rmin = P.get("Rmin", 0)
    gate = P.get("gate", 0.0)
    s0 = P.get("s0", 0.0)
    pw = P.get("pw", 0.0)
    for s, e in metrics.runs(V):
        L = e - s
        v = val[s:e]; lv = lvl[s:e]
        idx = np.arange(L)
        known_end = np.minimum(idx + K + 1, L)       # frames of the run known when j is shown
        if Rmin and L < Rmin and L <= K + 1:
            continue
        pb = P.get("peakwin", 0)
        if pb:
            # the loudest the note has been lately: the last `peakwin` analyses and the look-ahead
            from numpy.lib.stride_tricks import sliding_window_view
            padded = np.concatenate([np.full(pb, -np.inf), lv, np.full(K, -np.inf)])
            peak = sliding_window_view(padded, pb + K + 1).max(axis=1)[:L]
            peak = np.maximum(peak, 1e-9)
        else:
            peak = np.maximum.accumulate(lv)[known_end - 1]
        show = lv >= gate * peak if gate > 0 else np.ones(L, bool)
        if P.get("tailgate", 0) > 0:
            ends_soon = (L - idx) <= K + 1
            show &= ~(ends_soon & (lv < P["tailgate"] * peak))
        if Wb or Wf:
            # Only what is known when frame idx is shown: frames up to known_end - 1. The slope
            # is a central difference where both neighbours are known, one-sided at the edges.
            def slope_at(k, last):
                a, b = max(k - 1, 0), min(k + 1, last)
                return abs(v[b] - v[a]) / (b - a) if b > a else np.inf
            vs = np.full(L, np.nan)
            for j in range(L):
                last = known_end[j] - 1
                a, b = max(0, j - Wb), min(known_end[j], j + Wf + 1)
                ks = np.arange(a, b)
                w = np.ones(len(ks))
                if s0 > 0: w *= np.exp(-(np.array([slope_at(k, last) for k in ks]) / s0) ** 2) + 1e-3
                if pw > 0: w *= lv[ks] ** pw
                vv = v[ks]
                o = np.argsort(vv, kind="stable")
                cw = np.cumsum(w[o])
                vs[j] = vv[o[min(np.searchsorted(cw, cw[-1] / 2), len(vv) - 1)]]
            slope = np.array([slope_at(k, known_end[k] - 1) for k in range(L)])
            d = P.get("clamp", 0.0)
            if d > 0:
                dd = np.full(L, d)
                if "clamp_edge" in P:
                    E = P.get("edge", 12)
                    near_start = idx < E
                    near_end = ((L - idx) <= E) & ((L - idx) <= K)    # the end is known by then
                    dd[near_start | near_end] = P["clamp_edge"]
                vs = vs + np.clip(v - vs, -dd, dd)
        else:
            vs = v
        if P.get("edge_hide"):
            # near either end of the run (the far end only once it is known), a pitch still
            # sliding is the consonant pulling the voice, not the note: leave it out. The
            # slope is a least-squares fit over what is known around the analysis.
            E = P.get("hide_edge", 8)
            thr = P["edge_hide"]
            def fit_slope(a, b):
                x = np.arange(a, b); y = v[a:b]
                if len(x) < 3: return np.inf
                x = x - x.mean()
                return abs(np.dot(x, y - y.mean()) / np.dot(x, x))
            k0 = 0
            while k0 < min(E, L) and fit_slope(max(0, k0 - 2), min(known_end[k0], k0 + K + 1)) > thr: k0 += 1
            show[:k0] = False
            k1 = L
            while k1 > max(0, L - E) and (L - (k1 - 1)) <= K and fit_slope(max(0, k1 - 1 - K), min(L, k1 + 2)) > thr: k1 -= 1
            show[k1:] = False
        out[s:e] = np.where(show, vs, np.nan)
    # shown when analysis j + K arrives, and read once the 10 ms buffer holding it is processed
    ta = t + K * HOP
    ta = np.ceil(np.round(ta / 0.01, 3)) * 0.01     # (frame times are float32: 1.11 is 1.1100000143)
    return ta, out


def _job(args):
    item, P, name = args
    fr = run.load_frames(item, P.get("frames", "frames"))
    ta, m = smooth(fr, P)
    data.save_track(item, name, ta, m)
    return item["name"]


def make(name, P, sets):
    its = run.items_for(sets)
    with ProcessPoolExecutor(run.PROCS) as ex:
        list(ex.map(_job, [(i, P, name) for i in its], chunksize=4))


SETS = ["user", "vocadito", "mir1k", "vocalset"]


def compact(name):
    r = run.evaluate(name, SETS)
    u, p = r.get("user", {}), r.get("user-problem", {})
    g = lambda d, k, f=1: d.get(k, float("nan")) * f
    out = (f"{name:22s} lag {g(u,'lag'):5.1f} on {g(u,'onset_med'):5.1f} st {g(u,'step_med'):5.1f} | off/m {g(u,'offnote_pm'):5.1f} {g(p,'offnote_pm'):5.1f}"
           f" cons {g(p,'cons_pm'):5.1f} cov {g(u,'notecov'):5.1f} {g(p,'notecov'):5.1f} recS {g(u,'recallS',100):5.1f} p95 {g(u,'p95_c'):5.1f} fr {g(u,'frag'):4.2f} |")
    for k in ("vocadito", "mir1k", "vocalset"):
        d = r.get(k, {})
        out += f" {k[:4]} recS {g(d,'recallS',100):5.1f} p95 {g(d,'p95_c'):5.1f} gr {g(d,'gross_pm'):5.1f} sp {g(d,'spur_pm'):5.1f} fr {g(d,'frag'):4.2f} |"
    return out


if __name__ == "__main__" and sys.argv[1] == "sweep":
    for line in sys.argv[2:]:
        name, P = line.split("=", 1)
        make(name, json.loads(P), SETS)
        print(compact(name), flush=True)
elif __name__ == "__main__" and sys.argv[1] == "show":
    for name in sys.argv[2:]:
        print(compact(name), flush=True)
