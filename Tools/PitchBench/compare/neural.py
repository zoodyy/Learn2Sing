"""Neural pitch trackers on the same items, written as tracks the metrics understand.

  neural.py <kind> <sets>      kind: swiftf0-offline | swiftf0-la<N> | crepe-tiny | crepe-full | pesto-offline
  neural.py crepe-tracks <model> <periodicity threshold>

Every track is (t_avail, midi): when a value could first be on screen, given only the audio
up to then. "-offline" runs see the whole file: what the model can do with unlimited
look-ahead, not what a live line would show.

  SwiftF0 (MIT, 2025): 16 kHz, 16 ms frames; each frame needs 10 frames (160 ms) of future
    audio to be final. swiftf0-la<N> gives it N frames and zeros beyond, as a live stream
    with less look-ahead would.
  CREPE (MIT, 2018) via torchcrepe: 64 ms windows at 16 kHz, so a frame is known 32 ms
    after its centre; per-frame weighted argmax, as a live stream has to decode.
  PESTO (LGPL-3.0, so not shippable in the app; 2023/2025) via pesto-pitch: offline only,
    for its accuracy. Its streaming mode is a causal variable-Q transform whose kernels at
    men's low notes span ~70-110 ms.
Needs: pip install swift-f0 onnxruntime soxr (and torch torchcrepe for CREPE).
"""
import sys, os
import numpy as np
import soundfile as sf
import soxr
import multiprocessing as mp
import data


def load16(item):
    x, sr = sf.read(item["wav"], dtype="float32", always_2d=True)
    return soxr.resample(x[:, 0], sr, 16000).astype(np.float32)


_sf = None
def swiftf0_session():
    global _sf
    if _sf is None:
        from swift_f0 import SwiftF0
        _sf = SwiftF0(threads=1, spin=False)
    return _sf


def swiftf0_offline(item, thr=0.5):
    x = load16(item)
    pitch, conf = swiftf0_session()._run(x, 46.875, 2093.75)
    t = np.arange(len(pitch)) * 256 / 16000
    return t, np.where(conf >= thr, data.hz2midi(pitch), np.nan)


def swiftf0_stream(item, look_frames, thr=0.5, ctx_frames=24):
    det = swiftf0_session()
    x = load16(item)
    H = 256
    ts, ms = [], []
    for k in range(ctx_frames, len(x) // H + 1):
        pitch, conf = det._run(x[(k - ctx_frames) * H:k * H], 46.875, 2093.75)
        j = ctx_frames - look_frames
        if j < 0 or j >= len(pitch): continue
        ts.append(k * H / 16000)
        ms.append(data.hz2midi(pitch[j]) if conf[j] >= thr else np.nan)
    return np.array(ts), np.array(ms)


def crepe_raw(item, model):
    import torch, torchcrepe
    audio = torch.from_numpy(load16(item))[None]
    with torch.no_grad():
        pitch, per = torchcrepe.predict(audio, 16000, 160, 46.0, 2000.0, model, decoder=torchcrepe.decode.weighted_argmax,
                                        return_periodicity=True, batch_size=512, device="cpu", pad=True)
    t = np.arange(pitch.shape[1]) * 0.01
    np.save(data.track_path(item, f"crepe{model}raw")[:-4] + ".npy", np.stack([t, pitch[0].numpy(), per[0].numpy()]))


def pesto_offline(item):
    import torch, pesto
    x, sr = sf.read(item["wav"], dtype="float32", always_2d=True)
    t, semis, conf, _ = pesto.predict(torch.from_numpy(x[:, 0]), sr, step_size=10.0, convert_to_freq=False)
    t = t.numpy() / 1000 if float(t.max()) > 1000 else t.numpy()
    np.save(data.track_path(item, "pestoraw")[:-4] + ".npy", np.stack([t, semis.numpy(), conf.numpy()]))


def job(args):
    kind, item = args
    if kind == "swiftf0-offline":
        data.save_track(item, kind, *swiftf0_offline(item))
    elif kind.startswith("swiftf0-la"):
        data.save_track(item, kind, *swiftf0_stream(item, int(kind[10:])))
    elif kind.startswith("crepe-"):
        crepe_raw(item, kind.split("-")[1])
    elif kind == "pesto-offline":
        pesto_offline(item)
    return item["name"]


def crepe_tracks(model, thr):
    import run
    for it in run.items_for(["user", "vocadito", "mir1k", "vocalset"]):
        p = data.track_path(it, f"crepe{model}raw")[:-4] + ".npy"
        if not os.path.exists(p): continue
        t, f, c = np.load(p)
        data.save_track(it, f"crepe{model}@{thr}", t + 0.032, np.where(c >= thr, data.hz2midi(f), np.nan))


def pesto_tracks(thr):
    """Offline: frame times as PESTO labels them, which a live line could never meet."""
    import run
    for it in run.items_for(["user", "vocadito", "mir1k", "vocalset"]):
        p = data.track_path(it, "pestoraw")[:-4] + ".npy"
        if not os.path.exists(p): continue
        t, semis, c = np.load(p)
        data.save_track(it, f"pesto@{thr}", t, np.where(c >= thr, semis, np.nan))


if __name__ == "__main__":
    if sys.argv[1] == "crepe-tracks":
        crepe_tracks(sys.argv[2], float(sys.argv[3])); sys.exit()
    if sys.argv[1] == "pesto-tracks":
        pesto_tracks(float(sys.argv[2])); sys.exit()
    kind, sets = sys.argv[1], sys.argv[2].split(",")
    import run
    its = run.items_for(sets)
    procs = run.PROCS
    if kind.startswith("crepe") or kind.startswith("pesto"):
        import torch
        torch.set_num_threads(2)
        raw = f"crepe{kind.split('-')[1]}raw" if kind.startswith("crepe") else "pestoraw"
        its = [i for i in its if not os.path.exists(data.track_path(i, raw)[:-4] + ".npy")]
    with mp.get_context("fork").Pool(procs) as pool:
        for i, name in enumerate(pool.imap_unordered(job, [(kind, it) for it in its])):
            if i % 25 == 0: print(kind, i, "/", len(its), name, flush=True)
    print(kind, "done", flush=True)
