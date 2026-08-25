#!/usr/bin/env python3
"""Seed the Learn2Sing community backend with dummy public exercises.

Creates N fake accounts (PUBLIC_PROFILE documents) and spreads M dummy
SHARED_EXERCISE documents across them, then posts like/download/play user
events from a pool of throwaway user ids so each exercise ends up with a
random 0..10 of each.

Every id it writes is appended to manifest.json — the backend has no delete,
so that file is the only way to find these records again (a tombstone POST of
`{"userID": "..."}` under an exercise's id is what the app uses to unshare).

Usage:
    python3 seed.py --smoke          # 1 account, 1 exercise, then verify
    python3 seed.py --accounts 12 --exercises 80
    python3 seed.py ... --dry-run    # print what would be posted, send nothing
"""

import argparse
import concurrent.futures as futures
import hashlib
import json
import os
import random
import sys
import time
import urllib.parse
import urllib.request
import urllib.error

BASE = "https://echolex.api.phrase-by-phrase.com/api/v1/learn2Sing"
HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "manifest.json")

# The app's PublicIdentifier namespace. Deriving ids the same way keeps the
# seeded records shaped exactly like real ones (v5, lowercase, bare UUID).
NAMESPACE = "6C7E2A9B-4F13-5D8A-B0E6-1A2C3D4E5F60"


def derived(name: str) -> str:
    """RFC 4122 v5 UUID of `name` under the app namespace, lowercase."""
    ns = bytes.fromhex(NAMESPACE.replace("-", ""))
    h = bytearray(hashlib.sha1(ns + name.lower().encode()).digest()[:16])
    h[6] = (h[6] & 0x0F) | 0x50
    h[8] = (h[8] & 0x3F) | 0x80
    b = bytes(h)
    return f"{b[:4].hex()}-{b[4:6].hex()}-{b[6:8].hex()}-{b[8:10].hex()}-{b[10:].hex()}"


# ---------------------------------------------------------------- HTTP

def post(path: str, params: dict | None = None, body: dict | None = None,
         timeout: float = 30.0):
    url = f"{BASE}/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = None
    req = urllib.request.Request(url, method="POST")
    if body is not None:
        # Compact and key-sorted, like the app: the server rejects documents
        # past roughly 64 KB.
        data = json.dumps(body, separators=(",", ":"), sort_keys=True).encode()
        req.add_header("Content-Type", "application/json")
        req.data = data
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001 - network flake, reported to caller
        return 0, str(e)


def get(path: str, params: dict | None = None, timeout: float = 30.0):
    url = f"{BASE}/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        return 0, str(e)


# ---------------------------------------------------------------- content

USERNAMES = [
    "Mira Vocalis", "Tobias Lund", "Selin Aydar", "Rosa Delacroix",
    "Kenji Harada", "Nadia Brekke", "Oskar Vainio", "Lucia Marenzi",
    "Farah Nassar", "Ivo Petran", "Greta Solheim", "Diego Alcazar",
]

BLURBS = [
    "Choir director, twenty years in. I post the warm-ups my sopranos ask for.",
    "Bedroom singer working on breath support. Everything here is a work in progress.",
    "Voice teacher. Short drills, slow tempos, no shouting.",
    "Musical theatre student. Belting practice mostly.",
    "I sing bass and I collect descending scales.",
    "Recovering from vocal strain — gentle stuff only.",
    "Gospel background vocals. Riffs and runs.",
    "Just here to warm up before rehearsal.",
    "Classical baritone. Legato is the whole point.",
    "Learning to sing at 41. It is going fine, thanks for asking.",
    "Jazz vocalist. I like awkward intervals.",
    "Weekend a cappella. I write the drills nobody else wants to.",
]

CATEGORIES = ["Tone", "Scales", "Articulation", "Agility", "Range", ""]

ADJ = ["Morning", "Easy", "Slow", "Rolling", "Bright", "Low", "Open", "Quiet",
       "Steady", "Warm", "Narrow", "Wide", "Simple", "Long", "Short", "Round",
       "Gentle", "Firm", "Loose", "Clean"]
NOUN = ["Siren", "Ladder", "Arpeggio", "Hum", "Lip Roll", "Octave Jump",
        "Five Tone", "Triad Walk", "Vowel Swap", "Staccato Run", "Legato Line",
        "Descent", "Climb", "Sustain", "Skip", "Zigzag"]

