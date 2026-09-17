# PitchBench

Offline replay of the pitch detector against the debug recordings the app exports
(score screen ▸ export debug recording). It compiles the app's own
`Learn2Sing/Sources/Audio/PitchAnalyzer.swift`, so every number is the shipped
code's, next to a verbatim port of the detector it replaced (`old`, as of
commit ae59be0).

```bash
Tools/PitchBench/build.sh
Tools/PitchBench/.build/pitchbench prepare Debug     # any folders holding the exported zips
Tools/PitchBench/.build/pitchbench eval old 4800     # what the app did: 100 ms tap blocks
Tools/PitchBench/.build/pitchbench eval new 480      # what it does: 10 ms I/O buffers
Tools/PitchBench/.build/pitchbench synth new 480     # synthetic voices with exact ground truth
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

The bench only needs the macOS toolchain (Swift, Accelerate, AVFoundation).
