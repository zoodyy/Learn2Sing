# Localization tooling

`Learn2Sing/Localizable.xcstrings` is **generated**. Don't hand-edit it (and don't
edit it through Xcode's String Catalog editor either) — regenerate instead:

```bash
python3 Tools/Localization/generate.py
```

## How the app looks strings up

Every string is keyed by its **English text**, gettext-style, so English works
with no catalog at all and a missing translation falls back to readable English
rather than a raw key. Two kinds of call site:

- `Text("Settings")`, `Label`, `Button`, `Section` … take a `LocalizedStringKey`
  and resolve against the environment locale, which `ContentView` sets from the
  chosen language.
- `L("Settings")` returns a plain `String`, for anywhere a `LocalizedStringKey`
  never gets a chance: `settingHelp(_:)`, alert message bodies, values assigned
  to `@State`, enum `rawValue`s, and **`navigationTitle` / `searchable(prompt:)`**
  — those two are UIKit-backed and cache whatever they first resolved, so a live
  language switch wouldn't reach them.

See `Learn2Sing/Localization.swift` for the language list and the bundle
override, and `Learn2Sing/BundledLocalization.swift` for the rule that decides
which exercise, category and template names are the app's (translated) versus the
user's own (never touched).

## Adding or changing a string

1. Edit the Swift source as usual.
2. Add the English text to the matching `tr_*.py` table with one translation per
   language, in `trbase.LANGS` order.
3. Run `generate.py`. It re-extracts the keys from the sources and reports both
   `MISSING` (in the app, not translated) and `UNUSED` (translated, no longer in
   the app) — both should be empty before you commit.

Strings that are deliberately the same in every language — the vowel syllables
bundled exercises are named after ("Mum", "Yum Ya"), and file names — are listed
in `NOT_TRANSLATED` in `generate.py` so they don't show up as missing.

## Adding a language

1. Add a case to `AppLanguage` in `Learn2Sing/Localization.swift`, with its
   native and English names.
2. Add the code to `LANGS` in `trbase.py` and a translation to **every** row of
   every `tr_*.py` (the `T()` helper is positional and asserts on the count).
3. Add the code to `knownRegions` in `project.pbxproj`.
4. Run `generate.py`.

## Note on the catalog format

Entries deliberately carry no `"extractionState": "manual"`. That flag is what
makes `xcstringstool` emit a Swift symbol per key, and several keys differ only
in capitalisation ("Vocal Range" vs "Vocal range"), which it refuses to name
apart — it fails the build. Nothing references the generated symbols.
