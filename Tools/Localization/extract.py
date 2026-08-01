"""Pull every localizable English source string out of the Swift sources.

Two kinds of call site:
  * L("...") / L(\"\"\"...\"\"\") — plain-String lookups
  * SwiftUI APIs taking a LocalizedStringKey (Text, Label, navigationTitle, ...)
Both are keyed by the English text itself, so the key list is exactly what the
String Catalog needs.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[2] / "Learn2Sing"
SKIP_FILES = {"Localization.swift", "BundledLocalization.swift"}

# APIs whose first literal argument is a LocalizedStringKey.
LSK_PREFIXES = [
    "Text(", "Label(", "Button(", "Picker(", "Toggle(", "Stepper(", "ColorPicker(",
    "Section(", "TextField(", "LabeledContent(", "SharePreview(", "Tab(",
    "ContentUnavailableView(", ".navigationTitle(", ".alert(", ".accessibilityLabel(",
    ".accessibilityValue(", ".accessibilityHint(", ".confirmationDialog(",
]
# Named arguments that are LocalizedStringKey.
LSK_NAMED = ["prompt: ", "description: Text(", "title: "]

def read_literal(src, i):
    """Parse the Swift string literal starting at src[i] == '\"'. Returns (value, end)."""
    if src.startswith('"""', i):
        # Multi-line literal: content runs to the matching \"\"\", and the closing
        # delimiter's indentation is stripped from every line.
        end = src.index('"""', i + 3)
        body = src[i + 3:end]
        closing_line_start = src.rfind("\n", 0, end)
        indent = src[closing_line_start + 1:end]
        lines = body.split("\n")
        if lines and lines[0].strip() == "":
            lines = lines[1:]
        stripped = [ln[len(indent):] if ln.startswith(indent) else ln.lstrip() for ln in lines]
        if stripped and stripped[-1].strip() == "":
            stripped = stripped[:-1]
        # A trailing backslash joins the next line without a newline.
        out, pending = [], ""
        for ln in stripped:
            if ln.endswith("\\"):
                pending += ln[:-1]
            else:
                out.append(pending + ln)
                pending = ""
        if pending:
            out.append(pending)
        return "\n".join(out), end + 3
    # Single-line literal.
    j, out = i + 1, []
    while j < len(src):
        c = src[j]
        if c == "\\":
            nxt = src[j + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "0": "\0"}.get(nxt, nxt))
            j += 2
            continue
        if c == '"':
            return "".join(out), j + 1
        if c == "\n":
            return None, j          # not a literal we can read
        out.append(c)
        j += 1
    return None, j

def strip_line_comments(src):
    """Blank out `//` comments, keeping offsets, so prose about `Text("…")` in a
    doc comment isn't mistaken for a call site. String literals are respected so
    a `//` inside one survives."""
    out = list(src)
    i, in_string = 0, False
    while i < len(src):
        c = src[i]
        if in_string:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_string = False
        elif c == '"':
            in_string = True
        elif c == "/" and src[i + 1:i + 2] == "/":
            while i < len(src) and src[i] != "\n":
                out[i] = " "
                i += 1
            continue
        i += 1
    return "".join(out)


def collect(path):
    src = strip_line_comments(path.read_text())
    found = []
    for m in re.finditer(r'\bL\(\s*', src):
        i = m.end()
        if i < len(src) and src[i] == '"':
            val, _ = read_literal(src, i)
            if val:
                found.append(val)
    for prefix in LSK_PREFIXES + LSK_NAMED:
        start = 0
        while True:
            k = src.find(prefix, start)
            if k < 0:
                break
            start = k + len(prefix)
            i = start
            while i < len(src) and src[i] in " \n":
                i += 1
            if i < len(src) and src[i] == '"':
                val, _ = read_literal(src, i)
                if val:
                    found.append(val)
    return found

keys = []
seen = set()
for path in sorted(ROOT.glob("*.swift")):
    if path.name in SKIP_FILES:
        continue
    for key in collect(path):
        if key and key not in seen:
            seen.add(key)
            keys.append(key)

# Not translatable: symbol names, format-only strings, single characters.
def drop(k):
    return (
        not k.strip()
        or re.fullmatch(r"[\d\s%@.,:/+\-–—]*", k)
        or re.fullmatch(r"[a-z0-9.]+", k) and " " not in k and k.islower() and "." in k
    )

keys = [k for k in keys if not drop(k)]
print(json.dumps(keys, ensure_ascii=False, indent=1))
print(f"\n// {len(keys)} keys", file=sys.stderr)
