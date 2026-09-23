# PitchBench

Offline replay of the pitch detector against the debug recordings the app exports
(score screen ▸ export debug recording). It compiles the app's own
`Learn2Sing/Sources/Audio/PitchAnalyzer.swift` and `PitchSettler.swift`, so every number
is the shipped code's, next to a verbatim port of the detector it replaced (`old`, as of
commit ae59be0).

```bash
Tools/PitchBench/build.sh
Tools/PitchBench/.build/pitchbench prepare Debug Debug/Problematic   # any folders holding the exported zips
Tools/PitchBench/.build/pitchbench eval old 4800      # what the app did: 100 ms tap blocks
Tools/PitchBench/.build/pitchbench eval new 480       # Settings ▸ Voice ▸ "Fastest": 10 ms I/O buffers
Tools/PitchBench/.build/pitchbench eval balanced 480  # "Balanced delay and accuracy"
Tools/PitchBench/.build/pitchbench eval accurate 480  # "Slowest, most accurate"
Tools/PitchBench/.build/pitchbench synth new 480      # synthetic voices with exact ground truth
```

`prepare` unzips into `Tools/PitchBench/.work` (git-ignored; `PITCHBENCH_WORK`
overrides it) and computes a **reference track** for each recording: a slow,
look-ahead tracker (centred YIN, a harmonic comb for the octave, Viterbi over the
whole run) that nothing real-time can match. `checkref` compares it with the notes
that were sung against; on the 2026-08 recordings it never disagreed by an octave.

What `eval` prints, per recording and as a mean (`HLD` is the detector's output as
polled, `DRW` is what the screen draws, eased, at the given fps):

- `lat`: the delay that best lines the output up with the reference.
- `on`: median/90th percentile delay before a new note shows (within a semitone).
- `step`: median/90th percentile delay of a note change (≥ 1.5 semitones).
- `med`/`p95`: error on steady notes, in cents.
- `outl`: output more than a semitone from anything the reference had nearby
  (±30 ms), as a share of voiced output and as a count of separate events.
  `gross` is the same beyond 3 semitones.
- `spur`: output where the reference hears no voice at all.
- `recall`: share of steady reference frames the output covers.

`dump` and `classify` list and sort the outlier events; `validate` checks the
`old` port against the pitch line a recording actually drew (it matches with
4800-frame buffers, which is how the input tap turned out to deliver audio).

