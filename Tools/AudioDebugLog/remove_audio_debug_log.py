#!/usr/bin/env python3
"""Remove the temporary audio debug log from the app.

Deletes Learn2Sing/Sources/Debug/AudioDebug*.swift and undoes every hook tagged
`AUDIO DEBUG LOG` in the other Swift sources:

  * a line ending in `// AUDIO DEBUG LOG` is deleted;
  * a block from `// AUDIO DEBUG LOG BEGIN` to `// AUDIO DEBUG LOG END` is deleted;
  * a line ending in `// AUDIO DEBUG LOG restore: <code>` becomes `<code>`, at the
    line's own indentation.

Then it deletes this folder (Tools/AudioDebugLog) unless --keep-tools is given.
Pulled logs under Debug/AudioLogs are left alone.

    python3 Tools/AudioDebugLog/remove_audio_debug_log.py [--root DIR] [--keep-tools] [--dry-run]

--root points it at another checkout (for checking it against a copy).
"""
import argparse
import pathlib
import re
import shutil
import sys

TAG = "// AUDIO DEBUG LOG"
BEGIN = re.compile(r"^\s*// AUDIO DEBUG LOG BEGIN\s*$")
END = re.compile(r"^\s*// AUDIO DEBUG LOG END\s*$")
RESTORE = re.compile(r"^(\s*).*?\s*// AUDIO DEBUG LOG restore: (.*)$")
LINE = re.compile(r"^.*\s*// AUDIO DEBUG LOG\s*$")


def strip(text, path):
    out = []
    lines = text.split("\n")
    i = 0
    removed = restored = 0
    while i < len(lines):
        line = lines[i]
        if BEGIN.match(line):
            j = i + 1
            while j < len(lines) and not END.match(lines[j]):
                j += 1
            if j == len(lines):
                sys.exit(f"{path}:{i + 1}: BEGIN without END")
            removed += j - i + 1
            i = j + 1
            # A block that stood between two blank lines leaves one, not two.
            if out and not out[-1].strip() and i < len(lines) and not lines[i].strip():
                i += 1
                removed += 1
            continue
        if END.match(line):
            sys.exit(f"{path}:{i + 1}: END without BEGIN")
        m = RESTORE.match(line)
        if m:
            out.append(m.group(1) + m.group(2).rstrip())
            restored += 1
        elif LINE.match(line):
            removed += 1
        else:
            out.append(line)
        i += 1
    return "\n".join(out), removed, restored


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parents[2]))
    parser.add_argument("--keep-tools", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = pathlib.Path(args.root).resolve()
    sources = root / "Learn2Sing"
    if not sources.is_dir():
        sys.exit(f"no Learn2Sing folder under {root}")

    for path in sorted((sources / "Sources" / "Debug").glob("AudioDebug*.swift")):
        print(f"delete  {path.relative_to(root)}")
        if not args.dry_run:
            path.unlink()

    for path in sorted(sources.rglob("*.swift")):
        if path.name.startswith("AudioDebug") and path.parent.name == "Debug":
            continue
        text = path.read_text()
        if TAG not in text:
            continue
        new, removed, restored = strip(text, path)
        print(f"edit    {path.relative_to(root)}: {removed} lines removed, {restored} restored")
        if not args.dry_run:
            path.write_text(new)

    leftovers = []
    for path in sorted(sources.rglob("*.swift")):
        if not path.exists():
            continue
        text = path.read_text()
        for number, line in enumerate(text.split("\n"), 1):
            if "AUDIO DEBUG LOG" in line or "AudioDebug" in line or "audioDebug" in line:
                leftovers.append(f"{path.relative_to(root)}:{number}: {line.strip()}")
    if leftovers and not args.dry_run:
        print("\nStill mentioned (remove by hand):")
        print("\n".join(leftovers))
        sys.exit(1)

    tools = root / "Tools" / "AudioDebugLog"
    if not args.keep_tools and not args.dry_run and tools.is_dir():
        print(f"delete  {tools.relative_to(root)}/")
        shutil.rmtree(tools)
    print("\nDone. Build the app to check, and delete the audio-debug-log memory note.")


if __name__ == "__main__":
    main()
