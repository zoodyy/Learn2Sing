// Shared MIDI pitch constants and helpers used by EditingView and PlaybackView.

let hiPitch  = 83   // B5
let loPitch  = 36   // C2

private let _noteLabels = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

func pitchName(_ pitch: Int) -> String {
    "\(_noteLabels[pitch % 12])\((pitch / 12) - 1)"
}

func isBlack(_ pitch: Int) -> Bool {
    [1, 3, 6, 8, 10].contains(pitch % 12)
}
