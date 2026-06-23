import SwiftUI
import AVFoundation

// MARK: - Audio engine

final class ExercisePlayer {
    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private var workItems: [DispatchWorkItem] = []

    init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()

        let dlsPath = "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"
        if FileManager.default.fileExists(atPath: dlsPath) {
            let url = URL(fileURLWithPath: dlsPath)
            try? sampler.loadSoundBankInstrument(at: url, program: 0, bankMSB: 0x79, bankLSB: 0)
        }
    }

    func schedule(notes: [MIDINote], bpm: Double, leadIn: Double, onFinish: @escaping () -> Void) {
        cancelAll()
        let secPerBeat = 60.0 / bpm

        for note in notes {
            let onDelay  = (note.beat + leadIn) * secPerBeat
            let offDelay = (note.beat + note.length + leadIn) * secPerBeat

            let onItem = DispatchWorkItem { [weak self] in
                self?.sampler.startNote(UInt8(note.pitch), withVelocity: 90, onChannel: 0)
            }
            let offItem = DispatchWorkItem { [weak self] in
                self?.sampler.stopNote(UInt8(note.pitch), onChannel: 0)
            }
            workItems += [onItem, offItem]
            DispatchQueue.main.asyncAfter(deadline: .now() + onDelay,  execute: onItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + offDelay, execute: offItem)
        }

        let lastBeat = notes.map { $0.beat + $0.length }.max() ?? 0
        let finishDelay = (lastBeat + leadIn + 1.0) * secPerBeat
        let finishItem = DispatchWorkItem { onFinish() }
        workItems.append(finishItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + finishDelay, execute: finishItem)
    }

    func cancelAll() {
        workItems.forEach { $0.cancel() }
        workItems.removeAll()
        for p in 0...127 { sampler.stopNote(UInt8(p), onChannel: 0) }
    }

    deinit { cancelAll(); engine.stop() }
}

// MARK: - PlaybackView

struct PlaybackView: View {
    let exercise: Exercise

    @State private var player = ExercisePlayer()
    @State private var notes: [MIDINote] = []
    @State private var startDate: Date? = nil
    @Environment(\.dismiss) private var dismiss

    private let bpm: Double    = 120
    private let leadIn: Double = 2       // silent beats before first note
    private let pianoW: CGFloat = 38
    private let beatPx: CGFloat = 80     // pixels per beat in playback view

    var body: some View {
        TimelineView(.animation) { tl in
            let beat: Double = {
                guard let s = startDate else { return -leadIn }
                return tl.date.timeIntervalSince(s) * (bpm / 60.0) - leadIn
            }()

            Canvas { ctx, size in
                drawScene(ctx: ctx, size: size, beat: beat)
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadNotes()
            startDate = Date()
            player.schedule(notes: notes, bpm: bpm, leadIn: leadIn) {
                dismiss()
            }
        }
        .onDisappear {
            player.cancelAll()
        }
    }

    // MARK: - Drawing

    private func drawScene(ctx: GraphicsContext, size: CGSize, beat: Double) {
        let rows    = hiPitch - loPitch + 1
        let rowH    = size.height / CGFloat(rows)
        let phX     = pianoW + 24          // playhead x position

        let activePitches = Set(
            notes.filter { beat >= $0.beat && beat < $0.beat + $0.length }.map { $0.pitch }
        )

        // ── Piano key column ────────────────────────────────────────────
        for row in 0..<rows {
            let pitch = hiPitch - row
            let y = CGFloat(row) * rowH
            let active = activePitches.contains(pitch)
            let bg: Color = active ? .yellow : (isBlack(pitch) ? Color(white: 0.07) : Color(white: 0.82))
            ctx.fill(Path(CGRect(x: 0, y: y, width: pianoW - 1, height: rowH)), with: .color(bg))
        }

        var colBorder = Path()
        colBorder.move(to: CGPoint(x: pianoW - 0.5, y: 0))
        colBorder.addLine(to: CGPoint(x: pianoW - 0.5, y: size.height))
        ctx.stroke(colBorder, with: .color(.gray.opacity(0.4)), lineWidth: 1)

        // ── Note area row backgrounds ────────────────────────────────────
        for row in 0..<rows {
            let pitch = hiPitch - row
            let y = CGFloat(row) * rowH
            ctx.fill(
                Path(CGRect(x: pianoW, y: y, width: size.width - pianoW, height: rowH)),
                with: .color(isBlack(pitch) ? Color(white: 0.08) : Color(white: 0.14))
            )
        }

        // Horizontal separators
        var hLines = Path()
        for row in 0...rows {
            let y = CGFloat(row) * rowH
            hLines.move(to: CGPoint(x: pianoW, y: y))
            hLines.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(hLines, with: .color(white: 0.2), lineWidth: 0.5)

        // ── Notes ────────────────────────────────────────────────────────
        for note in notes {
            let noteX = phX + CGFloat(note.beat - beat) * beatPx
            let noteW = CGFloat(note.length) * beatPx

            let leftEdge  = max(noteX, pianoW)
            let rightEdge = min(noteX + noteW, size.width)
            guard rightEdge > leftEdge else { continue }

            let row  = hiPitch - note.pitch
            let y    = CGFloat(row) * rowH + 1
            let rect = CGRect(x: leftEdge, y: y, width: rightEdge - leftEdge - 1, height: rowH - 2)
            let path = Path(roundedRect: rect, cornerRadius: 2)

            let isActive = activePitches.contains(note.pitch) && beat >= note.beat
            if isActive {
                ctx.fill(path, with: .color(.white))
                ctx.stroke(path, with: .color(.yellow), lineWidth: 1.5)
            } else {
                ctx.fill(path, with: .color(.green.opacity(0.85)))
                ctx.stroke(path, with: .color(.green), lineWidth: 1)
            }
        }

        // ── Playhead ─────────────────────────────────────────────────────
        var glow = Path()
        glow.move(to: CGPoint(x: phX, y: 0))
        glow.addLine(to: CGPoint(x: phX, y: size.height))
        ctx.stroke(glow, with: .color(.white.opacity(0.12)), lineWidth: 10)

        var line = Path()
        line.move(to: CGPoint(x: phX, y: 0))
        line.addLine(to: CGPoint(x: phX, y: size.height))
        ctx.stroke(line, with: .color(.white), lineWidth: 2)
    }

    // MARK: - Persistence

    private func loadNotes() {
        let key = "midi_\(exercise.id.uuidString)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([MIDINote].self, from: data)
        else { return }
        notes = saved
    }
}
