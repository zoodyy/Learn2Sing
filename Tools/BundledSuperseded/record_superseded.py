#!/usr/bin/env python3
"""Record the earlier version of every bundled exercise the working tree changes.

An install keeps its own copy of each bundled exercise, so a change to
BundledExercises.json only reaches new installs. On the others, the old copy
would count as edited by its user (`ExerciseStore.isBundledEdited`), be rated
under an id of its own and get its difficulty seeded from that device.
`ExerciseStore.updateSupersededBundled` fixes that: a copy that is exactly an
earlier shipped version (its category aside) is replaced with the current one.
It knows the earlier versions from SupersededBundledExercises.json, which this
script appends to.

Run it after editing BundledExercises.json, before committing:

    python3 Tools/BundledSuperseded/record_superseded.py          # against HEAD
    python3 Tools/BundledSuperseded/record_superseded.py <rev>    # against <rev>

It compares the bundle at <rev> with the working tree, ignoring note and label
ids and order the way the app does, and appends one entry holding the old
version of each exercise that differs (settings, notes, ghost notes or labels).
New and removed exercises are left out: there is nothing to bring up to date.
Versions already recorded aren't added twice. The file is only ever added to.
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = "Learn2Sing/Bundled/BundledExercises.json"
SUPERSEDED = ROOT / "Learn2Sing/Bundled/SupersededBundledExercises.json"


def notes_content(notes):
    return tuple(sorted((n["pitch"], n["beat"], n["length"]) for n in notes or []))


def texts_content(texts):
    return tuple(sorted((t["beat"], t["pitch"], t["text"]) for t in texts or []))


def version(bundle, exercise):
    """What an exercise is, as the app compares it."""
    key = exercise["id"].upper()
    settings = {k: v for k, v in exercise.items() if k != "category"}
    return (json.dumps(settings, sort_keys=True),
            notes_content(bundle["midi"].get(key)),
            notes_content((bundle.get("ghosts") or {}).get(key)),
            texts_content((bundle.get("texts") or {}).get(key)))


def main():
    rev = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
    old = json.loads(subprocess.run(["git", "show", f"{rev}:{BUNDLE}"], cwd=ROOT,
                                    capture_output=True, text=True, check=True).stdout)
    new = json.loads((ROOT / BUNDLE).read_text())
    recorded = json.loads(SUPERSEDED.read_text()) if SUPERSEDED.exists() else []

    known = {(e["id"], version(b, e)) for b in recorded for e in b["exercises"]}
    current = {e["id"]: e for e in new["exercises"]}
    changed = [e for e in old["exercises"]
               if e["id"] in current
               and version(old, e) != version(new, current[e["id"]])
               and (e["id"], version(old, e)) not in known]
    if not changed:
        print("Nothing to record.")
        return

    keys = {e["id"].upper() for e in changed}
    recorded.append({
        "exercises": changed,
        "midi": {k: v for k, v in old["midi"].items() if k in keys},
        "texts": {k: v for k, v in (old.get("texts") or {}).items() if k in keys},
        "ghosts": {k: v for k, v in (old.get("ghosts") or {}).items() if k in keys},
    })
    SUPERSEDED.write_text(json.dumps(recorded, separators=(",", ":"), ensure_ascii=False))
    print(f"Recorded the {rev} version of {len(changed)} exercise(s):")
    for e in changed:
        print(f"  {e['name']}")


if __name__ == "__main__":
    main()
