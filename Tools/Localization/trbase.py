"""Shared table for the per-area translation batches.

`T(english, ...)` takes one translation per language, positionally, in LANGS
order — the tables are long, so repeating the 13 language codes on every row
would drown the actual text.
"""

LANGS = ["de", "es", "fr", "it", "pt-BR", "nl", "ru", "pl", "tr", "sv", "ja", "ko", "zh-Hans"]

TRANSLATIONS: dict[str, dict[str, str]] = {}


def T(english, *values):
    assert len(values) == len(LANGS), f"{english!r}: {len(values)} values, expected {len(LANGS)}"
    assert english not in TRANSLATIONS, f"duplicate key: {english!r}"
    TRANSLATIONS[english] = dict(zip(LANGS, values))