DETAILS = [
    "Dummy exercise. Keep the jaw loose and don't push at the top.",
    "Dummy exercise. Breathe low, start quietly, stop if it aches.",
    "Dummy exercise. Same vowel all the way through.",
    "Dummy exercise. Slow first, then take the tempo up.",
    "Dummy exercise. Let the last note fade rather than cutting it.",
    "Dummy exercise. Placeholder text for testing the community feed.",
    "Dummy exercise. Try it in a couple of keys.",
    "Dummy exercise. Nothing clever going on here.",
]

SOLFEGE = ["Do", "Re", "Mi", "Fa", "Sol", "La", "Ti"]
VOWELS = ["Ah", "Ee", "Oh", "Oo", "Ay"]


def make_pattern(rng: random.Random, seed_key: str):
    """A short, musically plausible note list plus optional text labels."""
    root = rng.choice([45, 48, 50, 52, 55, 57, 60])
    shape = rng.choice(["scale", "arpeggio", "siren", "skips", "five"])
    if shape == "scale":
        steps = [0, 2, 4, 5, 7, 5, 4, 2, 0]
    elif shape == "arpeggio":
        steps = [0, 4, 7, 12, 7, 4, 0]
    elif shape == "siren":
        steps = [0, 5, 12, 5, 0]
    elif shape == "skips":
        steps = [0, 4, 2, 5, 4, 7, 5, 0]
    else:
        steps = [0, 2, 4, 5, 7, 5, 4, 2, 0]
        steps = steps[: rng.choice([5, 7, 9])]

    length = rng.choice([0.5, 1.0, 1.0, 2.0])
    notes, beat = [], 0.0
    for i, s in enumerate(steps):
        notes.append({
            "id": derived(f"{seed_key}-note-{i}"),
            "pitch": root + s,
            "beat": beat,
            "length": length,
        })
        beat += length

    texts = []
    if rng.random() < 0.45:
        words = SOLFEGE if rng.random() < 0.5 else VOWELS
        for i, n in enumerate(notes):
            texts.append({
                "id": derived(f"{seed_key}-text-{i}"),
                "text": words[i % len(words)],
                "pitch": n["pitch"] + 1,
                "beat": n["beat"] + 0.25,
            })
    return notes, texts


def make_exercise(rng: random.Random, public_id: str, name: str, uploader: str):
    return {
        "id": public_id,
        "name": name,
        "details": rng.choice(DETAILS),
        "category": rng.choice(CATEGORIES),
        "pitchShift": rng.choice([0, 0, 0, -12, -5, 5, 12]),
        "bpm": float(rng.choice([60, 72, 80, 90, 100, 110, 120, 132, 138])),
        "repeatCount": rng.choice([1, 2, 4, 6, 8, 10]),
        "transposePerRepeat": rng.choice([0, 0, 1, 1, 2, -1]),
        "switchDirectionAfter": rng.choice([0, 0, 0, 4, 6]),
        "speedPerRepeat": rng.choice([0, 0, 0, 2, 5, -2]),
        "beatsBetweenReps": float(rng.choice([0, 0, 1, 2, 4])),
        "visibility": "public",
        "uploaderName": uploader,
    }


# ---------------------------------------------------------------- manifest

def load_manifest():
    if os.path.exists(MANIFEST):
        with open(MANIFEST) as f:
            return json.load(f)
    return {"accounts": [], "exercises": [], "voters": []}


def save_manifest(m):
    with open(MANIFEST, "w") as f:
        json.dump(m, f, indent=1)


# ---------------------------------------------------------------- seeding

def claim_account(username: str, seed_key: str, blurb: str, joined_at,
                  dry: bool):
    """POST one PUBLIC_PROFILE, retrying the name with a suffix on a 412."""
    user_id = derived(seed_key)
    for attempt in range(4):
        name = username if attempt == 0 else f"{username} {attempt + 1}"
        doc = {"userID": user_id, "username": name, "description": blurb}
        if joined_at is not None:
            doc["joinedAt"] = joined_at
        if dry:
            print(f"  [dry] PUBLIC_PROFILE {user_id} customName={name}")
            return {"userID": user_id, "username": name, "status": "dry"}
        status, body = post(f"persist/{user_id}/PUBLIC_PROFILE",
                            {"customId1": user_id, "customName": name}, doc)
        if 200 <= status < 300:
            return {"userID": user_id, "username": name, "status": "ok"}
        if status == 412:
            print(f"  name taken: {name!r}, retrying")
            continue
        return {"userID": user_id, "username": name,
                "status": f"failed {status}: {body[:160]}"}
    return {"userID": user_id, "username": username, "status": "name exhausted"}


