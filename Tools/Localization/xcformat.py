"""Xcode's String Catalog file format, reproduced byte for byte.

`Localizable.xcstrings` has two writers: `generate.py`, and Xcode itself, which
merges the strings its build extracts from the sources back into the file. They
have to agree on formatting down to the byte, because the file is 50 000 lines
long — if they disagree about a space before a colon or about where a key sorts,
every build and every `generate.py` run rewrites all of it and each commit
carries a whole-file diff.

So this module writes what Xcode writes: its indentation, its `" : "` separator,
its key order, its rendering of an empty entry, and no trailing newline. With
that, a `generate.py` run shows up in `git diff` as the strings that changed and
nothing else.
"""
import json
import unicodedata

# --- key order -------------------------------------------------------------
# Xcode sorts entries with Foundation's localizedStandardCompare: case- and
# diacritic-insensitive, runs of digits compared as numbers ("7d" before "24h"),
# quotation marks and dashes folded onto their ASCII forms ("“%@” goes back…"
# sorts among the plain-quoted keys), and punctuation in Unicode collation order
# rather than code point order ("*clap*" before "%d BPM", where code point order
# would say the opposite). Ties on all of that — keys differing only in case,
# like "Vocal range" and "Vocal Range" — put the lowercase one first.
#
# The groups below are that order, coarse enough for the punctuation that shows
# up in English UI strings; anything else falls in with the letters. They
# reproduce the order of every key in the catalog exactly.

# Characters Unicode collation weighs as their ASCII equivalent: the typographic
# quotes and dashes, the ellipsis (three periods) and the no-break spaces.
_EQUIVALENT = {
    "…": "...",
    "“": '"', "”": '"', "„": '"', "«": '"', "»": '"',
    "‘": "'", "’": "'",
    "–": "-", "—": "-",
    " ": " ", " ": " ",
}
_GROUPS = [
    "\t\n\v\f\r ",                                              # whitespace
    "_", "-", ",", ";", ":", "!", "?", ".", "'", '"',           # punctuation
    "(", ")", "[", "]", "{", "}", "@", "*", "/", "\\", "&", "#", "%",
    "+", "<", "=", ">", "|", "~",                               # symbols
    "$",                                                        # currency
]
_PUNCTUATION = {c: rank for rank, group in enumerate(_GROUPS, 1) for c in group}
_DIGITS = len(_GROUPS) + 1
_LETTERS = _DIGITS + 1


def _fold(key):
    """Drop the distinctions Unicode collation only weighs after the letters."""
    key = "".join(_EQUIVALENT.get(c, c) for c in key)
    key = unicodedata.normalize("NFD", key)
    return "".join(c for c in key if not unicodedata.combining(c))


def sort_key(key):
    """Order `key` the way Xcode orders it in the catalog."""
    folded = _fold(key)
    primary, i = [], 0
    while i < len(folded):
        c = folded[i]
        if c.isdigit():
            j = i
            while j < len(folded) and folded[j].isdigit():
                j += 1
            primary.append((_DIGITS, int(folded[i:j])))
            i = j
            continue
        primary.append((_PUNCTUATION.get(c, _LETTERS), ord(c.lower())))
        i += 1
    # Same letters, different capitalisation: lowercase first.
    return primary, [c.isupper() for c in folded]


# --- serialisation ---------------------------------------------------------

def _literal(value):
    return json.dumps(value, ensure_ascii=False)


def _write(value, depth, order=None):
    pad = "  " * depth
    if not isinstance(value, dict):
        return _literal(value)
    if not value:
        return "{\n\n" + pad + "}"          # how Xcode renders an entry with no content
    keys = order if order is not None else sorted(value)
    body = ",\n".join(f"{pad}  {_literal(k)} : {_write(value[k], depth + 1)}" for k in keys)
    return "{\n" + body + "\n" + pad + "}"


def dumps(catalog):
    """Render `catalog` as Xcode would write it — no trailing newline."""
    order = {"strings": sorted(catalog["strings"], key=sort_key)}
    body = ",\n".join(
        f"  {_literal(field)} : {_write(catalog[field], 1, order.get(field))}"
        for field in sorted(catalog))
    return "{\n" + body + "\n}"


def load(path):
    """Read a catalog, or an empty one if the file isn't there yet."""
    if not path.exists():
        return {"sourceLanguage": "en", "strings": {}, "version": "1.1"}
    return json.loads(path.read_text())


def save(path, catalog):
    """Write `catalog`, leaving the file alone if nothing changed. Returns whether it wrote."""
    text = dumps(catalog)
    if path.exists() and path.read_text() == text:
        return False
    path.write_text(text)
    return True
