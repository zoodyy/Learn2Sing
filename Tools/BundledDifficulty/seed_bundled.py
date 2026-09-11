#!/usr/bin/env python3
"""Seed the community difficulty of every bundled exercise.

The app estimates a difficulty for every exercise a user makes and posts it as
three plays from fixed ids (`CommunitySync.seedDifficulty`), but it leaves the
bundled exercises out: their ids are the same on every install, so a user's
edited copy would be posting its edit's difficulty as everyone's. This is the
out-of-band equivalent for the bundled library. Run it whenever the bundle
changes.

For each exercise in BundledExercises.json it:

  1. rates it with the app's own `ExerciseDifficulty`, compiled straight from
     the app's sources together with Rater/Shim.swift (see the note there on
     keeping the shim in step);
  2. deletes the ADD_PLAY rows of every seed id on it, so the value posted
     replaces the old estimate instead of blending into it (the server keeps a
     running mean per user);
  3. posts the expected score from each of the three seed ids;
  4. reads the average back, before step 3 and after it.

Real singers' rows are never touched: `delete-events` is scoped to one user.
The read-back between steps 2 and 3 is the average of the sung scores alone,
which is what the final average is checked against: with no sung scores it must
equal the estimate exactly, otherwise it must sit between the two, and the
script prints how many singers' rows that works out to.

Usage:
    python3 seed_bundled.py           # rate, compare with the server, post nothing
    python3 seed_bundled.py --post    # rate and seed
"""

import argparse
import concurrent.futures as futures
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
APP = HERE.parents[1] / "Learn2Sing"
BUNDLE = APP / "Bundled" / "BundledExercises.json"
BASE = "https://echolex.api.phrase-by-phrase.com/api/v1/learn2Sing"

# PublicIdentifier's namespace: the server knows an exercise by the v5 UUID of
# its raw id, never the raw id itself.
NAMESPACE = "6C7E2A9B-4F13-5D8A-B0E6-1A2C3D4E5F60"

# CommunitySync.seedUserIDs, the three ids an estimate is posted as. Not
# 1111…: the server silently drops everything posted from that id.
SEED_USERS = [
    "22222222-2222-2222-2222-222222222222",
    "33333333-3333-3333-3333-333333333333",
    "44444444-4444-4444-4444-444444444444",
]
# Also posted from by the hand seeding of 2026-09-06, before the app settled on
# three. Their rows are cleared and never rewritten, so every bundled exercise
# carries the same three votes as any other seeded exercise.
RETIRED_SEED_USERS = [
    "55555555-5555-5555-5555-555555555555",
    "66666666-6666-6666-6666-666666666666",
]


def derived(name: str) -> str:
    """PublicIdentifier.exerciseID: the v5 UUID of `name`, lowercase."""
    namespace = bytes.fromhex(NAMESPACE.replace("-", ""))
    digest = bytearray(hashlib.sha1(namespace + name.lower().encode()).digest()[:16])
    digest[6] = (digest[6] & 0x0F) | 0x50
    digest[8] = (digest[8] & 0x3F) | 0x80
    b = bytes(digest)
    return f"{b[:4].hex()}-{b[4:6].hex()}-{b[6:8].hex()}-{b[8:10].hex()}-{b[10:].hex()}"


def request(method: str, path: str, params: dict | None = None):
    url = f"{BASE}/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace")
    except Exception as error:  # noqa: BLE001 - reported per exercise
        return 0, str(error)


def average(public_id: str) -> float | None:
    """The server's difficulty (average score), or None for an unrated exercise."""
    status, body = request("GET", f"event-average/{public_id}/EXERCISE_DIFFICULTY")
    if status != 200:
        raise RuntimeError(f"event-average {public_id}: {status} {body[:200]}")
    return json.loads(body).get("calculatedValue")


def rate() -> list[dict]:
    """Every bundled exercise's rating, from the app's own code."""
    sources = [
        HERE / "Rater" / "main.swift",
        HERE / "Rater" / "Shim.swift",
        APP / "Sources" / "Exercises" / "ExerciseDifficulty.swift",
        APP / "Sources" / "Exercises" / "ExerciseTimeline.swift",
    ]
    with tempfile.TemporaryDirectory() as tmp:
        rater = pathlib.Path(tmp) / "rater"
        subprocess.run(["swiftc", "-o", str(rater), *map(str, sources)], check=True)
        out = subprocess.run([str(rater), "rate", str(BUNDLE)],
                             capture_output=True, text=True, check=True).stdout
    rows = [json.loads(line) for line in out.splitlines()]
    for row in rows:
        row["public_id"] = derived(row["id"])
    unrated = [row["name"] for row in rows if "rating" not in row]
    if unrated:
        sys.exit(f"no rating for {unrated} (no notes, or no tempo)")
    return rows


def seed(row: dict) -> dict:
    pid = row["public_id"]
    cleared = [request("DELETE", f"delete-events/{user}/{pid}/ADD_PLAY")[0] == 200
               for user in SEED_USERS + RETIRED_SEED_USERS]
    sung = average(pid)
    posted = [request("POST", f"user-event/{user}/{pid}/ADD_PLAY",
                      {"customValue": row["score"]})[0] == 200
              for user in SEED_USERS]
    final = average(pid)

    problems = []
    if not all(cleared):
        problems.append("a delete failed")
    if not all(posted):
        problems.append("a post failed")
    singers = None
    if final is None:
        problems.append("no average after posting")
    elif sung is None:
        if abs(final - row["score"]) > 0.01:
            problems.append(f"average {final} is not the estimate {row['score']}")
    elif abs(final - sung) > 1e-9:
        # final = (singers * sung + 3 * score) / (singers + 3)
        singers = len(SEED_USERS) * (row["score"] - final) / (final - sung)
        if singers < 0.5 or abs(singers - round(singers)) > 0.05:
            problems.append(f"average {final} doesn't fit 3 seed votes beside {sung}")
    return dict(row, sung=sung, final=final, singers=singers, problems=problems)


def fmt(value) -> str:
    return "-" if value is None else f"{value:.1f}"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--post", action="store_true", help="delete the old seed rows and post the new ones")
    args = parser.parse_args()

    rows = rate()
    with futures.ThreadPoolExecutor(max_workers=4) as pool:
        if not args.post:
            for row, avg in zip(rows, pool.map(lambda r: average(r["public_id"]), rows)):
                print(f"{row['name']:32} {row['category']:12} rating {row['rating']:3d} "
                      f"({row['rating'] / 20:.2f} stars)  score {row['score']:3d}  server now {fmt(avg)}")
            print("\nNothing posted; run with --post to seed.")
            return
        results = list(pool.map(seed, rows))

    failed = 0
    for r in results:
        singers = "" if r["singers"] is None else f"  beside {round(r['singers'])} singer(s) at {fmt(r['sung'])}"
        status = "  !! " + "; ".join(r["problems"]) if r["problems"] else ""
        failed += bool(r["problems"])
        print(f"{r['name']:32} rating {r['rating']:3d}  posted {r['score']:3d}  "
              f"server {fmt(r['final'])}{singers}{status}")
    print(f"\n{len(results) - failed}/{len(results)} seeded cleanly.")
    if failed:
        print("A rerun is safe: every seed row is deleted before it is written.")
        sys.exit(1)


if __name__ == "__main__":
    main()
