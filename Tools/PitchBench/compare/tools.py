"""Smaller helpers.

  tools.py fast <tag>=<ENV:val;ENV:val> ...    run the bench's exp analyzer with those settings
  tools.py bytech <detectors>                  VocalSet split by singing technique
  tools.py perfile <detectors> <name filter> [sets]
  tools.py plot <item prefix> <t0> <t1> <detectors> <out.png>
  tools.py classify <detector> <sets>          off-note events by where they sit in a syllable
"""
import sys, os, subprocess
import numpy as np
from concurrent.futures import ProcessPoolExecutor
import data, run, metrics, la


def fast(specs):
    for spec in specs:
        tag, envs = spec.split("=", 1)
        env = dict(os.environ)
        for kv in envs.split(";"):
            if kv: k, v = kv.split(":"); env[k] = v
        det = "exp-" + tag
        run.swift(det, 480, la.SETS, force=True, env=env)
        syn = subprocess.run([run.BENCH, "synth", "exp", "480"], env=dict(env, QUIET="1"), capture_output=True, text=True).stdout.strip()
        print(la.compact(det), flush=True)
        print("    ", syn.replace("SYNTH MEAN", "synth"), flush=True)


def tech(n):
    for k in ("breathy", "vocal_fry", "belt", "vibrato", "fast_forte", "caro", "row", "dona"):
        if k in n: return k
    return "?"


def bytech(dets):
    its = run.items_for(["vocalset"])
    for det in dets:
        with ProcessPoolExecutor(run.PROCS) as ex:
            rows = [r for r in ex.map(run._eval_one, [(i, det, None) for i in its]) if r]
        groups = {}
        for r in rows: groups.setdefault(tech(r["name"]), []).append(r)
        line = f"{det:14s}"
        for k in sorted(groups):
            s = run.summarize(groups[k])
            line += f" {k[:6]} recS {100*s['recallS']:5.1f} p95 {s['p95_c']:5.1f} gr {s['gross_pm']:5.1f} sp {s['spur_pm']:5.1f} |"
        print(line)


def perfile(dets, key, sets):
    its = [i for i in run.items_for(sets) if key in i["name"]]
    res = {}
    for d in dets:
        with ProcessPoolExecutor(run.PROCS) as ex:
            res[d] = {r["name"]: r for r in ex.map(run._eval_one, [(i, d, None) for i in its]) if r}
    for it in its:
        line = f"{it['name'][:30]:30s}"
        for d in dets:
            r = res[d].get(it["name"])
            if r: line += f" | {d[:10]:10s} gr {r['gross_ev']:3d} sp {r['spur_ev']:3d} p95 {r['p95_c']:6.1f} off {r.get('offnote_ev', 0):3d}"
        print(line)


def plot(name, t0, t1, dets, out):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import soundfile as sf
    from scipy.signal import stft
    it = [i for i in run.items_for(la.SETS) if i["name"].startswith(name)][0]
    x, sr = sf.read(it["wav"], dtype="float32", always_2d=True)
    x = x[:, 0]
    t1 = min(t1, len(x) / sr)
    a, b = int(t0 * sr), int(t1 * sr)
    f, t, Z = stft(x[a:b], sr, nperseg=4096, noverlap=4096 - 240)
    S = 20 * np.log10(np.abs(Z) + 1e-7)
    fm = f > 20; mid = 69 + 12 * np.log2(f[fm] / 440); keep = (mid > 30) & (mid < 96)
    fig, ax = plt.subplots(figsize=(22, 9))
    ax.pcolormesh(t + t0, mid[keep], S[fm][keep], shading="auto", cmap="Greys", vmin=S.max() - 60, vmax=S.max())
    sel = (it["gt_t"] >= t0) & (it["gt_t"] <= t1)
    ax.plot(it["gt_t"][sel], it["gt_midi"][sel], ".", color="lime", ms=4, label="truth / reference")
    if "notes" in it:
        off = metrics.singing_offset(it["gt_t"], it["gt_midi"], it["notes"])
        sung = metrics.sung_pitches(it["gt_t"], it["gt_midi"], it["notes"], off)
        for (pitch, a_, b_), s in zip(it["notes"], sung):
            if b_ + off < t0 or a_ + off > t1 or np.isnan(s): continue
            ax.fill_between([a_ + off - 0.06, b_ + off + 0.06], s - 1, s + 1, color="gold", alpha=0.15)
            ax.plot([a_ + off, b_ + off], [s, s], color="gold", lw=2)
        for tx, tt in it["texts"]:
            if t0 <= tt + off <= t1: ax.text(tt + off, 90, tx)
    cols = ["red", "blue", "magenta", "cyan", "orange", "brown"]
    for c, d in zip(cols, dets):
        # "name@ms" draws the track that much earlier, to line it up with the voice
        name, shift = (d.split("@")[0], float(d.split("@")[1]) / 1000) if "@" in d else (d, 0.0)
        try: tt, mm = data.load_track(it, name)
        except FileNotFoundError: continue
        tt = tt - shift
        s = (tt >= t0) & (tt <= t1)
        ax.step(tt[s], mm[s], where="post", color=c, lw=1.4, label=d)
    lo_, hi_ = (float(v) for v in os.environ.get("YLIM", "30,96").split(","))
    ax.set_xlim(t0, t1); ax.set_ylim(lo_, hi_); ax.legend(); ax.set_title(it["name"])
    fig.tight_layout(); fig.savefig(out, dpi=60); print(out)


