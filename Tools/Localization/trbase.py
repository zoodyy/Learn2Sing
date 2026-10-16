"""Shared table for the per-area translation batches.

`T(english, ...)` takes one translation per language, positionally, in LANGS
order — the tables are long, so repeating the 14 language codes on every row
would drown the actual text.
"""

LANGS = ["de", "es", "fr", "it", "pt-BR", "nl", "ru", "pl", "tr", "sv", "ja", "ko", "zh-Hans", "ar"]

TRANSLATIONS: dict[str, dict[str, str]] = {}


def T(english, *values):
    assert len(values) == len(LANGS), f"{english!r}: {len(values)} values, expected {len(LANGS)}"
    assert english not in TRANSLATIONS, f"duplicate key: {english!r}"
    TRANSLATIONS[english] = dict(zip(LANGS, values))


# Info.plist strings, for `InfoPlist.xcstrings`: keyed by their Info.plist key
# rather than by the English text, and holding the English too ("en"), since
# that is the value the build settings give the key.
INFOPLIST: dict[str, dict[str, str]] = {}


def P(key, english, *values):
    assert len(values) == len(LANGS), f"{key}: {len(values)} values, expected {len(LANGS)}"
    assert key not in INFOPLIST, f"duplicate key: {key}"
    INFOPLIST[key] = {"en": english, **dict(zip(LANGS, values))}
