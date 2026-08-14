import SwiftUI
import Combine

// MARK: - Model

struct MIDINote: Identifiable, Codable, Equatable {
    var id = UUID()
    var pitch: Int      // MIDI pitch number
    var beat: Double    // start position in beats
    var length: Double  // duration in beats

    private enum CodingKeys: String, CodingKey { case id, pitch, beat, length }

    // Emit the id lowercase so every UUID in the community request body is
    // lowercase; UUID decoding is case-insensitive, so this round-trips.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(pitch, forKey: .pitch)
        try c.encode(beat, forKey: .beat)
        try c.encode(length, forKey: .length)
    }
}

/// A free-floating text label placed on the grid. It shares the note coordinate
/// system (a `pitch` row for vertical position, a `beat` for horizontal) so it
/// scrolls in lockstep with the notes during playback.
struct MIDIText: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var pitch: Int      // row position (vertical)
    var beat: Double    // start position in beats (horizontal)

    private enum CodingKeys: String, CodingKey { case id, text, pitch, beat }

    // Emit the id lowercase so every UUID in the community request body is
    // lowercase; UUID decoding is case-insensitive, so this round-trips.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(pitch, forKey: .pitch)
        try c.encode(beat, forKey: .beat)
    }
}

// MARK: - Layout constants

private let rowH: CGFloat = 22
private let beatW: CGFloat = 52
private let pianoW: CGFloat = 52
private let beatsPerMeasure = 4
/// Empty measures always kept free to the right of the last note/text, so there's
/// room to keep adding; the grid grows by another measure whenever content reaches
/// into this trailing band.
private let freeMeasures = 4
private let totalRows = hiPitch - loPitch + 1
private let gridH = CGFloat(totalRows) * rowH
private let textFontSize: CGFloat = 12
private let rulerH: CGFloat = 26
/// Shortest note the grid can hold, matching the 1/4-beat snap.
private let minLength: Double = 0.25
/// Slack for comparing snapped beat positions, so touching notes don't read as overlapping.
private let beatEpsilon: Double = 1e-9


// MARK: - EditingView

