#!/usr/bin/env python3
"""Seed a difficulty for every Community exercise the server has none for.

The app estimates a user's exercise when it is made or edited
(`CommunitySync.seedDifficulty`). An exercise made before that existed, and
never edited since, was shared without one, so its intro screen shows no stars
until somebody sings it through. This gives those exercises the estimate the
app would have posted.

For each live SHARED_EXERCISE record whose `event-average` is empty it:

  1. rates the shared pattern with the app's own `ExerciseDifficulty` (the same
     rater seed_bundled.py builds);
  2. checks the average once more, and leaves the exercise alone if a real
     score has landed since the list was read;
  3. posts the expected score from each of the three seed ids;
  4. reads the average back, which with no other rows must be the estimate.

Nothing is deleted. An exercise without an average has no rows to clear, and
re-posting the same value from a seed id leaves its row as it was, so a post
that failed can be retried.

Usage:
    python3 seed_community.py           # list the unrated exercises and their estimates
    python3 seed_community.py --post    # and seed them
"""

import argparse
import concurrent.futures as futures
import json
import pathlib
import sys
import tempfile

from seed_bundled import SEED_USERS, average, request, run_rater

PAGE_SIZE = 50


def fetch_shared() -> list[dict]:
    """Every live shared exercise: its uploader's name and the shared document.

    Pages until an empty page, since a short page can have more behind it."""
    records, page = {}, 0
    while True:
        status, body = request("GET", "fetch-public/SHARED_EXERCISE",
                               {"sortBy": "CREATED_AT", "sortDirection": "ASC",
                                "page": page, "pageSize": PAGE_SIZE})
        if status != 200:
            sys.exit(f"fetch-public page {page}: {status} {body[:200]}")
        batch = json.loads(body)
        if not batch:
            break
        for record in batch:
            if record.get("storageType") == "SHARED_EXERCISE":
                records[record["entityId"]] = record
        page += 1

    shared = []
    for record in records.values():
        try:
            doc = json.loads(record["jsonData"])
        except (KeyError, ValueError):
            continue
        if not doc.get("exercise"):
            continue  # a tombstone
        name = record.get("customName1")
        if name == record.get("customId1"):
            name = None  # the server echoes the id when the uploader has no name
        shared.append({"public_id": doc["exercise"]["id"].lower(),
                       "uploader": name, "doc": doc})
    return shared


def rate(shared: list[dict]) -> None:
    """Puts the app's rating and score on each entry, where it has one."""
    bundle = {"exercises": [s["doc"]["exercise"] for s in shared],
              "midi": {s["public_id"].upper(): s["doc"].get("midi") or [] for s in shared}}
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / "community.json"
        path.write_text(json.dumps(bundle))
        rows = {row["id"].lower(): row for row in run_rater(path)}
    for s in shared:
        row = rows[s["public_id"]]
        s["name"] = row["name"]
        s["rating"] = row.get("rating")
        s["score"] = row.get("score")


def seed(s: dict) -> dict:
    pid = s["public_id"]
    if average(pid) is not None:
        return dict(s, final=None, problems=["rated meanwhile, left alone"])
    posted = []
    for user in SEED_USERS:
        for _ in range(3):
            if request("POST", f"user-event/{user}/{pid}/ADD_PLAY",
                       {"customValue": s["score"]})[0] == 200:
                posted.append(user)
                break
    final = average(pid)
    problems = []
    if len(posted) < len(SEED_USERS):
        problems.append(f"only {len(posted)} of {len(SEED_USERS)} posts went through")
    if final is None:
        problems.append("no average after posting")
    elif abs(final - s["score"]) > 0.01:
        problems.append(f"average {final} is not the estimate {s['score']}")
    return dict(s, final=final, problems=problems)


def fmt(value) -> str:
    return "-" if value is None else f"{value:.1f}"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--post", action="store_true", help="post the estimates")
    args = parser.parse_args()

    shared = fetch_shared()
    with futures.ThreadPoolExecutor(max_workers=4) as pool:
        averages = list(pool.map(lambda s: average(s["public_id"]), shared))
    unrated = [s for s, avg in zip(shared, averages) if avg is None]
    print(f"{len(shared)} live shared exercises, {len(unrated)} without a difficulty.\n")
    if not unrated:
        return
    rate(unrated)
    for s in unrated:
        if s["rating"] is None:
            print(f"{s['name']:32} by {s['uploader'] or '(no name)':14} nothing to rate, skipped")
    ratable = [s for s in unrated if s["rating"] is not None]

    if not args.post:
        for s in ratable:
            print(f"{s['name']:32} by {s['uploader'] or '(no name)':14} rating {s['rating']:3d} "
                  f"({s['rating'] / 20:.2f} stars)  score {s['score']:3d}")
        print("\nNothing posted; run with --post to seed.")
        return

    with futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(seed, ratable))
    failed = 0
    for r in results:
        status = "  !! " + "; ".join(r["problems"]) if r["problems"] else ""
        failed += bool(r["problems"])
        print(f"{r['name']:32} by {r['uploader'] or '(no name)':14} rating {r['rating']:3d}  "
              f"posted {r['score']:3d}  server {fmt(r['final'])}{status}")
    print(f"\n{len(results) - failed}/{len(results)} seeded cleanly.")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
