"""Update Localizable.xcstrings from the translation batches.

The catalog is generated, but only the entries that actually changed are
touched: it is read, reconciled with the `tr_*.py` tables and written back in
Xcode's own format (see `xcformat.py`), so `git diff` after a run shows the
strings you added, edited or deleted and nothing else. Xcode rewrites the same
file whenever a build extracts strings from the sources, so anything it owns —
its `extractionState` markers, its comments, the keys it extracts that we don't
know about — is carried through untouched rather than removed and re-added.

Also reports the gap in both directions: keys the app asks for that nobody
translated, and translations for keys the app no longer uses.
"""
import json, pathlib, subprocess, sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import trbase
import xcformat
import tr_common, tr_settings, tr_visuals, tr_library, tr_community, tr_bundled, tr_reset  # noqa: F401
import tr_feedback, tr_tutorial, tr_help  # noqa: F401

HERE = pathlib.Path(__file__).resolve().parent
APP = HERE.parents[1] / "Learn2Sing"
OUT = APP / "Localizable.xcstrings"

# Keys the extractor finds in the Swift sources, and the subset of those Xcode's
# own extractor finds too (the LocalizedStringKey call sites).
extraction = json.loads(subprocess.run(
    [sys.executable, str(HERE / "extract.py")],
    capture_output=True, text=True, check=True).stdout)
extracted = extraction["keys"]
extracted_by_xcode = set(extraction["extractedByXcode"])

# Keys that reach L() as an enum raw value, a stored category name or a bundled
# exercise's name/description, so they never appear as a literal in the sources.
INDIRECT = [
    # VocalRange
    "Bass", "Baritone", "Tenor", "Alto", "Mezzo", "Soprano", "Custom",
    # Instrument
    "Piano", "Sin Wave", "Guitar", "Voice",
    # AppTheme / OrientationLock
    "System", "Light", "Dark", "Don't lock", "Portrait", "Landscape",
    # PlaybackFont / PlayheadStyle / RepetitionCounterPosition
    "Rounded", "Serif", "Monospaced", "Line", "Dots",
    "Top right", "Bottom left", "Bottom middle", "Bottom right",
    # ScoreRange
    "24h", "7d", "30d", "6m", "1y", "All",
    # ExerciseVisibility
    "Private", "Public",
    # Audio route sentinels
    "Automatic", "iPhone Speaker", "iPhone Microphone",
    # Categories: bundled + Home tab built-ins
    "Tone", "Scales", "Articulation", "Agility", "Range", "No Category",
    "Recent", "Routines", "Favourites", "Recommended", "Time Spent Singing", "New for You",
    # Bundled visual templates
    "Simplest - dark", "Simplest - light",
    # FeedbackType / FeedbackLocation (the tab names are extracted from the
    # ContentView tabs they name, so only "Other" is listed here)
    "Bug", "Feature Request", "Feedback", "Question", "Other",
]

bundle = json.loads((APP / "Bundled" / "BundledExercises.json").read_text())
for exercise in bundle["exercises"]:
    INDIRECT.append(exercise["name"])
    if exercise.get("details", "").strip():
        INDIRECT.append(exercise["details"])

# Names that are the syllable the singer sings, or a product/file name: shown
# as-is in every language, so they are deliberately left untranslated.
NOT_TRANSLATED = {
    "Mom Moh", "Ng", "Mee May Mah Moh Moo", "Hoo", "Moo", "Mmm Mah", "Nee Nay Nah", "Vee",
    "Nyah", "Wee Woo", "Ming", "Gah", "Nuh",
    "La Le Li Lo Lu", "Ta Ka", "Pa Ba", "Hup", "Dee Dah", "Kah Gah", "Ti Ki Ta",
    "Ning Nong", "Ta Da La Na", "Buh Duh Guh", "Pa Ta Ka",
    "Learn2Sing Exercises",
}

wanted = []
for key in extracted + INDIRECT:
    if key not in wanted:
        wanted.append(key)

missing = [k for k in wanted if k not in trbase.TRANSLATIONS and k not in NOT_TRANSLATED]
unused = [k for k in trbase.TRANSLATIONS if k not in wanted]

if missing:
    print(f"MISSING {len(missing)}:")
    for k in missing:
        print("  " + json.dumps(k, ensure_ascii=False))
if unused:
    print(f"UNUSED {len(unused)}:")
    for k in unused:
        print("  " + json.dumps(k, ensure_ascii=False))

catalog = xcformat.load(OUT)
before = catalog["strings"]
after = {}

# Keys the app no longer asks for. An entry carrying translations was written
# from these tables, so it goes; one carrying none is Xcode's own extraction —
# Swift Charts axis labels and the like, which our extractor deliberately skips
# — and deleting that only gives the next build something to add back.
for key, entry in before.items():
    if key in wanted or not entry.get("localizations"):
        after[key] = entry

for key in wanted:
    translations = trbase.TRANSLATIONS.get(key)
    if not translations:
        # Untranslated, either on purpose (NOT_TRANSLATED) or not yet (MISSING).
        # Whatever Xcode holds stands: an entry with no translations in it is
        # one Xcode prunes, so writing one is a round trip for nothing.
        continue
    entry = dict(after.get(key, {}))
    entry["localizations"] = {
        lang: {"stringUnit": {"state": "translated", "value": value}}
        for lang, value in translations.items()
    }
    # No "extractionState": "manual" — that is what makes xcstringstool emit a
    # Swift symbol per key, and several keys differ only in capitalisation
    # ("Vocal Range" vs "Vocal range"), which it refuses to name apart. The app
    # looks every string up by its English text, so the symbols are unused.
    #
    # "stale" is Xcode's, and it lands on every key its own extractor can't see
    # — everything reached through L() or listed in INDIRECT. Writing it here
    # means the next build finds the entry already the way it wants it, instead
    # of coming back to edit the line we just added.
    if "extractionState" not in entry and key not in extracted_by_xcode:
        entry["extractionState"] = "stale"
    after[key] = entry

added = [k for k in after if k not in before]
deleted = [k for k in before if k not in after]
edited = [k for k in after if k in before and after[k] != before[k]]

# The whole point of matching Xcode's format is that a run rewrites nothing it
# didn't have to, so say something if an untouched key still moved.
kept = [k for k in before if k in after]
if kept != [k for k in sorted(after, key=xcformat.sort_key) if k in before]:
    print("NOTE: sorting moved entries nobody changed, so the diff will be bigger "
          "than the edit — either the file was left in some other writer's order, "
          "or xcformat.sort_key and Xcode have drifted apart.")

catalog["strings"] = after
if xcformat.save(OUT, catalog):
    print(f"\nwrote {OUT} — {len(added)} added, {len(edited)} edited, "
          f"{len(deleted)} deleted, {len(after)} entries")
else:
    print(f"\n{OUT} already up to date — {len(after)} entries")
