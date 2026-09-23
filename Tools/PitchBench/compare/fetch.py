"""Download the public singing datasets the comparison uses, convert them to 48 kHz mono,
scale them to the level the user's phone records at, and compute reference tracks where
there are no hand labels. Everything lands in .work (git-ignored). About 420 MB of
downloads, a few minutes.

  vocadito  (CC BY 4.0) all 40 excerpts, 58 MB zip          zenodo.org/records/5578807
  VocalSet  (CC BY 4.0) 160 of its 3613 takes, read out of the 2 GB zip with HTTP range
            requests: per singer the three straight song excerpts and one arpeggio each in
            belt, breathy, vocal fry and vibrato, plus a fast scale       zenodo.org/records/1442513
  MIR-1K    up to 12 clips per singer (224), the voice channel and the pitch labels,
            also by range requests out of the 1 GB zip        mirlab.org/dataset/public/MIR-1K.zip

  fetch.py [vocadito] [vocalset] [mir1k]      (default: all three)
"""
import os, sys, re, json, zipfile, io, collections, urllib.request
import numpy as np
import soundfile as sf
import data, metrics, run

VOCADITO = "https://zenodo.org/api/records/5578807/files/vocadito.zip/content"
VOCALSET = "https://zenodo.org/api/records/1442513/files/VocalSet11.zip/content"
MIR1K = "http://mirlab.org/dataset/public/MIR-1K.zip"


def fetch_vocadito():
    if os.path.exists(data.EXT + "/vocadito_metadata.csv"): return
    os.makedirs(data.EXT, exist_ok=True)
    with urllib.request.urlopen(VOCADITO) as r:
        zipfile.ZipFile(io.BytesIO(r.read())).extractall(data.EXT)


def fetch_vocalset():
    from remotezip import RemoteZip
    os.makedirs(data.EXT + "/vocalset", exist_ok=True)
    with RemoteZip(VOCALSET) as z:
        for info in z.infolist():
            n = info.filename
            if not n.endswith(".wav") or "__MACOSX" in n: continue
            parts = n.split("/"); kind = parts[2] + "/" + parts[3]; f = parts[-1]
            keep = (kind == "excerpts/straight"
                    or (kind in ("arpeggios/breathy", "arpeggios/vocal_fry", "arpeggios/belt", "arpeggios/vibrato") and f.endswith("_a.wav"))
                    or (kind == "scales/fast_forte" and re.search(r"_c_fast_forte_a\.wav$", f)))
            out = data.EXT + "/vocalset/" + f
            if keep and not os.path.exists(out):
                open(out, "wb").write(z.read(n))


def fetch_mir1k():
    from remotezip import RemoteZip
    os.makedirs(data.EXT + "/mir1k", exist_ok=True)
    with RemoteZip(MIR1K) as z:
        wavs = sorted(i.filename for i in z.infolist() if i.filename.startswith("MIR-1K/Wavfile/") and i.filename.endswith(".wav"))
        by = collections.defaultdict(list)
        for w in wavs: by[w.split("/")[-1].split("_")[0]].append(w)
        for singer, ws in by.items():
            for w in ws[::max(1, len(ws) // 12)][:12]:
                stem = w.split("/")[-1][:-4]
                for src, dst in ((w, f"{stem}.wav"), (f"MIR-1K/PitchLabel/{stem}.pv", f"{stem}.pv")):
                    if not os.path.exists(data.EXT + "/mir1k/" + dst):
                        open(data.EXT + "/mir1k/" + dst, "wb").write(z.read(src))


def normalize():
    """Median 10 ms RMS over voiced frames -> 0.1, what the user's phone recordings sit at
    (their silence gate is an absolute level, so a dataset recorded 20 dB quieter would
    look like breath). VocalSet is scaled per singer from their straight song excerpts,
    so breathy and fry stay as much softer as the singer made them."""
    done_path = os.path.join(data.E48, "normalized.json")
    done = json.load(open(done_path)) if os.path.exists(done_path) else {}
    items = [i for i in data.all_items(("vocadito", "mir1k", "vocalset")) if i["name"] not in done and "gt_t" in i]

    def voiced_level(it):
        x, _ = sf.read(it["wav"], dtype="float32")
        n = len(x) // 480
        r = np.sqrt(np.mean(x[:n * 480].reshape(n, 480) ** 2, axis=1))
        v = ~np.isnan(metrics.gt_on(it["gt_t"], it["gt_midi"], (np.arange(n) + 0.5) * 0.01))
        return np.median(r[v]) if v.sum() > 20 else np.nan

    singer = collections.defaultdict(list)
    levels = {it["name"]: voiced_level(it) for it in items}
    for it in items:
        if it["dataset"] == "vocalset" and "straight" in it["name"]:
            singer[it["name"].split("_")[0]].append(levels[it["name"]])
    for it in items:
        ref = np.nanmedian(singer[it["name"].split("_")[0]]) if it["dataset"] == "vocalset" else levels[it["name"]]
        if not np.isfinite(ref) or ref <= 0: continue
        gain = 0.1 / ref
        x, sr = sf.read(it["wav"], dtype="float32")
        sf.write(it["wav"], np.clip(x * gain, -1, 1), sr, subtype="FLOAT")
        done[it["name"]] = float(gain)
        # A reference worked out before the scaling goes; `refs` redoes it on the new level.
        if "refbin" in it and os.path.exists(it["refbin"]): os.remove(it["refbin"])
    json.dump(done, open(done_path, "w"))


if __name__ == "__main__":
    which = sys.argv[1:] or ["vocadito", "vocalset", "mir1k"]
    if "vocadito" in which: fetch_vocadito()
    if "vocalset" in which: fetch_vocalset()
    if "mir1k" in which: fetch_mir1k()
    data.all_items(tuple(which))           # converts to 48 kHz
    run.refs(["vocalset"])                 # VocalSet has no labels: the reference is its truth
    normalize()
    run.refs(["vocalset"])                 # again, at the level the detectors will hear
    print("ready:", {k: len(run.items_for([k])) for k in which})
