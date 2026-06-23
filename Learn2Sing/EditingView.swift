import SwiftUI

// MARK: - Model

struct MIDINote: Identifiable, Codable, Equatable {
    var id = UUID()
    var pitch: Int      // MIDI pitch number
    var beat: Double    // start position in beats
    var length: Double  // duration in beats
}

// MARK: - Layout constants

private let rowH: CGFloat = 22
private let beatW: CGFloat = 52
private let pianoW: CGFloat = 52
private let totalBeats = 32
private let totalRows = hiPitch - loPitch + 1
private let gridW = CGFloat(totalBeats) * beatW
private let gridH = CGFloat(totalRows) * rowH


// MARK: - EditingView

struct EditingView: View {
    var exercise: Exercise? = nil

    @State private var notes: [MIDINote] = []
    @State private var interaction: Interaction = .idle
    @State private var drawMode = true

    private enum Interaction {
        case idle
        case creating(MIDINote)
        case resizing(UUID)
        case pendingDelete(UUID)
    }

    // Notes visible during an in-progress drag
    private var liveNotes: [MIDINote] {
        if case .creating(let n) = interaction { return notes + [n] }
        return notes
    }

    private var inProgressID: UUID? {
        if case .creating(let n) = interaction { return n.id }
        return nil
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                pianoKeysCanvas
                ScrollView(.horizontal, showsIndicators: true) {
                    rollCanvas
                        .frame(width: gridW, height: gridH)
                        .highPriorityGesture(rollGesture, including: drawMode ? .all : .none)
                }
            }
        }
        .background(Color.black)
        .navigationTitle(exercise?.name ?? "Editing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 2) {
                    Button { drawMode = true } label: {
                        Image(systemName: "pencil")
                            .padding(6)
                            .background(drawMode ? Color.accentColor.opacity(0.2) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    Button { drawMode = false } label: {
                        Image(systemName: "hand.point.up.left")
                            .padding(6)
                            .background(!drawMode ? Color.accentColor.opacity(0.2) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .onAppear(perform: loadNotes)
        .onChange(of: notes) { _, _ in saveNotes() }
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

                if !isBlack(pitch) {
                    ctx.draw(
                        Text(pitchName(pitch))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.black),
                        at: CGPoint(x: pianoW - 4, y: y + rowH / 2),
                        anchor: .trailing
                    )
                }
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
        Canvas { ctx, _ in
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
            for note in liveNotes {
                let rect = rect(for: note)
                let inner = rect.insetBy(dx: 1, dy: 1)
                let dimmed = note.id == inProgressID
                let notePath = Path(roundedRect: inner, cornerRadius: 3)
                ctx.fill(notePath, with: .color(.green.opacity(dimmed ? 0.6 : 0.88)))
                ctx.stroke(notePath, with: .color(.green), lineWidth: 1)

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
        }
    }

    // MARK: - Gesture

    private var rollGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                switch interaction {
                case .idle:
                    if let hit = noteAt(v.startLocation) {
                        if nearRightEdge(hit, x: v.startLocation.x) {
                            interaction = .resizing(hit.id)
                        } else {
                            interaction = .pendingDelete(hit.id)
                        }
                    } else {
                        let note = MIDINote(
                            pitch: pitchAt(v.startLocation.y),
                            beat: snappedBeat(v.startLocation.x),
                            length: 0.25
                        )
                        interaction = .creating(note)
                    }

                case .creating(var note):
                    let endBeat = Double(v.location.x) / Double(beatW)
                    note.length = max(0.25, snapped(endBeat - note.beat))
                    interaction = .creating(note)

                case .resizing(let id):
                    if let i = notes.firstIndex(where: { $0.id == id }) {
                        let endBeat = Double(v.location.x) / Double(beatW)
                        notes[i].length = max(0.25, snapped(endBeat - notes[i].beat))
                    }

                case .pendingDelete:
                    if hypot(v.translation.width, v.translation.height) > 8 {
                        interaction = .idle
                    }
                }
            }
            .onEnded { _ in
                switch interaction {
                case .creating(let note):
                    notes.append(note)
                case .pendingDelete(let id):
                    notes.removeAll { $0.id == id }
                default:
                    break
                }
                interaction = .idle
            }
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

    private func noteAt(_ point: CGPoint) -> MIDINote? {
        notes.last { rect(for: $0).contains(point) }
    }

    private func nearRightEdge(_ note: MIDINote, x: CGFloat) -> Bool {
        rect(for: note).maxX - x < 14
    }

    private func pitchAt(_ y: CGFloat) -> Int {
        let row = Int(y / rowH)
        return max(loPitch, min(hiPitch, hiPitch - row))
    }

    private func snappedBeat(_ x: CGFloat) -> Double {
        snapped(Double(x) / Double(beatW))
    }

    private func snapped(_ beats: Double) -> Double {
        (beats * 4).rounded(.down) / 4  // snap to 1/4 beat
    }

    // MARK: - Persistence

    private var saveKey: String {
        "midi_\(exercise?.id.uuidString ?? "standalone")"
    }

    private func saveNotes() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(data, forKey: saveKey)
    }

    private func loadNotes() {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let saved = try? JSONDecoder().decode([MIDINote].self, from: data)
        else { return }
        notes = saved
    }
}
