# App Store screenshot headlines

Renders the five iPhone App Store screenshots (1242×2688) with their big headline translated:
it erases the English headline from each original and sets the translation in its place, in
the same font, size, squash and position, shrinking only when a line would not fit.

The originals are `~/Downloads/YouCanSing app store 1.png` … `5.png`:

| # | English headline |
|---|---|
| 1 | See Your Pitch |
| 2 | Create Your Own Exercises |
| 3 | Over 100 Bundled Exercises |
| 4 | And Share Them With The Community ("them" = the exercises) |
| 5 | Customise Your Experience |

The translations are in `headlines.tsv`, one row per App Store Connect language, with `\n`
for line breaks. The output folders use App Store Connect's language names. Spanish (Spain/Mexico)
and French (France/Canada) share one translation each, since the app only has `es` and `fr`.

## Running

```bash
cd Tools/StoreScreenshots
swiftc -O Common.swift render/main.swift -o "$TMPDIR/store-render"
"$TMPDIR/store-render" ~/Downloads/"YouCanSing app store" ~/Downloads/"YouCanSing app store localized" headlines.tsv
```

A 4th argument renders only some folders or languages, e.g. `German,ja`. Then check the result:

```bash
swiftc -O Common.swift verify/main.swift -o "$TMPDIR/store-verify"
"$TMPDIR/store-verify" ~/Downloads/"YouCanSing app store" ~/Downloads/"YouCanSing app store localized"
```

It checks each file is 1242×2688 without alpha, that nothing below the header changed, that the
phones in screenshot 5 are untouched, and that the side margins are empty. Look at the
images as well: a line that had to shrink a lot is usually better broken differently.

## What the originals turned out to be (measured with `measure/`)

- **Font.** "Damascus Bold" has no Latin letters or digits, so the design tool (Apple's text
  system) set all of them in **Helvetica Bold**. Only the space, Arabic and the line leading come
  from Damascus. Cyrillic also falls back to Helvetica Bold.
- **Squash.** The text is squashed vertically to **92.8 %**: a horizontally stretched text layer.
  With it, the re-rendered English matches the originals to about 1.5/531 per pixel.
- **Line spacing.** The pitch is 1.0× the squashed size. A line that contains a Damascus glyph
  (any space) sits 0.0215 em lower, which is Damascus' leading.
- **Position.** Each screenshot's lines are centred on its own x (615.7–629.1, not the canvas
  centre 621). The ink box is centred vertically on y 546 in 1–4, and on y 424.5 in 5, where the
  tilted phones start higher.
- **Background.** It is flat (205, 73, 253) with a faint 2-px seam across rows 549–550 and a 2-px
  strip down both edges below that. The cleaning step keeps each row's own colour.

## Choices made for the translations

- **Fitting.** The size starts at the original's and shrinks only to keep 60 px side margins, the
  original's vertical room and, in 5, at least 16 px between the text and the phones (there the
  block moves up before it shrinks). Lines push apart only if a descender would nearly touch an
  accent.
- **CJK.** Line spacing gives the same visible gap as the Latin lines, rather than the fonts' own
  very loose leading. Japanese uses Hiragino Sans W8 with proportional kana (`palt`). Korean uses
  Apple SD Gothic Neo ExtraBold. Chinese keeps PingFang SC Semibold, the default fallback and the
  heaviest PingFang. Digits stay in Helvetica Bold.
- **Arabic.** Arabic starts at 1.3× the size, because Arabic letters at the same point size look
  much smaller than Latin capitals. Digits stay Western, like the app's Arabic strings.
- **Wording.** The register follows the app: du/tú/tu/je for German, Spanish, Italian, Dutch and
  Swedish, and vous/вы/siz for French, Russian and Turkish. The terms come from
  `Tools/Localization` ("Tonhöhe", "Community", "Übungen", …).
- **Line breaks.** One-letter prepositions never end a line (Russian "с сообществом").

Not covered: the iPad screenshot (`YouCanSing app store ipad 1.png`, 2064×2752) would need its
own measured entry in `shots`.
