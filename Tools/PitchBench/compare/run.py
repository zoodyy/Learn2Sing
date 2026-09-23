"""Runs detectors over the datasets and scores them.

  run.py swift <detector> <bufferFrames> <sets> [force]   Swift detectors via pitchbench runlist
  run.py refs <sets>                                      reference tracks where there are no labels
  run.py frames <sets>                                    per-analysis features of the exp analyzer
  run.py eval <detectors> <sets> [files]

<sets> is a comma list of user, user-problem, vocadito, mir1k, vocalset.
Parallelism is PROCS (default 4): the machine this was built on went down under 16 busy
processes, so it stays modest.
"""
import sys, os, subprocess
import numpy as np
from concurrent.futures import ProcessPoolExecutor
import data, metrics

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.join(os.path.dirname(HERE), ".build", "pitchbench")
LISTS = os.path.join(data.WORK, "lists")
PROCS = int(os.environ.get("PROCS", "4"))


def items_for(sets):
    it = data.all_items(tuple(s for s in ("user", "vocadito", "mir1k", "vocalset") if any(x.startswith(s) for x in sets)))
    return [i for i in it if any(i["dataset"].startswith(s) for s in sets)]


def _list(name, lines):
    os.makedirs(LISTS, exist_ok=True)
    path = os.path.join(LISTS, name)
    open(path, "w").write("\n".join(lines))
    return path


def swift(det, hop, sets, force=False, env=None):
    its = items_for(sets)
    lines = [f"{i['wav']}\t{data.track_path(i, det)}" for i in its if force or not os.path.exists(data.track_path(i, det))]
    if not lines: return
    subprocess.run([BENCH, "runlist", det, str(hop), _list(f"{det}.txt", lines)], check=True, env=env)


def refs(sets):
    its = items_for(sets)
    lines = [f"{i['wav']}\t{i['refbin']}" for i in its if "refbin" in i]
    subprocess.run([BENCH, "reflist", _list("ref.txt", lines)], check=True)


def frames(sets, hop=480, env=None, tag="frames"):
    its = items_for(sets)
    lines = [f"{i['wav']}\t{data.track_path(i, tag)}" for i in its]
    subprocess.run([BENCH, "frames", str(hop), _list("frames.txt", lines)], check=True, env=env)


def load_frames(item, tag="frames"):
    a = np.fromfile(data.track_path(item, tag), dtype=np.float32).reshape(-1, 7)
    return dict(t=a[:, 0].astype(float), level=a[:, 1], midi=a[:, 2].astype(float), clarity=a[:, 3], long=a[:, 4],
                shown=a[:, 5].astype(float), window=a[:, 6])


def _eval_one(args):
    item, det, lag = args
    try:
        t, m = data.load_track(item, det)
    except FileNotFoundError:
        return None
    if "gt_t" not in item or len(t) < 10: return None
    r = metrics.evaluate(t, m, item["gt_t"], item["gt_midi"], lag=lag, notes=item.get("notes"), texts=item.get("texts"),
                         loose=item.get("gt_loose"))
    r["name"] = item["name"]; r["dataset"] = item["dataset"]
    return r


def _lag_one(args):
    item, det = args
    try:
        t, m = data.load_track(item, det)
    except FileNotFoundError:
        return None
    if "gt_t" not in item or len(t) < 10: return None
    end = min(t[-1], item["gt_t"][-1])
    g, y = metrics.held(t, m, end)
    return item["dataset"], metrics.best_lag(g, y, item["gt_t"], item["gt_midi"])


KEYS = ["lag", "onset_med", "onset_p90", "step_med", "step_p90", "med_c", "p95_c", "recall50", "recallS", "outl_pct", "gross_pct",
        "spur_pct", "spur_pm", "gross_pm", "glitch_pm", "jumps_pm", "offnote_pct", "offnote_pm", "cons_pm", "notecov"]


def summarize(rows):
    """Events are summed and divided by the voiced minutes; delays are medians over files;
    everything else is weighted by each file's voiced time."""
    out = {}
    w = np.array([r["voiced_s"] for r in rows])
    mins = w.sum() / 60
    for k in KEYS:
        vals = np.array([r.get(k, np.nan) for r in rows], dtype=float)
        ok = ~np.isnan(vals)
        if not ok.any(): continue
        if k.endswith("_pm"):
            evs = np.array([r.get(k.replace("_pm", "_ev"), 0) for r in rows], dtype=float)
            out[k] = evs.sum() / mins
        elif k in ("onset_med", "onset_p90", "step_med", "step_p90", "lag"):
            out[k] = np.nanmedian(vals)
        else:
            out[k] = np.average(vals[ok], weights=w[ok])
    out["frag"] = sum(r["runs_out"] for r in rows) / max(1, sum(r["runs_gt"] for r in rows))
    out["files"] = len(rows); out["minutes"] = mins
    return out


def evaluate(det, sets, per_file=False, fixed_lag=None):
    """Each dataset is scored at the detector's median best lag over its files."""
    its = items_for(sets)
    with ProcessPoolExecutor(PROCS) as ex:
        lags = [x for x in ex.map(_lag_one, [(i, det) for i in its], chunksize=4) if x]
    by = {}
    for ds, L in lags: by.setdefault(ds, []).append(L)
    med = {ds: float(np.median(v)) for ds, v in by.items()}
    with ProcessPoolExecutor(PROCS) as ex:
        rows = [r for r in ex.map(_eval_one, [(i, det, fixed_lag if fixed_lag is not None else med.get(i["dataset"])) for i in its],
                                  chunksize=4) if r]
    res = {}
    for ds in sorted(set(r["dataset"] for r in rows)):
        rs = [r for r in rows if r["dataset"] == ds]
        res[ds] = summarize(rs)
        if per_file:
            for r in rs: print(fmt(det + " " + r["name"][:28], r))
    return res


def fmt(label, s):
    def f(k, spec):
        v = s.get(k, np.nan)
        return format(v, spec) if not (isinstance(v, float) and np.isnan(v)) else " " * len(format(0.0, spec))
    return (f"{label:38s} lag{f('lag','5.1f')} on{f('onset_med','5.1f')}/{f('onset_p90','5.1f')} st{f('step_med','5.1f')}/{f('step_p90','5.1f')}"
            f" c{f('med_c','4.1f')}/{f('p95_c','5.1f')} rec{f('recall50','6.2%')} recS{f('recallS','6.2%')} gross/m{f('gross_pm','5.1f')} spur/m{f('spur_pm','5.1f')}"
            f" jump/m{f('jumps_pm','5.1f')} off/m{f('offnote_pm','5.1f')} cons/m{f('cons_pm','5.1f')} cov{f('notecov','6.2f')}")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "swift":
        swift(sys.argv[2], int(sys.argv[3]), sys.argv[4].split(","), force="force" in sys.argv)
    elif cmd == "refs":
        refs(sys.argv[2].split(","))
    elif cmd == "frames":
        frames(sys.argv[2].split(","))
    elif cmd == "eval":
        sets = sys.argv[3].split(",")
        for det in sys.argv[2].split(","):
            res = evaluate(det, sets, per_file="files" in sys.argv)
            for ds, s in res.items():
                print(fmt(f"{det} [{ds} {s['files']}f {s['minutes']:.1f}m]", s))
