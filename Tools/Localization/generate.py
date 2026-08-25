"""Build Localizable.xcstrings from the translation batches.

Also reports the gap in both directions: keys the app asks for that nobody
translated, and translations for keys the app no longer uses.
"""
import json, pathlib, subprocess, sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import trbase
import tr_common, tr_settings, tr_visuals, tr_library, tr_community, tr_bundled, tr_reset  # noqa: F401
import tr_feedback  # noqa: F401

HERE = pathlib.Path(__file__).resolve().parent
APP = HERE.parents[1] / "Learn2Sing"
OUT = APP / "Localizable.xcstrings"

# Keys the extractor finds in the Swift sources.
extracted = json.loads(subprocess.run(
    [sys.executable, str(HERE / "extract.py")],
    capture_output=True, text=True, check=True).stdout)

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
    "Recent", "Routines", "Favourites", "Recommended", "Calendar",
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
    "May", "Doo Hoo", "Mum", "Yum Ya", "Myam Myom", "Mom Moh",
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

strings = {}
for key in wanted:
    # No "extractionState": "manual" — that is what makes xcstringstool emit a
    # Swift symbol per key, and several keys differ only in capitalisation
    # ("Vocal Range" vs "Vocal range"), which it refuses to name apart. The app
    # looks every string up by its English text, so the symbols are unused.
    entry = {}
    translations = trbase.TRANSLATIONS.get(key)
    if translations:
        entry["localizations"] = {
            lang: {"stringUnit": {"state": "translated", "value": value}}
            for lang, value in translations.items()
        }
    strings[key] = entry

catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
OUT.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
print(f"\nwrote {OUT} — {len(strings)} keys, "
      f"{len(strings) - len(missing) - len(NOT_TRANSLATED & set(wanted))} translated")