Detectors: `old`, `new` (= `fastest`), `balanced`, `accurate`, and `exp`, the bench's
copy of the analyzer without the settler whose tuning comes from the environment
(`COMB_SHARE`, `COMB_WEIGHT`, `SUB_WEIGHT`, `CONT_BONUS`, `CONT_RANGE`, `PERIODS`; see
`Sources/ExpAnalyzer.swift`, whose defaults are the app's and have to be kept in step).
For audio that isn't an exported recording: `runlist <detector> <bufferFrames> <list>`
writes a track per WAV, `reflist <list>` a reference track, `frames <bufferFrames> <list>`
every analysis of `exp` (level, candidate, clarity, what it shows) for prototyping what
comes after it; `export` does the first for the prepared recordings.

The bench only needs the macOS toolchain (Swift, Accelerate, AVFoundation).

## Comparing against other trackers and other voices (`compare/`)

Python tooling around the bench, used on 2026-09-23 to choose the three pitch
detection settings. It adds public singing datasets, neural trackers, and metrics for
what the singer sees rather than what an f0 annotation says.

```bash
python3 -m venv Tools/PitchBench/.venv          # git-ignored
Tools/PitchBench/.venv/bin/pip install numpy scipy matplotlib soundfile soxr remotezip swift-f0 onnxruntime
cd Tools/PitchBench/compare
../.venv/bin/python fetch.py                    # ~420 MB: vocadito, VocalSet and MIR-1K subsets
../.venv/bin/python run.py swift balanced 480 user,vocadito,mir1k,vocalset
../.venv/bin/python run.py eval new,balanced,accurate user,vocadito,mir1k,vocalset
../.venv/bin/python la.py show new balanced accurate          # one line per detector
../.venv/bin/python tools.py plot Ti-Ki-Ta 15.5 16.5 new@14,balanced@34,accurate@94 out.png
```

Sets: `user` (the exported recordings), `user-problem` (the ones in
`Debug/Problematic`), `vocadito` (40 solo excerpts in 7 languages, hand-labelled f0),
`mir1k` (224 karaoke clips of 19 amateur singers, hand-labelled), `vocalset` (160 takes
of 20 trained singers from bass to soprano: belt, breathy, vocal fry, vibrato, fast
scales, songs with lyrics; truth is the reference track). The public sets are scaled to
the level the phone records at: VocalSet is recorded ~20 dB quieter, and the analyzer's
silence gate is an absolute level.

Metrics beyond the bench's (`metrics.py`):

- `off/m`: output more than a semitone away from the pitch the singer settled on for
  the notes around it (the reference's median over each note's middle), per minute.
  This is what "consonants throw the line off" looks like in numbers: the voice really
  does start a syllable a semitone or two off after a "t" or "k" and droops into the
  next closure, which an f0 annotation counts as correct.
- `cons/m`: those within 100 ms of a sung syllable's start (`texts` in the recording).
- `cov`: share of each note's settled middle the line covers within half a semitone.
- `gross/m`, `spur/m`: events more than 3 semitones off the truth, and output where
  the truth hears no voice. On the public sets these, `recallS` (coverage of steady
  frames) and `p95` (cents, steady frames, which is where flattened vibrato shows) are
  the fair measures: their annotations include the consonant slides.

`neural.py` runs SwiftF0 and CREPE as live trackers would (only the audio up to each
moment), `la.py` is the prototype the `PitchSettler` was tuned with (array code,
checked against the Swift port to 99.9% of output points). `PROCS` (default 4) sets the
parallelism: 16 busy processes plus PyTorch took the development machine down once.

Results (2026-09-23; line delay and time until a new note shows as drawn, the rest per
minute of singing; lower is better except coverage):

| | line delay | new note | off-note / consonant, Problematic | gross / spurious, vocadito | gross, MIR-1K / VocalSet |
|---|---|---|---|---|---|
| fastest (before) | 14 ms | 33 ms | 79.1 / 39.0 | 57.1 / 30.2 | 19.7 / 30.6 |
| fastest | 14 ms | 33 ms | 79.1 / 39.0 | 54.1 / 30.1 | 18.4 / 26.9 |
| balanced | 34 ms | 59 ms | 25.8 / 12.7 | 29.0 / 14.0 | 6.3 / 18.6 |
| most accurate | 94 ms | 112 ms | 10.8 / 5.0 | 12.8 / 6.2 | 3.4 / 17.9 |
| SwiftF0 (2025), full look-ahead (176 ms) | ~8 ms* | | 100.7 / 45.5 | 37.1 / 24.8 | 11.8 / 29.4 |
| SwiftF0, 48 ms look-ahead | 56 ms | | 105.4 / 44.8 | 37.0 / 30.5 | 16.0 / 28.3 |
| CREPE full, live (64 ms window) | 36 ms | | 50.2 / 34.3 | 47.8 / 48.3 | |
| CREPE tiny, live | 36 ms | | 45.5 / 32.0 | 40.3 / 37.7 | |
| PESTO (LGPL), offline | ~6 ms* | | 85.3 / 57.9 | 50.6 / 21.6 | |

\* offline: it sees the whole file (PESTO's median error on steady notes is also 8 cents
against the analyzer's 1.6: its bins are a third of a semitone). CREPE and PESTO are
shown at their best voicing threshold (0.7, 0.85). The neural trackers follow the voice's real
consonant slides faithfully, which is exactly what the singer reads as the line being
thrown off, and at the delays a live line can afford they make more gross errors than
the analyzer. Coverage of steady notes stays at 99.5-99.9% for all three settings.
