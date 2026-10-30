#!/usr/bin/env python3
"""Summarise a pulled audio debug log (see Learn2Sing/Sources/Debug/AudioDebugLog.swift).

    python3 Tools/AudioDebugLog/summarize_audio_logs.py DIR             one line per run
    python3 Tools/AudioDebugLog/summarize_audio_logs.py DIR --run 12    run 12's lines, in time order
    python3 Tools/AudioDebugLog/summarize_audio_logs.py DIR --launches  each launch's build and settings

DIR is a folder pulled by pull_audio_logs.sh (or the AudioDebugLog folder itself).
A run is marked LATE? when its recognised microphone delay sits more than 100 ms
above the median of the runs on the same microphone and speaker: through Bluetooth
earphones, a run heard late shows up as the singer following the sound.
"""
import argparse
import pathlib
import re
import statistics
import sys
from collections import defaultdict

LINE = re.compile(r"^(\S+ \S+) m=(\S+) \[(?:R(\d+) ([+-][\d.]+)|L(\d+))\] (\S+)(?: (.*))?$")
FIELD = re.compile(r'([A-Za-z][\w.]*)=("(?:[^"\\]|\\.)*"|\S*)')


def fields(text):
    out = {}
    for key, value in FIELD.findall(text or ""):
        if value.startswith('"'):
            value = value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        out[key] = value
    return out


def read_lines(folder):
    logs = sorted(folder.glob("audio-*.log")) + [folder / "audio.log"]
    lines = []
    for path in logs:
        if not path.exists():
            continue
        for raw in path.read_text(errors="replace").splitlines():
            m = LINE.match(raw)
            if not m:
                continue
            wall, mach, run, offset, launch, name, rest = m.groups()
            lines.append({
                "wall": wall, "mach": float(mach), "run": int(run) if run else None,
                "t": float(offset) if offset else None, "launch": int(launch) if launch else None,
                "name": name, "text": rest or "", "raw": raw,
            })
    return lines


def output_of(route):
    m = re.search(r"out: (\S+)", route or "")
    return m.group(1) if m else "?"


def summarise(lines, folder):
    runs = defaultdict(list)
    for line in lines:
        if line["name"] == "FLAG":
            # A flag names its run, which it can be logged after.
            m = re.search(r"target=R(\d+)", line["text"])
            if m:
                runs[int(m.group(1))].append(line)
        elif line["run"] is not None:
            runs[line["run"]].append(line)

    rows = []
    for number in sorted(runs):
        entries = sorted(runs[number], key=lambda l: l["mach"])
        row = {"run": number, "flags": [], "notes": defaultdict(int)}
        for e in entries:
            f = fields(e["text"])
            name = e["name"]
            if name == "run.open":
                row.update(wall=e["wall"][:16], exercise=f.get("exercise"), mode=f.get("mode"), bpm=f.get("bpm"),
                           instrument=f.get("instrument"))
            elif name == "run.routeSettled":
                row["out"] = output_of(f.get("route"))
                row["outLat"] = f.get("outLat")
            elif name == "route.wait.end" and f.get("waiting") == "1" and "wait" not in row:
                row["wait"] = f"{float(f.get('ms', 0)):.0f}ms" + ("" if f.get("arrived") == "1" else "(TIMEOUT)")
            elif name == "render.first":
                row["firstRender"] = e["t"]
            elif name == "mic.engine.start" and "mic" not in row:
                row["mic"] = e["t"] if f.get("ok") == "1" else "FAILED"
            elif name == "run.delay":
                row["delay"] = f.get("delayMs")
                row["best"] = f.get("bestMs")
                row["devices"] = f.get("devices")
            elif name == "run.score":
                row["score"] = f.get("score")
            elif name == "FLAG":
                row["flags"].append(f.get("kind"))
            elif name == "run.close":
                row["reason"] = f.get("reason")
                for key in ("renderGaps", "overruns", "nonFiniteBuffers", "catchUps", "timeJumps",
                            "micGaps", "drawHitches", "droppedRows"):
                    if f.get(key, "0") not in ("0", ""):
                        row["notes"][key] += int(float(f[key]))
                for item in (f.get("events") or "").split(","):
                    if ":" in item:
                        key, count = item.rsplit(":", 1)
                        if key in ("engine.configChange", "session.routeChange", "session.interruption",
                                   "main.hang", "main.stuck", "player.engine.restart", "mic.fallbackToTap",
                                   "route.reapply", "session.mediaServicesReset", "app.background"):
                            row["notes"][key.split(".", 1)[1]] += int(count)
        rows.append(row)

    # Late runs, judged against the other runs on the same devices.
    by_devices = defaultdict(list)
    for row in rows:
        try:
            by_devices[row.get("devices")].append(float(row["delay"]))
        except (KeyError, TypeError, ValueError):
            pass
    for row in rows:
        delays = by_devices.get(row.get("devices"), [])
        try:
            if len(delays) >= 3 and float(row["delay"]) - statistics.median(delays) > 100:
                row["late"] = True
        except (KeyError, TypeError, ValueError):
            pass

    for row in rows:
        parts = [f"R{row['run']:<4}", row.get("wall", "?"), f"{row.get('exercise')!s:24.24}",
                 f"{row.get('mode', '?')}", f"out={row.get('out', '?')}", f"lat={row.get('outLat', '?')}",
                 f"wait={row.get('wait', '?')}"]
        if "firstRender" in row:
            parts.append(f"render@{row['firstRender']:+.2f}")
        if "mic" in row:
            parts.append(f"mic@{row['mic']:+.2f}" if isinstance(row["mic"], float) else "mic=FAILED")
        if "score" in row:
            parts.append(f"score={row['score']}")
        if "delay" in row:
            parts.append(f"delay={row['delay']}ms")
        parts.append(f"[{row.get('reason', 'open')}]")
        if row.get("late"):
            parts.append("LATE?")
        if row["flags"]:
            parts.append("FLAGS=" + ",".join(row["flags"]))
        if row["notes"]:
            parts.append(" ".join(f"{k}={v}" for k, v in sorted(row["notes"].items())))
        print("  ".join(parts))

    flags = folder / "flags.log"
    if flags.exists() and flags.read_text().strip():
        print("\nflags.log:")
        print(flags.read_text().rstrip())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("folder")
    parser.add_argument("--run", type=int)
    parser.add_argument("--launches", action="store_true")
    args = parser.parse_args()
    folder = pathlib.Path(args.folder)
    if (folder / "AudioDebugLog").is_dir():
        folder = folder / "AudioDebugLog"
    lines = read_lines(folder)
    if not lines:
        sys.exit(f"no audio.log in {folder}")
    if args.run is not None:
        mine = [l for l in lines if l["run"] == args.run
                or (l["name"] == "FLAG" and f"target=R{args.run} " in l["text"] + " ")]
        for line in sorted(mine, key=lambda l: l["mach"]):
            print(line["raw"])
    elif args.launches:
        for line in lines:
            if line["name"].startswith(("====", "launch.")):
                print(line["raw"])
    else:
        summarise(lines, folder)


if __name__ == "__main__":
    main()