struct EditingView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    var exercise: Exercise? = nil

    @State private var notes: [MIDINote] = []
    @State private var texts: [MIDIText] = []
    @State private var interaction: Interaction = .idle
    @State private var tool: Tool = .pen

    // The pattern as it was when the editor opened. Edits are written through to
    // UserDefaults as they happen, so leaving without saving means putting this
    // snapshot back.
    @State private var savedNotes: [MIDINote] = []
    @State private var savedTexts: [MIDIText] = []
    @State private var didLoad = false
    @State private var showOverlapWarning = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toasts: ToastCenter

    // Text-entry sheet state.
    @State private var showTextEditor = false
    @State private var textInput = ""
    @State private var editingTextID: UUID? = nil
    @State private var isNewText = false

    // Playback state. The playhead is where the next playback run starts (set by
    // scrubbing the ruler); while playing, the drawn position comes from the audio
    // engine's own clock so the line tracks exactly what's being heard.
    @State private var player = ExercisePlayer()
    @State private var isPlaying = false
    @State private var playheadBeat: Double = 0
    @State private var playStartBeat: Double = 0
    @State private var engineStarted = false
    // Horizontal scroll offset + viewport size of the roll, so the fixed ruler can
    // draw in grid coordinates and auto-follow knows what's visible.
    @State private var scrollGeom = CGRect.zero
    @State private var scrollPos = ScrollPosition(edge: .leading)
    @Environment(\.scenePhase) private var scenePhase

    private enum Tool {
        case pen    // create / move / resize notes
        case text   // place / move / edit text labels
        case erase  // delete notes and text
        case hand   // pan & scroll (gesture disabled)
    }

    /// Which end of a note a drag is dragging: the start or the end of it.
    private enum ResizeEdge {
        case leading, trailing
    }

    private enum Interaction {
        case idle
        // `anchor` is the beat the press landed on; the note grows right from it, or
        // left from the right edge it started with.
        case creating(note: MIDINote, anchor: Double)
        // A press that landed on a beat no note can start on — another note already
        // sounds there, or there's too little room left before the next one. Nothing is
        // drawn yet: the note appears the moment the drag reaches free timeline either
        // side, butted up against the stretch that blocked it.
        case pendingNote(pitch: Int, origin: Double)
        case resizing(id: UUID, edge: ResizeEdge)
        case movingNote(id: UUID, grabDX: Double)
        case pendingText(CGPoint)
        case movingText(id: UUID, grabDX: Double, moved: Bool)
        case erasing
    }

    // Notes visible during an in-progress drag
    private var liveNotes: [MIDINote] {
        if case .creating(let n, _) = interaction { return notes + [n] }
        return notes
    }

    private var inProgressID: UUID? {
        if case .creating(let n, _) = interaction { return n.id }
        return nil
    }

    // MARK: - Dynamic grid width

    /// Furthest beat any content reaches: the end of the longest-reaching note or the
    /// right edge of the furthest text chip. Uses `liveNotes` so the grid grows live
    /// while a note is being dragged into the trailing free measures.
    private var contentEndBeat: Double {
        var maxBeat = 0.0
        for note in liveNotes { maxBeat = max(maxBeat, note.beat + note.length) }
        for label in texts { maxBeat = max(maxBeat, Double(textRect(for: label).maxX / beatW)) }
        return maxBeat
    }

    /// Whole measures of content (rounded up) plus `freeMeasures` empty ones, expressed
    /// in beats. A tiny epsilon keeps content that lands exactly on a measure line from
    /// counting as spilling into the next measure.
    private var totalBeats: Int {
        let contentMeasures = Int((contentEndBeat / Double(beatsPerMeasure) - 1e-6).rounded(.up))
        return (max(0, contentMeasures) + freeMeasures) * beatsPerMeasure
    }

    private var gridW: CGFloat { CGFloat(totalBeats) * beatW }

    private var bpm: Double { exercise?.bpm ?? 120 }

    var body: some View {
        VStack(spacing: 0) {
            rulerRow
            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    pianoKeysCanvas
                    ScrollView(.horizontal, showsIndicators: true) {
                        rollCanvas
                            .frame(width: gridW, height: gridH)
                            .overlay(alignment: .topLeading) { playheadOverlay }
                            .highPriorityGesture(rollGesture, including: tool == .hand ? .none : .all)
                    }
                    .scrollPosition($scrollPos)
                    .onScrollGeometryChange(for: CGRect.self) { g in
                        CGRect(origin: g.contentOffset, size: g.containerSize)
                    } action: { _, new in
                        scrollGeom = new
                    }
                }
            }
            transportBar
        }
        .background(Color.black)
        .navigationTitle(exercise?.localizedName ?? L("Editing"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { attemptLeave() } label: {
                    Label("Back", systemImage: "chevron.backward")
                        .labelStyle(.titleAndIcon)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 2) {
                    toolButton(.pen,   system: "pencil")
                    toolButton(.text,  system: "textformat")
                    toolButton(.erase, system: "eraser")
                    toolButton(.hand,  system: "hand.point.up.left")
                }
            }
        }
        .alert("Text", isPresented: $showTextEditor) {
            TextField("Label", text: $textInput)
            Button("OK") { commitText() }
            Button("Cancel", role: .cancel) { cancelText() }
        } message: {
            Text("Enter text to place on the grid")
        }
        .alert("Overlapping Notes", isPresented: $showOverlapWarning) {
            Button("Stay in Editor", role: .cancel) { }
            Button("Leave Without Saving", role: .destructive) { leaveDiscardingChanges() }
        } message: {
            Text("""
                 The sections marked red are sung at the same time as another note. \
                 An exercise can only have one note sounding at a time, so it can't be \
                 saved like this.

                 Go back and fix the red sections, or leave and discard the changes you \
                 made in this editor.
                 """)
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            loadNotes()
            loadTexts()
            savedNotes = notes
            savedTexts = texts
        }
        .onDisappear {
            isPlaying = false
            player.stop()
            if engineStarted {
                AudioRouteManager.shared.deactivateSession()
                engineStarted = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, isPlaying { stopPlayback() }
        }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            followPlayhead()
        }
        .onChange(of: notes) { _, _ in saveNotes() }
        .onChange(of: texts) { _, _ in saveTexts() }
    }

    // MARK: - Playback

    /// The beat the playhead is drawn at: the engine's live position while playing
    /// (so the line tracks the audio exactly), otherwise where the user parked it.
    private var displayBeat: Double {
        if isPlaying, let b = player.currentBeat(bpm: bpm, leadIn: 0) {
            return playStartBeat + max(0, b)
        }
        return playheadBeat
    }

    private func startPlayback(from startBeat: Double) {
        // Keep only what sounds at or after the playhead; a note straddling it is
        // clipped so just its remainder plays.
        let clipped: [MIDINote] = notes.compactMap { note in
            let end = note.beat + note.length
            guard end > startBeat else { return nil }
            var n = note
            n.beat = max(0, note.beat - startBeat)
            n.length = (end - startBeat) - n.beat
            return n
        }
        guard !clipped.isEmpty else { return }

        // Configure the route and start the engine on first play only; afterwards it
        // keeps running between runs so play/stop is instant.
        if !engineStarted {
            AudioRouteManager.shared.configureSession()
            player.begin()
            engineStarted = true
        }
        player.setClickMode(false)
        player.setInstrument(Instrument.current)
        playStartBeat = startBeat
        player.schedule(notes: clipped, bpm: bpm, leadIn: 0, preview: false) {
            isPlaying = false
            playheadBeat = playStartBeat
        }
        isPlaying = true
    }

    /// Silence the schedule and park the playhead back where this run started, so
    /// pressing play again repeats the same passage.
    private func stopPlayback() {
        player.cancelAll()
        isPlaying = false
        playheadBeat = playStartBeat
    }

    /// Keep the playhead on screen during playback: once it leaves the viewport,
    /// jump the scroll so it re-enters near the left edge.
    private func followPlayhead() {
        guard isPlaying, scrollGeom.width > 0 else { return }
        let x = CGFloat(displayBeat) * beatW
        if x > scrollGeom.maxX - 24 || x < scrollGeom.minX {
            let target = max(0, x - scrollGeom.width * 0.2)
            withAnimation(.easeInOut(duration: 0.2)) { scrollPos.scrollTo(x: target) }
        }
    }

    // MARK: - Leaving the editor

    /// The back button saves by leaving the written-through edits in place — unless
    /// notes are still sounding on top of each other, which the exercise can't
    /// represent, in which case the user has to choose what happens.
    private func attemptLeave() {
        if isPlaying { stopPlayback() }
        if hasOverlappingNotes {
            showOverlapWarning = true
        } else {
            dismiss()
        }
    }

    /// Put the pattern back the way it was when the editor opened, then pop. The
    /// pop's "Midi Saved!" toast is swallowed — nothing was saved.
    private func leaveDiscardingChanges() {
        notes = savedNotes
        texts = savedTexts
        writeNotes(savedNotes)
        writeTexts(savedTexts)
        toasts.suppressNext()
        dismiss()
    }

    // MARK: - Ruler & transport bar

    /// Fixed strip above the grid showing measure numbers and beat ticks, drawn in
    /// grid coordinates (shifted by the roll's scroll offset so it stays aligned).
    /// Tap or drag anywhere on it to move the playhead.
    private var rulerRow: some View {
        HStack(spacing: 0) {
            Color(white: 0.13).frame(width: pianoW)
            TimelineView(.animation(minimumInterval: nil, paused: !isPlaying)) { _ in
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.13)))
                    ctx.translateBy(x: -scrollGeom.minX, y: 0)

                    let first = max(0, Int(scrollGeom.minX / beatW))
                    let last = min(totalBeats, Int((scrollGeom.minX + size.width) / beatW) + 1)
                    if first <= last {
                        for beat in first...last {
                            let x = CGFloat(beat) * beatW
                            let isBar = beat % beatsPerMeasure == 0
                            var tick = Path()
                            tick.move(to: CGPoint(x: x, y: isBar ? size.height * 0.35 : size.height * 0.65))
                            tick.addLine(to: CGPoint(x: x, y: size.height))
                            ctx.stroke(tick, with: .color(white: isBar ? 0.6 : 0.35), lineWidth: 1)
                            if isBar {
                                ctx.draw(
                                    Text(verbatim: "\(beat / beatsPerMeasure + 1)")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(.gray),
                                    at: CGPoint(x: x + 3, y: 1),
                                    anchor: .topLeading
                                )
                            }
                        }
                    }

                    let px = CGFloat(displayBeat) * beatW
                    var marker = Path()
                    marker.move(to: CGPoint(x: px - 5, y: 0))
                    marker.addLine(to: CGPoint(x: px + 5, y: 0))
                    marker.addLine(to: CGPoint(x: px, y: 8))
                    marker.closeSubpath()
                    ctx.fill(marker, with: .color(.red))
                    var line = Path()
                    line.move(to: CGPoint(x: px, y: 0))
                    line.addLine(to: CGPoint(x: px, y: size.height))
                    ctx.stroke(line, with: .color(.red.opacity(0.9)), lineWidth: 1.5)
                }
                .gesture(rulerGesture)
            }
        }
        .frame(height: rulerH)
    }

    private var rulerGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if isPlaying { stopPlayback() }
                let beat = Double(v.location.x + scrollGeom.minX) / Double(beatW)
                playheadBeat = min(Double(totalBeats), max(0, snapped(beat)))
            }
    }

    /// Red line over the roll at the playhead, animated from the audio clock while
    /// playing. Drawn in its own overlay so the note canvas isn't redrawn per frame.
    private var playheadOverlay: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isPlaying)) { _ in
            Canvas { ctx, size in
                let x = CGFloat(displayBeat) * beatW
                guard x >= 0, x <= size.width else { return }
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(line, with: .color(.red.opacity(0.9)), lineWidth: 1.5)
            }
        }
        .frame(width: gridW, height: gridH)
        .allowsHitTesting(false)
    }

    private var transportBar: some View {
        HStack(spacing: 24) {
            Button {
                if isPlaying { stopPlayback() }
                playheadBeat = 0
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .accessibilityLabel("Go to Start")
            Button {
                isPlaying ? stopPlayback() : startPlayback(from: playheadBeat)
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 28)
            }
            .disabled(notes.isEmpty)
            .accessibilityLabel(isPlaying ? L("Stop") : L("Play"))
            TimelineView(.animation(minimumInterval: 0.1, paused: !isPlaying)) { _ in
                Text(verbatim: positionLabel(for: displayBeat))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(L("%d BPM", Int(bpm)))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.1))
        .foregroundStyle(.white)
    }

    /// "measure.beat" readout, 1-based, e.g. "3.2".
    private func positionLabel(for beat: Double) -> String {
        let b = max(0, beat)
        return "\(Int(b) / beatsPerMeasure + 1).\(Int(b) % beatsPerMeasure + 1)"
    }

    private func toolButton(_ t: Tool, system: String) -> some View {
        Button { tool = t } label: {
            Image(systemName: system)
                .padding(6)
                .background(tool == t ? Color.accentColor.opacity(0.2) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Piano key column

    private var pianoKeysCanvas: some View {
        Canvas { ctx, _ in
            for row in 0..<totalRows {
                let pitch = hiPitch - row
                let y = CGFloat(row) * rowH
                let bg: Color = isBlack(pitch) ? Color(white: 0.08) : Color(white: 0.88)
                ctx.fill(Path(CGRect(x: 0, y: y, width: pianoW, height: rowH)),
                         with: .color(bg))

                var sep = Path()
                sep.move(to: CGPoint(x: 0, y: y + rowH))
                sep.addLine(to: CGPoint(x: pianoW, y: y + rowH))
                ctx.stroke(sep, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)

                ctx.draw(
                    Text(pitchName(pitch))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(isBlack(pitch) ? .white : .black),
                    at: CGPoint(x: pianoW - 4, y: y + rowH / 2),
                    anchor: .trailing
                )
            }

            var border = Path()
            border.move(to: CGPoint(x: pianoW - 0.5, y: 0))
            border.addLine(to: CGPoint(x: pianoW - 0.5, y: gridH))
            ctx.stroke(border, with: .color(.gray.opacity(0.5)), lineWidth: 1)
        }
        .frame(width: pianoW, height: gridH)
    }

    // MARK: - Piano roll grid canvas

    private var rollCanvas: some View {
        let shown = liveNotes
        let overlaps = overlapSpans(in: shown)
        return Canvas { ctx, _ in
            // Row backgrounds
            for row in 0..<totalRows {
                let pitch = hiPitch - row
                let y = CGFloat(row) * rowH
                let bg: Color = isBlack(pitch) ? Color(white: 0.1) : Color(white: 0.17)
                ctx.fill(Path(CGRect(x: 0, y: y, width: gridW, height: rowH)), with: .color(bg))
            }

            // Horizontal row separators
            var hGrid = Path()
            for row in 0...totalRows {
                let y = CGFloat(row) * rowH
                hGrid.move(to: CGPoint(x: 0, y: y))
                hGrid.addLine(to: CGPoint(x: gridW, y: y))
            }
            ctx.stroke(hGrid, with: .color(white: 0.22), lineWidth: 0.5)

            // Vertical beat lines
            for beat in 0...totalBeats {
                let x = CGFloat(beat) * beatW
                let isBar = beat % 4 == 0
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: gridH))
                ctx.stroke(line,
                           with: .color(white: isBar ? 0.45 : 0.25),
                           lineWidth: isBar ? 1.5 : 0.5)
            }

            // Notes
            for note in shown {
                let rect = rect(for: note)
                let inner = rect.insetBy(dx: 1, dy: 1)
                let dimmed = note.id == inProgressID
                let notePath = Path(roundedRect: inner, cornerRadius: 3)
                ctx.fill(notePath, with: .color(.green.opacity(dimmed ? 0.6 : 0.88)))
                ctx.stroke(notePath, with: .color(.green), lineWidth: 1)

                // Paint the stretches another note sounds over, so it's clear which
                // part of the note is the problem rather than just which notes are.
                if let spans = overlaps[note.id] {
                    for span in spans {
                        let x0 = max(inner.minX, CGFloat(span.start) * beatW)
                        let x1 = min(inner.maxX, CGFloat(span.end) * beatW)
                        guard x1 > x0 else { continue }
                        let bad = CGRect(x: x0, y: inner.minY,
                                         width: x1 - x0, height: inner.height)
                        ctx.fill(Path(roundedRect: bad, cornerRadius: 2),
                                 with: .color(.red.opacity(dimmed ? 0.7 : 0.95)))
                    }
                    ctx.stroke(notePath, with: .color(.red), lineWidth: 1.5)
                }

                if inner.width > 20 {
                    ctx.draw(
                        Text(pitchName(note.pitch))
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.black),
                        at: CGPoint(x: inner.minX + 3, y: inner.midY),
                        anchor: .leading
                    )
                }
            }

            // Text labels
            for label in texts {
                let rect = textRect(for: label)
                let chip = Path(roundedRect: rect.insetBy(dx: 1, dy: 3), cornerRadius: 3)
                ctx.fill(chip, with: .color(.orange.opacity(0.22)))
                ctx.stroke(chip, with: .color(.orange.opacity(0.6)), lineWidth: 1)
                ctx.draw(
                    Text(label.text.isEmpty ? " " : label.text)
                        .font(.system(size: textFontSize, weight: .semibold))
                        .foregroundColor(.orange),
                    at: CGPoint(x: rect.minX + 5, y: rect.midY),
                    anchor: .leading
                )
            }
        }
    }

    // MARK: - Gesture

    private var rollGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                switch tool {
                case .pen:   penChanged(v)
                case .text:  textChanged(v)
                case .erase: eraseChanged(v)
                case .hand:  break
                }
            }
            .onEnded { v in
                switch tool {
                case .pen:   penEnded(v)
                case .text:  textEnded(v)
                case .erase: interaction = .idle
                case .hand:  break
                }
            }
    }

    // MARK: Pen tool — create, move, resize notes (no delete)

    private func penChanged(_ v: DragGesture.Value) {
        switch interaction {
        case .idle:
            if let hit = noteAt(v.startLocation) {
                if let edge = resizeEdge(of: hit, x: v.startLocation.x) {
                    interaction = .resizing(id: hit.id, edge: edge)
                } else {
                    interaction = .movingNote(id: hit.id,
                                              grabDX: beatValue(v.startLocation.x) - hit.beat)
                }
            } else {
                // Only one note may sound at a time, so a press that lands on a beat
                // another note already covers — even several rows away — draws nothing
                // yet; it waits to see whether the drag leaves the taken stretch.
                let start = snappedBeat(v.startLocation.x)
                guard !isOccupied(start), spaceAfter(start) >= minLength else {
                    interaction = .pendingNote(pitch: pitchAt(v.startLocation.y), origin: start)
                    break
                }
                let note = MIDINote(
                    pitch: pitchAt(v.startLocation.y),
                    beat: start,
                    length: minLength
                )
                interaction = .creating(note: note, anchor: start)
            }

        case .pendingNote(let pitch, let origin):
            // The drag started over a beat that was already taken. As soon as it reaches
            // free timeline the note begins there, as if the press had landed as close to
            // the blocking note as a note can start — on whichever side the drag went.
            let pointer = beatValue(v.location.x)
            let from = beatValue(v.startLocation.x)
            if pointer > from, let anchor = nextFreeStart(atOrAfter: origin), pointer >= anchor {
                let note = MIDINote(pitch: pitch, beat: anchor, length: minLength)
                interaction = .creating(note: grown(note, anchor: anchor, pointer: pointer),
                                        anchor: anchor)
            } else if pointer < from, let end = previousFreeEnd(atOrBefore: origin), pointer <= end {
                let anchor = end - minLength
                let note = MIDINote(pitch: pitch, beat: anchor, length: minLength)
                interaction = .creating(note: grown(note, anchor: anchor, pointer: pointer),
                                        anchor: anchor)
            }

        case .creating(let note, let anchor):
            interaction = .creating(note: grown(note, anchor: anchor,
                                                pointer: beatValue(v.location.x)),
                                    anchor: anchor)

        case .resizing(let id, let edge):
            if let i = notes.firstIndex(where: { $0.id == id }) {
                let pointer = beatValue(v.location.x)
                switch edge {
                case .trailing:
                    notes[i].length = min(max(minLength, snapped(pointer - notes[i].beat)),
                                          spaceAfter(notes[i].beat, excluding: id))
                case .leading:
                    // Dragging the start of the note: the end of it stays put.
                    let rightEdge = notes[i].beat + notes[i].length
                    let leftLimit = rightEdge - spaceBefore(rightEdge, excluding: id)
                    let beat = min(max(snapped(pointer), leftLimit), rightEdge - minLength)
                    notes[i].beat = beat
                    notes[i].length = rightEdge - beat
                }
            }

        case .movingNote(let id, let grabDX):
            if let i = notes.firstIndex(where: { $0.id == id }) {
                let desired = max(0, snapped(beatValue(v.location.x) - grabDX))
                notes[i].beat = placement(desired: desired,
                                          length: notes[i].length,
                                          excluding: id) ?? notes[i].beat
                notes[i].pitch = pitchAt(v.location.y)
            }

        default:
            break
        }
    }

    private func penEnded(_ v: DragGesture.Value) {
        switch interaction {
        case .creating(let note, _):
            notes.append(note)

        case .pendingNote:
            // Never left the taken stretch, so nothing was drawn — say why, since the
            // press looks like it should have worked.
            toasts.show(L("Notes Can't Overlap"), icon: "exclamationmark.triangle.fill")

        default:
            break
        }
        interaction = .idle
    }

    /// The note being drawn, stretched to the pointer: right of `anchor` it grows right
    /// from that edge, left of it the right edge the note started with stays put. Either
    /// way it stops at the notes on both sides of it.
    private func grown(_ note: MIDINote, anchor: Double, pointer: Double) -> MIDINote {
        var note = note
        if pointer >= anchor {
            note.beat = anchor
            note.length = min(max(minLength, snapped(pointer - anchor)), spaceAfter(anchor))
        } else {
            let rightEdge = anchor + minLength
            let leftLimit = rightEdge - spaceBefore(rightEdge)
            note.beat = min(max(snapped(pointer), leftLimit), anchor)
            note.length = rightEdge - note.beat
        }
        return note
    }

    // MARK: Text tool — place, move, edit labels

    private func textChanged(_ v: DragGesture.Value) {
        switch interaction {
        case .idle:
            if let hit = textAt(v.startLocation) {
                interaction = .movingText(id: hit.id,
                                          grabDX: beatValue(v.startLocation.x) - hit.beat,
                                          moved: false)
            } else {
                interaction = .pendingText(v.startLocation)
            }

        case .movingText(let id, let grabDX, _):
            let moved = hypot(v.translation.width, v.translation.height) > 6
            if moved, let i = texts.firstIndex(where: { $0.id == id }) {
                texts[i].beat = max(0, snapped(beatValue(v.location.x) - grabDX))
                texts[i].pitch = pitchAt(v.location.y)
            }
            interaction = .movingText(id: id, grabDX: grabDX, moved: moved)

        default:
            break
        }
    }

    private func textEnded(_ v: DragGesture.Value) {
        switch interaction {
        case .pendingText(let p):
            let label = MIDIText(text: "", pitch: pitchAt(p.y), beat: snappedBeat(p.x))
            texts.append(label)
            beginEditingText(label.id, isNew: true)

        case .movingText(let id, _, let moved):
            // A tap (no drag) opens the editor for that label.
            if !moved { beginEditingText(id, isNew: false) }

        default:
            break
        }
        interaction = .idle
    }

    private func beginEditingText(_ id: UUID, isNew: Bool) {
        editingTextID = id
        isNewText = isNew
        textInput = texts.first(where: { $0.id == id })?.text ?? ""
        showTextEditor = true
    }

    private func commitText() {
        guard let id = editingTextID else { return }
        let trimmed = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            texts.removeAll { $0.id == id }
        } else if let i = texts.firstIndex(where: { $0.id == id }) {
            texts[i].text = trimmed
        }
        editingTextID = nil
    }

    private func cancelText() {
        // Discard a label that was created just for this edit.
        if isNewText, let id = editingTextID {
            texts.removeAll { $0.id == id }
        }
        editingTextID = nil
    }

    // MARK: Erase tool — scrub over notes and text to delete

    private func eraseChanged(_ v: DragGesture.Value) {
        if let n = noteAt(v.location) {
            notes.removeAll { $0.id == n.id }
        } else if let t = textAt(v.location) {
            texts.removeAll { $0.id == t.id }
        }
        interaction = .erasing
    }

    // MARK: - Overlap rules
    //
    // An exercise is sung, so only one note may sound at any moment: two notes must
    // never share a stretch of the timeline, no matter how far apart their pitches
    // are. Editing clamps every placement to keep that true; anything that slipped
    // through anyway (an older pattern, a downloaded one) is drawn red instead.

    /// Free stretches of the timeline, as `(start, end)` beat pairs, with `id`'s own
    /// note left out. The last stretch runs to infinity.
    private func freeGaps(excluding id: UUID?) -> [(start: Double, end: Double)] {
        var gaps: [(start: Double, end: Double)] = []
        var cursor = 0.0
        for note in notes.filter({ $0.id != id }).sorted(by: { $0.beat < $1.beat }) {
            if note.beat > cursor + beatEpsilon { gaps.append((cursor, note.beat)) }
            cursor = max(cursor, note.beat + note.length)
        }
        gaps.append((cursor, .infinity))
        return gaps
    }

    /// Is some note already sounding at `beat`?
    private func isOccupied(_ beat: Double, excluding id: UUID? = nil) -> Bool {
        notes.contains { note in
            note.id != id
                && beat >= note.beat - beatEpsilon
                && beat < note.beat + note.length - beatEpsilon
        }
    }

    /// How long a note starting at `beat` may grow before it runs into the next one.
    private func spaceAfter(_ beat: Double, excluding id: UUID? = nil) -> Double {
        let next = notes
            .filter { $0.id != id && $0.beat > beat + beatEpsilon }
            .map(\.beat)
            .min()
        return (next ?? .infinity) - beat
    }

    /// How far a note ending at `beat` may grow leftwards before it runs into the
    /// previous one, or the start of the timeline.
    private func spaceBefore(_ beat: Double, excluding id: UUID? = nil) -> Double {
        let previousEnd = notes
            .filter { $0.id != id && $0.beat + $0.length < beat + beatEpsilon }
            .map { $0.beat + $0.length }
            .max()
        return beat - max(0, previousEnd ?? 0)
    }

    /// The first beat from `origin` rightwards a new note may start on: `origin` itself
    /// when there's room, otherwise the end of whatever is in the way. `nil` if nothing
    /// to the right can hold a note.
    private func nextFreeStart(atOrAfter origin: Double) -> Double? {
        for gap in freeGaps(excluding: nil) {
            let start = max(gap.start, origin)
            if gap.end - start >= minLength - beatEpsilon { return start }
        }
        return nil
    }

    /// The last beat up to `origin` a new note may end on: `origin` itself when there's
    /// room in front of it, otherwise the start of whatever is in the way. `nil` if
    /// nothing to the left can hold a note.
    private func previousFreeEnd(atOrBefore origin: Double) -> Double? {
        var result: Double? = nil
        for gap in freeGaps(excluding: nil) where gap.start <= origin + beatEpsilon {
            let end = min(gap.end, origin)
            if end - gap.start >= minLength - beatEpsilon { result = end }
        }
        return result
    }

    /// Where a note of `length` dragged to `desired` may actually land: inside the free
    /// gap the drag is centred on, or the nearest gap big enough if that one is taken.
    /// `nil` when nothing on the timeline can hold it.
    private func placement(desired: Double, length: Double, excluding id: UUID?) -> Double? {
        let fitting = freeGaps(excluding: id).filter { $0.end - $0.start >= length - beatEpsilon }
        guard !fitting.isEmpty else { return nil }
        let centre = desired + length / 2
        let gap = fitting.first { centre >= $0.start && centre <= $0.end }
            ?? fitting.min { distance(from: centre, to: $0) < distance(from: centre, to: $1) }!
        return min(max(desired, gap.start), gap.end - length)
    }

    private func distance(from beat: Double, to gap: (start: Double, end: Double)) -> Double {
        if beat < gap.start { return gap.start - beat }
        if beat > gap.end { return beat - gap.end }
        return 0
    }

    /// Stretches of each note that another note is sounding over, merged per note so
    /// the red overlay is drawn once per region.
    private func overlapSpans(in all: [MIDINote]) -> [UUID: [(start: Double, end: Double)]] {
        var result: [UUID: [(start: Double, end: Double)]] = [:]
        for (i, a) in all.enumerated() {
            var spans: [(start: Double, end: Double)] = []
            for (j, b) in all.enumerated() where i != j {
                let start = max(a.beat, b.beat)
                let end = min(a.beat + a.length, b.beat + b.length)
                if end - start > beatEpsilon { spans.append((start, end)) }
            }
            guard !spans.isEmpty else { continue }
            var merged: [(start: Double, end: Double)] = []
            for span in spans.sorted(by: { $0.start < $1.start }) {
                if let last = merged.last, span.start <= last.end + beatEpsilon {
                    merged[merged.count - 1].end = max(last.end, span.end)
                } else {
                    merged.append(span)
                }
            }
            result[a.id] = merged
        }
        return result
    }

    /// Whether any two notes currently sound at the same time.
    private var hasOverlappingNotes: Bool {
        var cursor = -Double.infinity
        for note in notes.sorted(by: { $0.beat < $1.beat }) {
            if note.beat < cursor - beatEpsilon { return true }
            cursor = max(cursor, note.beat + note.length)
        }
        return false
    }

    // MARK: - Coordinate helpers

    private func rect(for note: MIDINote) -> CGRect {
        CGRect(
            x: CGFloat(note.beat) * beatW,
            y: CGFloat(hiPitch - note.pitch) * rowH,
            width: CGFloat(note.length) * beatW,
            height: rowH
        )
    }

    private func textRect(for label: MIDIText) -> CGRect {
        let w = max(beatW * 0.5, CGFloat(label.text.count) * textFontSize * 0.62 + 12)
        return CGRect(
            x: CGFloat(label.beat) * beatW,
            y: CGFloat(hiPitch - label.pitch) * rowH,
            width: w,
            height: rowH
        )
    }

    private func noteAt(_ point: CGPoint) -> MIDINote? {
        notes.last { rect(for: $0).contains(point) }
    }

    private func textAt(_ point: CGPoint) -> MIDIText? {
        texts.last { textRect(for: $0).contains(point) }
    }

    /// Which end of `note` a press at `x` takes hold of, or `nil` for the middle of it,
    /// which moves the note instead. The grab zones shrink along with the note so even
    /// the shortest one keeps a middle to move it by.
    private func resizeEdge(of note: MIDINote, x: CGFloat) -> ResizeEdge? {
        let box = rect(for: note)
        let zone = min(14, box.width / 3)
        if x - box.minX < zone { return .leading }
        if box.maxX - x < zone { return .trailing }
        return nil
    }

    private func pitchAt(_ y: CGFloat) -> Int {
        let row = Int(y / rowH)
        return max(loPitch, min(hiPitch, hiPitch - row))
    }

    private func beatValue(_ x: CGFloat) -> Double {
        Double(x) / Double(beatW)
    }

    private func snappedBeat(_ x: CGFloat) -> Double {
        snapped(beatValue(x))
    }

    private func snapped(_ beats: Double) -> Double {
        (beats * 4).rounded(.down) / 4  // snap to 1/4 beat
    }

    // MARK: - Persistence

    private var saveKey: String {
        "midi_\(exercise?.id.uuidString ?? "standalone")"
    }

    private var textSaveKey: String {
        "miditext_\(exercise?.id.uuidString ?? "standalone")"
    }

    private func saveNotes() { writeNotes(notes) }

    private func writeNotes(_ value: [MIDINote]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: saveKey)
        scheduleServerSync()
    }

    private func loadNotes() {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let saved = try? JSONDecoder().decode([MIDINote].self, from: data)
        else { return }
        notes = saved
    }

    private func saveTexts() { writeTexts(texts) }

    private func writeTexts(_ value: [MIDIText]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: textSaveKey)
        scheduleServerSync()
    }

    /// Pattern edits write to UserDefaults directly, bypassing the store the
    /// server syncs observe — so kick them explicitly. Keeps a public exercise's
    /// server copy current without toggling its visibility.
    private func scheduleServerSync() {
        guard exercise != nil else { return }
        ProfileSync.shared.scheduleUpload()
        CommunitySync.shared.scheduleUpload()
    }

    private func loadTexts() {
        guard let data = UserDefaults.standard.data(forKey: textSaveKey),
              let saved = try? JSONDecoder().decode([MIDIText].self, from: data)
        else { return }
        texts = saved
    }
}