def publish_exercise(entry, dry: bool):
    """POST one SHARED_EXERCISE document."""
    doc = {
        "userID": entry["userID"],
        "exercise": entry["exercise"],
        "midi": entry["midi"],
        "createdAt": entry["createdAt"],
    }
    if entry["texts"]:
        doc["texts"] = entry["texts"]
    ex_id = entry["exercise"]["id"]
    params = {
        "customId1": entry["userID"],
        "customName": entry["exercise"]["name"],
        "description": entry["exercise"]["details"],
        "customId2": ex_id,
    }
    if dry:
        size = len(json.dumps(doc, separators=(",", ":")))
        print(f"  [dry] SHARED_EXERCISE {ex_id} {entry['exercise']['name']!r} "
              f"({size} B) by {entry['uploader']}")
        return "dry"
    for attempt in range(3):
        status, body = post(f"persist/{ex_id}/SHARED_EXERCISE", params, doc)
        if 200 <= status < 300:
            return "ok"
        if status == 412:  # exercise name collides with an existing customName
            params["customName"] = f"{entry['exercise']['name']} {attempt + 2}"
            entry["exercise"]["name"] = params["customName"]
            doc["exercise"] = entry["exercise"]
            continue
        if status == 0 or status >= 500:
            time.sleep(1.5 * (attempt + 1))
            continue
        return f"failed {status}: {body[:160]}"
    return "failed after retries"


def post_event(user_id: str, ex_id: str, event: str, dry: bool):
    if dry:
        return "dry"
    for attempt in range(3):
        status, body = post(f"user-event/{user_id}/{ex_id}/{event}")
        if 200 <= status < 300:
            return "ok"
        if status == 0 or status >= 500:
            time.sleep(1.0 * (attempt + 1))
            continue
        return f"failed {status}: {body[:120]}"
    return "failed after retries"