def classify(det, sets):
    from collections import Counter
    cnt = Counter()
    for it in run.items_for(sets):
        t, m = data.load_track(it, det)
        g, y = metrics.held(t, m, min(t[-1], it["gt_t"][-1]))
        lag = metrics.best_lag(g, y, it["gt_t"], it["gt_midi"])
        gt_t, gt_m, notes = it["gt_t"], it["gt_midi"], it["notes"]
        off = metrics.singing_offset(gt_t, gt_m, notes)
        sung = metrics.sung_pitches(gt_t, gt_m, notes, off)
        ts = g - lag - off
        lo = np.full(len(g), np.inf); hi = np.full(len(g), -np.inf); cov = np.zeros(len(g), bool)
        for (pitch, a, b), s in zip(notes, sung):
            if np.isnan(s): continue
            i0 = np.searchsorted(ts, a - 0.06); i1 = np.searchsorted(ts, b + 0.06)
            lo[i0:i1] = np.minimum(lo[i0:i1], s - 1); hi[i0:i1] = np.maximum(hi[i0:i1], s + 1); cov[i0:i1] = True
        O = ~np.isnan(y)
        bad = O & cov & ((y < lo) | (y > hi))
        p = metrics.gt_on(gt_t, gt_m, g - lag)
        vr = metrics.runs(~np.isnan(p))
        runid = np.full(len(g), -1)
        for k, (s, e) in enumerate(vr): runid[s:e] = k
        for s, e in metrics.runs(bad):
            c = (s + e) // 2
            if runid[c] < 0: pos = "gap"
            else:
                rs, re = vr[runid[c]]
                pos = "onset" if (c - rs) * 0.002 < 0.1 else "tail" if (re - c) * 0.002 < 0.1 else "mid"
            dev = np.nanmedian(np.where(y[s:e] > hi[s:e], y[s:e] - hi[s:e], lo[s:e] - y[s:e]))
            dk = "<0.5" if dev < 0.5 else "<1" if dev < 1 else "<3" if dev < 3 else ">3"
            dur = (e - s) * 2
            dd = "<20ms" if dur < 20 else "<50ms" if dur < 50 else "<100ms" if dur < 100 else ">100ms"
            cnt[(pos, dk, dd)] += 1
    tot = sum(cnt.values())
    for k, v in sorted(cnt.items(), key=lambda kv: -kv[1]): print(f"{v:5d} {100*v/tot:5.1f}%  {k}")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "fast": fast(sys.argv[2:])
    elif cmd == "bytech": bytech(sys.argv[2].split(","))
    elif cmd == "perfile": perfile(sys.argv[2].split(","), sys.argv[3], sys.argv[4].split(",") if len(sys.argv) > 4 else ["vocalset"])
    elif cmd == "plot": plot(sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), sys.argv[5].split(","), sys.argv[6])
    elif cmd == "classify": classify(sys.argv[2], sys.argv[3].split(","))
