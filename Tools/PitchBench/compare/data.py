"""Datasets for comparing pitch trackers, all as 48 kHz mono WAVs with a ground truth.

Every item: name, dataset, wav (48 kHz mono path), gt_t (s), gt_midi (NaN = unvoiced),
gt_kind ('human' annotations, 'ref' = the bench's look-ahead reference track).
The user's exported recordings also carry their notes and sung syllables.

Public sets (downloaded into .work/external by fetch.py, converted by prep_*):
  vocadito  40 solo excerpts, 7 languages, hand-labelled f0 (CC BY 4.0)
  mir1k     224 karaoke clips of 19 amateur singers, hand-labelled pitch
  vocalset  160 takes of 20 trained singers (arpeggios in belt, breathy, vocal fry,
            vibrato; fast scales; three song excerpts with lyrics) (CC BY 4.0);
            ground truth = the reference track
"""
import os, json, glob
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.environ.get("PITCHBENCH_WORK", os.path.join(os.path.dirname(HERE), ".work"))
EXT = WORK + "/external"
E48 = WORK + "/ext48"
PROBLEMATIC = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(HERE))), "Debug", "Problematic")
SR = 48000


def hz2midi(f):
    f = np.asarray(f, dtype=float)
    out = np.full(f.shape, np.nan)
    ok = f > 0
    out[ok] = 69 + 12 * np.log2(f[ok] / 440)
    return out


def to48(x, sr):
    if sr == SR:
        return x.astype(np.float32)
    from math import gcd
    g = gcd(int(sr), SR)
    return resample_poly(x, SR // g, int(sr) // g).astype(np.float32)


def load_ref(path, step=96):
    ref = np.fromfile(path, dtype=np.float32).reshape(-1, 4)
    t = (np.arange(len(ref)) * step + step / 2) / SR
    return t, ref[:, 0].astype(float)


def user_items():
    items = []
    for d in sorted(glob.glob(WORK + "/Learn2Sing-*")):
        j = json.load(open(d + "/recording.json"))
        t, m = load_ref(d + "/ref.bin")
        _, loose = load_ref(d + "/ref_loose.bin")
        seg = j["audio"]["segments"][0]["beat"]
        bpm = j["exercise"]["bpm"]
        b2t = lambda b: (b - seg) * 60 / bpm
        notes = [(n["pitch"], b2t(n["beat"]), b2t(n["beat"] + n["length"])) for n in j["notes"]]
        texts = [(tx["text"], b2t(tx["beat"])) for tx in j.get("texts", [])]
        problem = os.path.exists(os.path.join(PROBLEMATIC, os.path.basename(d) + ".zip"))
        items.append(dict(name=os.path.basename(d)[11:], dataset="user" + ("-problem" if problem else ""), wav=d + "/microphone.wav",
                          dir=d, gt_t=t, gt_midi=m, gt_loose=loose, gt_kind="ref", notes=notes, texts=texts))
    return items


def prep_vocadito():
    os.makedirs(E48 + "/vocadito", exist_ok=True)
    items = []
    for w in sorted(glob.glob(EXT + "/Audio/vocadito_*.wav"), key=lambda p: int(p.split("_")[-1][:-4])):
        stem = os.path.basename(w)[:-4]
        out = f"{E48}/vocadito/{stem}.wav"
        if not os.path.exists(out):
            x, sr = sf.read(w, dtype="float32", always_2d=True)
            sf.write(out, to48(x[:, 0], sr), SR, subtype="FLOAT")
        gt = np.loadtxt(f"{EXT}/Annotations/F0/{stem}_f0.csv", delimiter=",")
        items.append(dict(name=stem, dataset="vocadito", wav=out, gt_t=gt[:, 0], gt_midi=hz2midi(gt[:, 1]), gt_kind="human"))
    return items


def prep_mir1k():
    os.makedirs(E48 + "/mir1k", exist_ok=True)
    items = []
    for w in sorted(glob.glob(EXT + "/mir1k/*.wav")):
        stem = os.path.basename(w)[:-4]
        pv = w[:-4] + ".pv"
        if not os.path.exists(pv):
            continue
        out = f"{E48}/mir1k/{stem}.wav"
        if not os.path.exists(out):
            x, sr = sf.read(w, dtype="float32", always_2d=True)
            sf.write(out, to48(x[:, 1], sr), SR, subtype="FLOAT")   # right channel: the voice alone
        lab = np.atleast_1d(np.loadtxt(pv))
        m = np.where(lab > 0, lab, np.nan)
        # 40 ms frames every 20 ms, the first centred at 20 ms.
        t = np.arange(len(m)) * 0.02 + 0.02
        items.append(dict(name=stem, dataset="mir1k", wav=out, gt_t=t, gt_midi=m, gt_kind="human"))
    return items


def prep_vocalset():
    os.makedirs(E48 + "/vocalset", exist_ok=True)
    items = []
    for w in sorted(glob.glob(EXT + "/vocalset/*.wav")):
        stem = os.path.basename(w)[:-4]
        out = f"{E48}/vocalset/{stem}.wav"
        if not os.path.exists(out):
            x, sr = sf.read(w, dtype="float32", always_2d=True)
            sf.write(out, to48(x[:, 0], sr), SR, subtype="FLOAT")
        ref = f"{E48}/vocalset/{stem}.ref.bin"
        item = dict(name=stem, dataset="vocalset", wav=out, gt_kind="ref", refbin=ref)
        if os.path.exists(ref):
            item["gt_t"], item["gt_midi"] = load_ref(ref)
        items.append(item)
    return items


def all_items(which=("user", "vocadito", "mir1k", "vocalset")):
    out = []
    if "user" in which: out += user_items()
    if "vocadito" in which: out += prep_vocadito()
    if "mir1k" in which: out += prep_mir1k()
    if "vocalset" in which: out += prep_vocalset()
    return out


def track_path(item, det):
    if item["dataset"].startswith("user"):
        return item["dir"] + f"/track_{det}.bin"
    return item["wav"][:-4] + f".{det}.bin"


def load_track(item, det):
    a = np.fromfile(track_path(item, det), dtype=np.float32).reshape(-1, 2)
    return a[:, 0].astype(float), a[:, 1].astype(float)


def save_track(item, det, t, m):
    a = np.stack([np.asarray(t, np.float32), np.asarray(m, np.float32)], axis=1)
    a.tofile(track_path(item, det))