def tombstone(targets, dry: bool):
    """Overwrite seeded exercises with the app's tombstone document.

    The backend has no delete; the app unshares by posting a document with no
    `exercise`, which every reader skips. Targets are exercise ids, uploader
    usernames, or ALL.
    """
    manifest = load_manifest()
    wanted = set(targets)
    todo = [e for e in manifest["exercises"]
            if "ALL" in wanted or e["id"] in wanted or e["uploader"] in wanted]
    print(f"Tombstoning {len(todo)} exercises…")
    for e in todo:
        if dry:
            print(f"  [dry] tombstone {e['id']} {e['name']!r}")
            continue
        status, body = post(f"persist/{e['id']}/SHARED_EXERCISE",
                            {"customId1": e["userID"], "customName": "",
                             "description": "", "customId2": e["id"]},
                            {"userID": e["userID"]})
        print(f"  {e['id']} {e['name']!r}: {status} {body[:80]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--accounts", type=int, default=12)
    ap.add_argument("--exercises", type=int, default=80)
    ap.add_argument("--max-events", type=int, default=10)
    ap.add_argument("--voters", type=int, default=24)
    ap.add_argument("--seed", default="l2s-seed-2026-08-25")
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--smoke", action="store_true",
                    help="1 account / 1 exercise, then read it back")
    ap.add_argument("--tombstone", metavar="NAME_OR_ID", nargs="+",
                    help="unshare seeded exercises named in the manifest "
                         "(exercise id, uploader username, or ALL)")
    args = ap.parse_args()

    if args.tombstone:
        tombstone(args.tombstone, args.dry_run)
        return

    if args.smoke:
        args.accounts, args.exercises, args.seed = 1, 1, args.seed + "-smoke"
        USERNAMES[:] = ["Seed Smoke Test"]

    rng = random.Random(args.seed)
    dry = args.dry_run
    manifest = load_manifest()
    now = time.time()

    # ---- accounts
    print(f"Creating {args.accounts} accounts…")
    accounts = []
    for i in range(args.accounts):
        username = USERNAMES[i % len(USERNAMES)]
        if i >= len(USERNAMES):
            username = f"{username} {i // len(USERNAMES) + 1}"
        # Older than any exercise (those are 1-400 days back), so nobody
        # has posted before the day they joined.
        joined = now - rng.uniform(401, 1100) * 86400 if rng.random() < 0.6 else None
        acct = claim_account(username, f"{args.seed}-user-{i}",
                             BLURBS[i % len(BLURBS)],
                             round(joined, 0) if joined else None, dry)
        acct["seedKey"] = f"{args.seed}-user-{i}"
        accounts.append(acct)
        print(f"  {acct['username']:<20} {acct['userID']}  {acct['status']}")
    ok_accounts = [a for a in accounts if a["status"] in ("ok", "dry")]
    if not ok_accounts:
        sys.exit("No account could be created; aborting.")

    # ---- exercises
    used_names = set()
    entries = []
    for i in range(args.exercises):
        acct = ok_accounts[i % len(ok_accounts)]
        seed_key = f"{args.seed}-ex-{i}"
        ex_id = derived(seed_key)
        while True:
            name = f"{rng.choice(ADJ)} {rng.choice(NOUN)}"
            if name not in used_names:
                used_names.add(name)
                break
        notes, texts = make_pattern(rng, seed_key)
        entries.append({
            "userID": acct["userID"],
            "uploader": acct["username"],
            "exercise": make_exercise(rng, ex_id, name, acct["username"]),
            "midi": notes,
            "texts": texts,
            "createdAt": round(now - rng.uniform(1, 400) * 86400, 0),
        })

    print(f"\nPublishing {len(entries)} exercises…")
    with futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(pool.map(lambda e: publish_exercise(e, dry), entries))
    for e, r in zip(entries, results):
        e["publish"] = r
        if r not in ("ok", "dry"):
            print(f"  ! {e['exercise']['name']}: {r}")
    print(f"  {sum(1 for r in results if r in ('ok', 'dry'))}/{len(results)} published")

    # ---- events
    voters = [derived(f"{args.seed}-voter-{i}") for i in range(args.voters)]
    jobs = []
    for e in entries:
        if e["publish"] not in ("ok", "dry"):
            continue
        ex_id = e["exercise"]["id"]
        counts = {}
        for event in ("ADD_LIKE", "ADD_DOWNLOAD", "ADD_PLAY"):
            n = rng.randint(0, args.max_events)
            counts[event] = n
            # One row per (user, exercise, type) server-side, so N distinct
            # users is the only way to reach a count of N.
            for v in rng.sample(voters, n):
                jobs.append((v, ex_id, event))
        e["counts"] = counts

    print(f"\nPosting {len(jobs)} user events…")
    with futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        ev = list(pool.map(lambda j: post_event(j[0], j[1], j[2], dry), jobs))
    bad = [(j, r) for j, r in zip(jobs, ev) if r not in ("ok", "dry")]
    print(f"  {len(ev) - len(bad)}/{len(ev)} events accepted")
    for j, r in bad[:10]:
        print(f"  ! {j[2]} {j[1]}: {r}")

    # ---- manifest
    if not dry:
        manifest["accounts"].extend(
            {"userID": a["userID"], "username": a["username"],
             "seedKey": a["seedKey"], "status": a["status"]}
            for a in accounts)
        manifest["exercises"].extend(
            {"id": e["exercise"]["id"], "name": e["exercise"]["name"],
             "userID": e["userID"], "uploader": e["uploader"],
             "publish": e["publish"], "counts": e.get("counts", {})}
            for e in entries)
        manifest["voters"] = sorted(set(manifest.get("voters", []) + voters))
        manifest["lastRun"] = {"at": now, "seed": args.seed,
                               "accounts": args.accounts,
                               "exercises": args.exercises}
        save_manifest(manifest)
        print(f"\nManifest: {MANIFEST}")

    # ---- smoke verification
    if args.smoke and not dry:
        ex_id = entries[0]["exercise"]["id"]
        print("\nReading back…")
        s, b = get(f"fetch-private/{ex_id}/SHARED_EXERCISE")
        print(f"  fetch-private exercise: {s} {b[:400]}")
        s, b = get(f"fetch-private/{ok_accounts[0]['userID']}/PUBLIC_PROFILE")
        print(f"  fetch-private profile:  {s} {b[:400]}")
        s, b = get(f"event-summary/{ex_id}")
        print(f"  event-summary:          {s} {b[:200]}  (expected {entries[0].get('counts')})")


if __name__ == "__main__":
    main()
