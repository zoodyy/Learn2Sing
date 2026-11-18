import SwiftUI
import Combine
import UIKit

// MARK: - Model

extension CodingUserInfoKey {
    /// Set on an encoder to leave every note's and label's `id` out of the JSON
    /// it writes. A pattern's ids mean nothing outside the device that made it —
    /// nothing stored refers to them, and a decode without them mints fresh ones
    /// — but at 36 characters each they were the single biggest thing in the
    /// synced profile document, which has a hard size limit to fit inside (see
    /// `ProfileSync.uploadBody`, the only place that sets this).
    ///
    /// Only that document leaves them out. Local storage keeps them, so ids stay
    /// stable while the editor is working with a pattern, and so do the community
    /// documents, which older installs still decode with a synthesised
    /// initialiser that would throw on a missing key.
    nonisolated static let omitPatternIDs = CodingUserInfoKey(rawValue: "omitPatternIDs")!
}

nonisolated struct MIDINote: Identifiable, Codable, Equatable {
    var id = UUID()
    var pitch: Int      // MIDI pitch number
    var beat: Double    // start position in beats
    var length: Double  // duration in beats

    init(id: UUID = UUID(), pitch: Int, beat: Double, length: Double) {
        self.id = id
        self.pitch = pitch
        self.beat = beat
        self.length = length
    }

    private enum CodingKeys: String, CodingKey { case id, pitch, beat, length }

    // Emit the id lowercase so every UUID in the community request body is
    // lowercase; UUID decoding is case-insensitive, so this round-trips.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if encoder.userInfo[.omitPatternIDs] == nil {
            try c.encode(id.uuidString.lowercased(), forKey: .id)
        }
        try c.encode(pitch, forKey: .pitch)
        try c.encode(beat, forKey: .beat)
        try c.encode(length, forKey: .length)
    }

    // Written by hand rather than synthesised: a synthesised initialiser throws
    // on a missing `id` instead of falling back to the default value above, and
    // documents written without one have to decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pitch = try c.decode(Int.self, forKey: .pitch)
        beat = try c.decode(Double.self, forKey: .beat)
        length = try c.decode(Double.self, forKey: .length)
        // Held to a MIDI note and a place in the pattern whatever the document
        // says (see ExerciseLimits): a pitch far outside the keyboard overflows
        // the arithmetic that draws and plays it.
        self = withinLimits()
    }
}

/// A free-floating text label placed on the grid. It shares the note coordinate
/// system (a `pitch` row for vertical position, a `beat` for horizontal) so it
/// scrolls in lockstep with the notes during playback.
nonisolated struct MIDIText: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var pitch: Int      // row position (vertical)
    var beat: Double    // start position in beats (horizontal)
    /// Where each note around this label lies from its middle, nearest first, leaving
    /// out a note whose beats the middle sits in. Set by `Exercise.timeline(...)`,
    /// together with `tempoScale`, for a screen to keep the text clear of notes a
    /// faster repetition squeezes in on it (see `noteFitScale`). Never stored: it
    /// belongs to a laid-out timeline, not to the label the editor saved.
    var noteGaps: [NoteGap] = []
    /// One note as `noteGaps` lists it.
    nonisolated struct NoteGap: Equatable {
        /// How far the note's nearer end is from the label's middle, to either side,
        /// in beats at the tempo the pattern was written at.
        var beats: Double
        /// How many rows above the label's row the note is: negative below it, 0 on
        /// the same row.
        var rows: Int
    }
    /// How far the repetition this label is drawn in squeezes the written beats: 1 at
    /// the written tempo, less on one sped up by "speed up per repetition". Set by
    /// `Exercise.timeline(...)`; never stored either.
    var tempoScale: Double = 1

    init(id: UUID = UUID(), text: String, pitch: Int, beat: Double) {
        self.id = id
        self.text = text
        self.pitch = pitch
        self.beat = beat
    }

    private enum CodingKeys: String, CodingKey { case id, text, pitch, beat }

    // Emit the id lowercase so every UUID in the community request body is
    // lowercase; UUID decoding is case-insensitive, so this round-trips.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if encoder.userInfo[.omitPatternIDs] == nil {
            try c.encode(id.uuidString.lowercased(), forKey: .id)
        }
        try c.encode(text, forKey: .text)
        try c.encode(pitch, forKey: .pitch)
        try c.encode(beat, forKey: .beat)
    }

    // Hand-written for the same reason as `MIDINote`'s: a missing `id` has to
    // decode to a fresh one rather than throw.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        pitch = try c.decode(Int.self, forKey: .pitch)
        beat = try c.decode(Double.self, forKey: .beat)
        // The same as a note's, and the text cut to a label's length: a label is
        // drawn as wide as what it says.
        self = withinLimits()
    }
}

// MARK: - Text label geometry
//
// A label's stored `beat` is its left edge, but what the user places is its middle:
// the editor snaps by the middle and grows the text either side of it. Playback and
// the review screen draw labels from the same numbers, so the conversion between the
// two lives here rather than in the editor — a label lands where the editor showed
// it on every screen. The width is in points, so turning it into beats means the
// scale the editor laid it out at (`beatW`), whatever a playing screen is zoomed to.

/// How wide the chip around `text` is drawn: the text at the width it actually lays
/// out at, plus the same padding either side of it. An empty label — one still being
/// typed — keeps a half-beat chip so there's something to see.
func midiTextChipWidth(_ text: String) -> CGFloat {
    max(beatW * 0.5, TextWidths.width(of: text) + textChipPadding * 2)
}

/// The size the labels are written at, and the size a screen draws one at unless it's
/// shrunk to keep clear of its neighbours (see TextLabelFit.swift) — the size
/// `midiTextChipWidth` measures against.
let midiTextFontSize: CGFloat = 12

/// Half the room a label reading `text` takes, in beats: the same points-to-beats
/// conversion `centreBeat` makes, for callers that need the width itself rather than
/// where the middle lands.
func midiTextHalfWidth(_ text: String) -> Double {
    Double(midiTextChipWidth(text) / beatW) / 2
}

/// The start beat — what's stored — that puts `text`'s middle on `centre`. A label
/// may hang off the front of the timeline, but only as far as staying centred on
/// `firstNoteCentre` — the middle of the exercise's first note — carries it, so a
/// long label over a note near the start keeps its place over that note instead of
/// being shoved right. With no note to centre on it stops at the start line.
func midiTextBeat(centring text: String, at centre: Double, firstNoteCentre: Double? = nil) -> Double {
    let half = midiTextHalfWidth(text)
    return max(centre, min(half, firstNoteCentre ?? half)) - half
}

extension MIDIText {
    /// Where this label sits on the timeline: its middle, not the `beat` it starts
    /// on. Text is placed, dragged and snapped by this, so a label stays put on the
    /// beat it was set against however long its text gets — and it's what a screen
    /// drawing the label should centre it on.
    ///
    /// Settable, since a screen that lays the pattern out somewhere else — the
    /// timeline expansion moving a repetition to its own tempo — has to move the
    /// middle and let the stored left edge follow, not the other way round. The width
    /// it converts is the written one: a label shrunk to keep clear of its neighbours
    /// shrinks about this middle and stays where it was placed.
    var centreBeat: Double {
        get { beat + midiTextHalfWidth(text) }
        set { beat = newValue - midiTextHalfWidth(text) }
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
/// Gap between a text label's edge and the text inside it, the same on both sides.
private let textChipPadding: CGFloat = 5
private let rulerH: CGFloat = 26
/// Shortest note the grid can hold, matching the 1/4-beat snap.
private let minLength: Double = 0.25
/// Slack for comparing snapped beat positions, so touching notes don't read as overlapping.
private let beatEpsilon: Double = 1e-9
/// How many ghost notes may sound at the same moment: a chord of five, which is as
/// many notes as a hand plays.
private let maxGhostsAtOnce = 5
/// What the stretch of a note a ghost note of the same pitch lies over is painted:
/// plain to see against the green, without the alarm of the red that marks
/// overlapping notes.
private let ghostOverNoteColor = Color.cyan
/// How near an edge of the roll a drag has to bring the finger before the roll scrolls
/// that way (see `edgeScrollVelocity`).
private let edgeScrollZone: CGFloat = 44
/// How much closer to an edge than it pressed a drag has to come before the roll scrolls
/// that way, so a press that lands near an edge, and a finger wavering there, leave the
/// roll where it is.
private let edgeScrollSlop: CGFloat = 10
/// How fast the roll scrolls with the finger at an edge or past it, in points a second:
/// screen points, and points of the roll's own space too, whichever is reached first
/// at the zoom it's at. No more than a quarter-beat note's width a frame at 60 frames a
/// second through the roll itself, so the eraser can't skip one as the roll runs under
/// it however far out it's zoomed.
private let edgeScrollMaxSpeed: CGFloat = 700
/// How long the roll takes to reach the speed the finger asks for, so it never sets off
/// with a jolt.
private let edgeScrollEaseIn: CFTimeInterval = 0.2


// MARK: - EditingView

struct EditingView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    var exercise: Exercise? = nil

    @State private var notes: [MIDINote] = []
    @State private var texts: [MIDIText] = []
    /// The notes drawn with the ghost tool: played, but never sung or scored. See
    /// `NoteLayer`.
    @State private var ghosts: [MIDINote] = []
    @State private var interaction: Interaction = .idle
    @State private var tool: Tool = .pen

    // The pattern as it was when the editor opened. Edits are written through to
    // UserDefaults as they happen, so leaving without saving means putting this
    // snapshot back.
    @State private var savedNotes: [MIDINote] = []
    @State private var savedTexts: [MIDIText] = []
    @State private var savedGhosts: [MIDINote] = []
    /// The exercise's dates as they were when the editor opened, which leaving
    /// without saving puts back along with the pattern (see ExerciseDates).
    @State private var savedDates: ExerciseTimestamps?
    /// The exercise's tempo as it was when the editor opened. The slider the BPM
    /// readout opens changes it in here, so leaving without saving puts it back too.
    @State private var savedBPM: Double?
    @State private var showOverlapWarning = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var store: ExerciseStore

    /// Whether the tempo slider is out, opened and closed by tapping the BPM readout.
    @State private var showsTempo = false

    /// Set when the note under the finger stopped short of where it was dragged
    /// because the run would have lasted longer than the limit allows, so the toast
    /// saying so goes up when the finger lifts rather than on every move.
    @State private var hitLengthLimit = false

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
    /// Where the roll is scrolled to and how far it's zoomed, which the keys, the ruler
    /// and the grid are all drawn through (see RollCamera.swift). Opens scrolled down
    /// to where `openingOffset` puts it, until `rollTouched`. Only the canvases watch
    /// it, so the body never reads what it shows.
    @State private var camera = RollCamera()
    /// Set the first time the roll is scrolled, zoomed or drawn on. From then on it
    /// stays where the user has it, whatever happens to its height.
    @State private var rollTouched = false
    /// Scrolls the roll while a drag holds the finger near one of its edges.
    @State private var edge = RollEdgeScroll()
    /// Whether the press on the roll is still the tools', and the pattern from before
    /// they did anything with it, for when two fingers take it over.
    @State private var press = RollPress()
    /// Whether a finger is down on the roll. Unlike the drag's end, this also goes
    /// back when the system cancels the drag, which has to stop edge scrolling too.
    @GestureState private var fingerOnRoll = false
    @Environment(\.scenePhase) private var scenePhase

    init(exercise: Exercise? = nil) {
        self.exercise = exercise
        // Read here rather than on appear, so the roll's very first layout already
        // has the pattern it opens scrolled to (see `openingOffset`). State only
        // takes these the first time; a later init's are thrown away.
        // No more of each than a pattern may hold (see ExerciseLimits), as the
        // store reads them everywhere else: a pattern downloaded before the limits
        // existed is whatever its document held.
        let notes = loadPattern([MIDINote].self, forKey: saveKey)
            .capped(at: ExerciseLimits.notesPerRepetition)
        let texts = loadPattern([MIDIText].self, forKey: textSaveKey)
            .capped(at: ExerciseLimits.labelsPerRepetition)
        let ghosts = loadPattern([MIDINote].self, forKey: ghostSaveKey)
            .capped(at: ExerciseLimits.ghostsPerRepetition)
        _notes = State(initialValue: notes)
        _texts = State(initialValue: texts)
        _ghosts = State(initialValue: ghosts)
        _savedNotes = State(initialValue: notes)
        _savedTexts = State(initialValue: texts)
        _savedGhosts = State(initialValue: ghosts)
        _savedDates = State(initialValue: exercise.flatMap { ExerciseDates.timestamps(for: $0.id) })
        _savedBPM = State(initialValue: exercise?.bpm)
    }

    private enum Tool {
        case pen    // create / move / resize notes
        case text   // place / move / edit text labels
        case erase  // delete notes, ghost notes and text
        case hand   // one finger scrolls the roll too (the tools' drag is off)
        case ghost  // create / move / resize ghost notes, exactly as the pen does notes
    }

    /// The two kinds of note on the roll. The melody is what the exercise is sung
    /// to, drawn with the pen. Ghost notes, drawn with the ghost tool, are only ever
    /// played: wherever they sound over the melody they're heard in its place, so a
    /// note can be hidden in a chord the singer has to find it in. Neither kind gets
    /// in the other's way.
    private enum NoteLayer {
        case melody, ghost
    }

    /// One cap on how many notes may sound at the same moment: `capacity` of `notes`.
    private struct SoundingLimit {
        let notes: [MIDINote]
        let capacity: Int
    }

    /// Which end of a note a drag is dragging: the start or the end of it.
    private enum ResizeEdge {
        case leading, trailing
    }

    private enum Interaction {
        case idle
        // `anchor` is the beat the press landed on; the note grows right from it, or
        // left from the right edge it started with. `layer` is the kind of note it is.
        case creating(note: MIDINote, anchor: Double, layer: NoteLayer)
        // A press that landed on a beat no note can start on — another note already
        // sounds there (for a ghost note, as many as there's room for), or there's too
        // little room left before the next one. Nothing is drawn yet: the note appears
        // the moment the drag reaches free timeline either side, butted up against the
        // stretch that blocked it.
        case pendingNote(pitch: Int, origin: Double)
        case resizing(id: UUID, edge: ResizeEdge)
        case movingNote(id: UUID, grabDX: Double)
        case pendingText(CGPoint)
        // `grabDX` is how far the press landed from the label's middle, which is what
        // text is positioned by — see `MIDIText.centreBeat`.
        case movingText(id: UUID, grabDX: Double, moved: Bool)
        // A press that landed on the black margin before the first beat, where nothing
        // can be placed. It does nothing until the finger lifts.
        case deadSpace
        // A press that would add more than the exercise may hold (see `Refusal`).
        // Nothing is drawn; the finger lifting puts up a toast saying why.
        case refused(Refusal)
        case erasing
    }

    /// A drag on the roll in the roll's own space, which the tools work in: where the
    /// press landed, and where the finger is now. While the roll scrolls under a finger
    /// held near its edge, the finger comes to be somewhere new in it without moving.
    private struct RollTouch {
        var startLocation: CGPoint
        var location: CGPoint
        var translation: CGSize {
            CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y)
        }
    }

    /// The space the roll's drag is read in: the vertical scroll view's frame, piano
    /// keys and all, which stays put however the roll is scrolled.
    private let rollViewportSpace = "rollViewport"

    /// Why a press drew nothing although it landed on free timeline.
    private enum Refusal {
        /// The note would reach past the point where the run lasts half an hour.
        case tooLong
        /// One more note or ghost note than the pattern, or the whole run, may hold.
        case tooManyNotes
        /// The same for a label.
        case tooManyLabels
    }

    // Notes visible during an in-progress drag
    private var liveNotes: [MIDINote] {
        if case .creating(let n, _, .melody) = interaction { return notes + [n] }
        return notes
    }

    /// The ghost notes, likewise.
    private var liveGhosts: [MIDINote] {
        if case .creating(let n, _, .ghost) = interaction { return ghosts + [n] }
        return ghosts
    }

    private var inProgressID: UUID? {
        if case .creating(let n, _, _) = interaction { return n.id }
        return nil
    }

    private func layerNotes(_ layer: NoteLayer) -> [MIDINote] {
        layer == .melody ? notes : ghosts
    }

    /// Puts `note` back over the note of `layer` with its id, if it's still there.
    private func replace(_ note: MIDINote, in layer: NoteLayer) {
        switch layer {
        case .melody:
            if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note }
        case .ghost:
            if let i = ghosts.firstIndex(where: { $0.id == note.id }) { ghosts[i] = note }
        }
    }

    // MARK: - Dynamic grid width

    /// Furthest beat any content reaches: the end of the longest-reaching note (or
    /// ghost note) or the right edge of the furthest text chip. Uses `liveNotes` so the
    /// grid grows live while a note is being dragged into the trailing free measures.
    private var contentEndBeat: Double {
        var maxBeat = 0.0
        for note in liveNotes + liveGhosts { maxBeat = max(maxBeat, note.beat + note.length) }
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

    // MARK: - Dead space before the first beat
    //
    // A label is placed by its middle, so a long one over a note near the start
    // reaches back past beat 0 — where the grid, and the exercise, begin. Rather than
    // shove such a label right, off the note it annotates, the roll grows a margin of
    // dead space to the left of beat 0, wide enough for whatever hangs off the front.
    // It's drawn flat black with no grid on it and nothing can be placed there, so the
    // first vertical line still reads as where the exercise starts.

    /// The middle of the first note — as far left as a label may ever be centred,
    /// however wide it grows. `nil` when there's no note to centre on, and labels stop
    /// at beat 0 instead.
    private var firstNoteCentre: Double? {
        guard let first = notes.min(by: { $0.beat < $1.beat }) else { return nil }
        return first.beat + first.length / 2
    }

    /// How far left of beat 0 a label reading `text` may reach: what's left of its
    /// half-width once it's pulled back to the furthest-left middle it may sit on.
    private func maxOverhang(of text: String) -> Double {
        let half = Double(midiTextChipWidth(text) / beatW) / 2
        return max(0, half - (firstNoteCentre ?? half))
    }

    /// How far the roll reaches left of beat 0, in beats: as far as the label that
    /// hangs furthest off the front. While a label is being dragged it's as far as
    /// that label *could* reach, so the margin — and with it the whole grid — holds
    /// still under the finger for the length of the drag instead of growing into it.
    private var leadBeats: Double {
        var lead = 0.0
        for label in texts { lead = max(lead, -min(0, label.beat)) }
        if case .movingText(let id, _, _) = interaction,
           let dragged = texts.first(where: { $0.id == id }) {
            lead = max(lead, maxOverhang(of: dragged.text))
        }
        return lead
    }

    private var leadW: CGFloat { CGFloat(leadBeats) * beatW }

    /// The whole scrollable width: the dead margin plus the grid itself.
    private var contentW: CGFloat { leadW + gridW }

    /// The exercise's tempo, read from the store rather than the copy this screen was
    /// pushed with, so it follows the tempo slider (see `tempo`).
    private var bpm: Double {
        guard let exercise else { return 120 }
        return store.exercises.first { $0.id == exercise.id }?.bpm ?? exercise.bpm
    }

    /// What the tempo slider sets: the exercise's own `bpm`, written through the store
    /// exactly as the Tempo slider on its settings screen writes it, so the two are
    /// one setting. Whole beats per minute, as that slider's steps are; rounded here
    /// rather than stepped on the slider, which would draw its 200 tick marks as a
    /// solid line under the track.
    private var tempo: Binding<Double> {
        Binding(
            get: { bpm },
            set: { value in
                guard let exercise else { return }
                let newValue = slowestFittingTempo(value.rounded())
                guard newValue != bpm else { return }
                // A run under way was scheduled at the old tempo, and the playhead is
                // drawn from it, so stop it the way scrubbing the ruler does.
                if isPlaying { stopPlayback() }
                store.binding(for: exercise.id).wrappedValue.bpm = newValue
            })
    }

    /// The roll: the piano-key column beside the grid, both drawn through the camera.
    /// Two fingers move and zoom it whatever the tool, as a photo is moved and zoomed;
    /// one finger does with the hand tool, and scrolls it up and down on the keys. Kept
    /// out of `body` so the compiler can still type-check that.
    private var rollViewport: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                pianoKeysCanvas
                    .frame(width: pianoW)
                ZStack {
                    rollCanvas
                    playheadOverlay
                    RollScrollIndicators(camera: camera)
                }
            }
            // Over everything, so it sees every finger; the tools' drag below is on
            // the view around it and sees them too.
            RollNavigationSurface(camera: camera,
                                  keysWidth: pianoW,
                                  oneFingerPans: tool == .hand,
                                  onPressBegan: pressBegan,
                                  onPressEnded: pressEnded,
                                  onNavigationBegan: navigationBegan)
        }
        .clipped()
        .contentShape(Rectangle())
        // The hand tool turns off only this drag: the surface's own touches go on.
        .gesture(rollGesture, including: tool == .hand ? .subviews : .all)
        .coordinateSpace(.named(rollViewportSpace))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportChanged(to: $0) }
        .onReceive(edge.frames) { edgeScrollStep($0) }
        .onChange(of: fingerOnRoll) { _, down in
            guard !down else { return }
            edge.end()
            // Whether it ended or was cancelled, the drag is over and so is what it kept.
            press.before = nil
            releaseToolLockIfDone()
        }
    }

    /// The roll's viewport, piano keys and all, is `size` now.
    private func viewportChanged(to size: CGSize) {
        camera.setContent(CGSize(width: contentW, height: gridH))
        camera.setViewport(CGSize(width: max(0, size.width - pianoW), height: size.height))
        // The first layouts are provisional, taller than the roll ends up while the
        // push sets the screen out, so until the roll is touched it's put where it
        // opens each time its height changes.
        guard !rollTouched else { return }
        camera.jump(toY: openingOffset(in: size))
    }

    /// How wide the roll is in its own space, and how much of that is the dead margin
    /// in front of beat 0.
    private struct RollExtent: Equatable {
        var lead: CGFloat
        var width: CGFloat
    }

    private var rollExtent: RollExtent { RollExtent(lead: leadW, width: contentW) }

    /// The camera measures from the roll's leading edge, and the dead margin growing or
    /// shrinking is that edge moving: the camera moves by the same amount, so the grid
    /// stays where it was instead of jumping sideways.
    private func rollExtentChanged(from old: RollExtent, to new: RollExtent) {
        let lead = new.lead - old.lead
        // A drag under way has had the roll moved under it, and keeps the say over
        // where it is until the finger lifts.
        if lead != 0, edge.drag != nil { edge.steered = true }
        camera.setContent(CGSize(width: new.width, height: gridH), leadGrownBy: lead)
    }

    /// How far down the roll opens scrolled: far enough that the notes (and ghost
    /// notes) on the first screenful, the stretch it shows before it's scrolled
    /// sideways, sit centred between the ruler and the transport bar. When they span
    /// more rows than fit, it's as near that as it gets while the first note stays on
    /// screen. With nothing on the first screenful it's the first note that's
    /// centred, and with no notes at all the roll opens at the top.
    ///
    /// Read off the pattern as the editor opened it, so nothing drawn since moves it.
    private func openingOffset(in viewport: CGSize) -> CGFloat {
        let opened = savedNotes + savedGhosts
        // The earliest note, a melody note on a tie: they're listed first.
        guard let first = opened.min(by: { $0.beat < $1.beat }) else { return 0 }
        let lead = savedTexts.reduce(0.0) { max($0, -min(0, $1.beat)) }
        let screenEnd = Double(viewport.width - pianoW) / Double(beatW) - lead
        let onScreen = opened.filter { $0.beat < screenEnd }
        let rows = (onScreen.isEmpty ? [first] : onScreen).map { hiPitch - $0.pitch }
        let top = CGFloat(rows.min() ?? 0) * rowH
        let bottom = CGFloat((rows.max() ?? 0) + 1) * rowH

        var offset = (top + bottom - viewport.height) / 2
        if bottom - top > viewport.height {
            // Too tall to centre whole: slide only as far as keeps the first note a
            // row clear of the edges.
            let firstTop = CGFloat(hiPitch - first.pitch) * rowH
            let margin = min(rowH, max(0, (viewport.height - rowH) / 2))
            offset = min(max(offset, firstTop + rowH + margin - viewport.height), firstTop - margin)
        }
        return min(max(offset, 0), max(0, gridH - viewport.height))
    }

    var body: some View {
        // Every edit is written through as it happens (see `savedNotes`). Kept apart
        // from the screen itself so the compiler can still type-check both.
        editor
            .onChange(of: notes) { _, _ in saveNotes() }
            .onChange(of: texts) { _, _ in saveTexts() }
            .onChange(of: ghosts) { _, _ in saveGhosts() }
            .onChange(of: rollExtent) { old, new in rollExtentChanged(from: old, to: new) }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            // Time runs left to right across the grid in every language, with the
            // keys on its left, so a mirrored app lays the ruler and the roll out as
            // they are. The transport bar underneath is ordinary chrome and mirrors.
            Group {
                rulerRow
                rollViewport
            }
            .environment(\.layoutDirection, .leftToRight)
            if showsTempo {
                tempoPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // Over the tempo slider, which slides out from underneath it.
            transportBar
                .zIndex(1)
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
            ToolbarItem(placement: .topBarTrailing) { toolRow }
        }
        .explainBarButton(L("Back"), L("Saves what you drew and goes back to the exercise's settings."))
        .alert("Text", isPresented: $showTextEditor) {
            TextField("Label", text: $textInput.limited(to: TextLimit.label))
            Button("OK") { commitText() }
            Button("Cancel", role: .cancel) { cancelText() }
        } message: {
            Text("Enter text to place on the grid.")
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
        .onDisappear {
            edge.end()
            camera.stopMotion()
            isPlaying = false
            player.stop()
            if engineStarted {
                AudioRouteManager.shared.deactivateSession()
                engineStarted = false
            }
            // The pattern is what an exercise's difficulty is read off, so this
            // is the first moment there is one to read — an exercise created
            // straight from the + button reaches its list again with its notes
            // already drawn, but one named and left empty only gets them here.
            // It is also the moment an estimate goes stale: notes changed in
            // here can make the exercise a different exercise to sing, and the
            // estimate posted for it is corrected to match. Costs nothing when
            // the strokes made in here left the difficulty where it was
            // (CommunitySync.seedDifficulty(for:)).
            if let exercise { CommunitySync.shared.seedDifficulty(for: exercise.id) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, isPlaying { stopPlayback() }
        }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            followPlayhead()
        }
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
        // clipped so just its remainder plays. Ghost notes the same.
        func clipped(_ list: [MIDINote]) -> [MIDINote] {
            list.compactMap { note in
                let end = note.beat + note.length
                guard end > startBeat else { return nil }
                var n = note
                n.beat = max(0, note.beat - startBeat)
                n.length = (end - startBeat) - n.beat
                return n
            }
        }
        let melody = clipped(notes)
        let ghostNotes = clipped(ghosts)
        guard !melody.isEmpty || !ghostNotes.isEmpty else { return }

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
        player.schedule(notes: melody, ghosts: ghostNotes, bpm: bpm, leadIn: 0, preview: false) {
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
    /// move the roll so it re-enters near the left edge.
    private func followPlayhead() {
        // Not while a drag is steering the roll (see `edgeScrollStep`), or fingers are,
        // or it's still on its way somewhere: whatever is moving it has the say over
        // where it's scrolled until it's done.
        guard isPlaying, camera.viewport.width > 0, !edge.steered,
              !camera.isNavigating, !camera.isMoving else { return }
        let shot = camera.shot
        let shown = camera.viewport.width / shot.zoom
        let x = leadW + CGFloat(displayBeat) * beatW
        if x > shot.origin.x + shown - 24 / shot.zoom || x < shot.origin.x {
            camera.glide(toX: max(0, x - shown * 0.2))
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
    /// pop's "MIDI Saved!" toast is swallowed — nothing was saved.
    private func leaveDiscardingChanges() {
        notes = savedNotes
        texts = savedTexts
        ghosts = savedGhosts
        writeNotes(savedNotes)
        writeTexts(savedTexts)
        writeGhosts(savedGhosts)
        if let exercise, let savedBPM {
            store.binding(for: exercise.id).wrappedValue.bpm = savedBPM
        }
        // The edits are gone, so the date they stamped goes with them.
        if let exercise { ExerciseDates.restore(savedDates, for: exercise.id) }
        toasts.suppressNext()
        dismiss()
    }

    // MARK: - Ruler & transport bar

    /// Fixed strip above the grid showing measure numbers and beat ticks, drawn through
    /// the roll's camera so it stays aligned with the grid however that's scrolled and
    /// zoomed. Tap or drag anywhere on it to move the playhead.
    private var rulerRow: some View {
        HStack(spacing: 0) {
            Color(white: 0.13).frame(width: pianoW)
            TimelineView(.animation(minimumInterval: nil, paused: !isPlaying)) { _ in
                RollCameraCanvas(camera: camera) { ctx, size, shot in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.13)))
                    let beatPx = beatW * shot.zoom
                    ctx.translateBy(x: (leadW - shot.origin.x) * shot.zoom, y: 0)
                    // Black over the dead margin here too, so the exercise starts on the
                    // same line on the ruler as it does on the grid.
                    ctx.fill(Path(CGRect(x: -leadW * shot.zoom, y: 0, width: leadW * shot.zoom,
                                         height: size.height)),
                             with: .color(.black))

                    let shownFrom = (shot.origin.x - leadW) / beatW
                    let shownTo = shownFrom + size.width / shot.zoom / beatW
                    if let beats = wholeSpan(shownFrom, shownTo, within: 0...totalBeats) {
                        for beat in beats {
                            let x = CGFloat(beat) * beatPx
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

                    let px = CGFloat(displayBeat) * beatPx
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
                let shot = camera.shot
                let beat = Double((v.location.x / shot.zoom + shot.origin.x - leadW) / beatW)
                playheadBeat = min(Double(totalBeats), max(0, snapped(beat)))
            }
    }

    /// Red line over the roll at the playhead, animated from the audio clock while
    /// playing. Drawn in its own overlay so the note canvas isn't redrawn per frame.
    private var playheadOverlay: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isPlaying)) { _ in
            RollCameraCanvas(camera: camera) { ctx, size, shot in
                let x = (leadW + CGFloat(displayBeat) * beatW - shot.origin.x) * shot.zoom
                guard x >= 0, x <= size.width else { return }
                // Down the rows and no further.
                let top = max(0, -shot.origin.y * shot.zoom)
                let bottom = min(size.height, (gridH - shot.origin.y) * shot.zoom)
                guard bottom > top else { return }
                var line = Path()
                line.move(to: CGPoint(x: x, y: top))
                line.addLine(to: CGPoint(x: x, y: bottom))
                ctx.stroke(line, with: .color(.red.opacity(0.9)), lineWidth: 1.5)
            }
        }
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
            .explain(L("Puts the playhead back at the beginning."))
            Button {
                isPlaying ? stopPlayback() : startPlayback(from: playheadBeat)
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 28)
            }
            .disabled(notes.isEmpty && ghosts.isEmpty)
            .accessibilityLabel(isPlaying ? L("Stop") : L("Play"))
            .explain(L("Plays what you have drawn from the playhead, so you can hear it. Nothing is recorded or scored here."))
            TimelineView(.animation(minimumInterval: 0.1, paused: !isPlaying)) { _ in
                Text(verbatim: positionLabel(for: displayBeat))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .explain(L("Where the playhead stands, as bar and beat."))
            }
            Spacer()
            Button {
                withAnimation(.snappy(duration: 0.25)) { showsTempo.toggle() }
            } label: {
                Text(L("%d BPM", Int(bpm)))
                    .font(.footnote)
                    .foregroundStyle(showsTempo ? .primary : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(showsTempo ? Color.accentColor.opacity(0.2) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    // The highlight and the hit area reach past the text without
                    // moving it or making the bar any taller.
                    .padding(.horizontal, -8)
                    .padding(.vertical, -6)
            }
            .buttonStyle(.plain)
            .disabled(exercise == nil)
            .explain(L("The exercise's tempo, in beats per minute. Tap it to show or hide a slider that changes it."))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.1))
        .foregroundStyle(.white)
    }

    /// The slider the BPM readout opens, along the bottom of the screen just above
    /// the transport bar. It sets the same tempo as the Tempo slider on the
    /// exercise's settings screen (see `tempo`).
    private var tempoPanel: some View {
        Slider(value: tempo, in: Exercise.tempoRange) {
            Text("Tempo")
        } minimumValueLabel: {
            Image(systemName: "tortoise.fill")
        } maximumValueLabel: {
            Image(systemName: "hare.fill")
        }
        .foregroundStyle(.secondary)
        // The editor is drawn dark whatever the app's appearance, so its track and
        // the tortoise and hare are too. The bubble keeps the app's.
        .environment(\.colorScheme, .dark)
        .explain(L("How fast the exercise is played, in beats per minute."))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(white: 0.1))
        .overlay(alignment: .bottom) {
            // Kept apart from the transport bar under it, which is the same gray.
            Rectangle().fill(Color(white: 0.2)).frame(height: 0.5)
        }
    }

    /// "measure.beat" readout, 1-based, e.g. "3.2".
    private func positionLabel(for beat: Double) -> String {
        let b = max(0, beat)
        return "\(Int(b) / beatsPerMeasure + 1).\(Int(b) % beatsPerMeasure + 1)"
    }

    /// The tools along the top right. Kept out of `body` so the compiler can still
    /// type-check that.
    private var toolRow: some View {
        HStack(spacing: 2) {
            toolButton(.pen,   system: "pencil",
                       help: L("Draw notes: drag on the grid to make one, drag a note to move it, or drag its ends to make it longer or shorter."))
            toolButton(.text,  system: "textformat",
                       help: L("Write a label on the grid, for the syllable to sing. Tap a label to change it, or drag it somewhere else."))
            toolButton(.erase, system: "eraser",
                       help: L("Erase notes and labels by dragging across them."))
            toolButton(.hand,  system: "hand.point.up.left",
                       help: L("Scroll the grid around without changing anything."))
            // SF Symbols has no ghost. A dashed bar is what a ghost note looks like
            // on the grid.
            toolButton(.ghost, system: "rectangle.dashed",
                       help: L("Draw ghost notes the way you draw notes. They're played but never sung or scored, and while they play over a note only they are heard, so the note can be hidden in a chord. Up to %d can play at once.", maxGhostsAtOnce))
        }
    }

    private func toolButton(_ t: Tool, system: String, help: String) -> some View {
        Button { tool = t } label: {
            Image(systemName: system)
                .padding(6)
                .background(tool == t ? Color.accentColor.opacity(0.2) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                // Out to the glass's box at the ends of the row, and half the
                // row's spacing towards each neighbour.
                .toolbarHitArea(reach: EdgeInsets(top: 16, leading: t == .pen ? 16 : 1,
                                                  bottom: 16, trailing: t == .ghost ? 16 : 1))
        }
        .explain(help)
    }

    // MARK: - Piano key column

    /// The keys, drawn through the roll's camera: scrolled and zoomed up and down with
    /// the grid's rows, always the same width.
    private var pianoKeysCanvas: some View {
        RollCameraCanvas(camera: camera) { ctx, size, shot in
            let keyH = rowH * shot.zoom
            let top = -shot.origin.y * shot.zoom
            // Zoomed out too far for every name to fit, only the Cs are named, which
            // mark the octaves.
            let namesAll = keyH >= 12
            let nameSize = namesAll ? 9 : min(9, max(6, keyH - 1))
            let shownFrom = shot.origin.y / rowH
            let shownTo = shownFrom + size.height / shot.zoom / rowH
            if let rows = wholeSpan(shownFrom, shownTo, within: 0...(totalRows - 1)) {
                for row in rows {
                    let pitch = hiPitch - row
                    let y = top + CGFloat(row) * keyH
                    let bg: Color = isBlack(pitch) ? Color(white: 0.08) : Color(white: 0.88)
                    ctx.fill(Path(CGRect(x: 0, y: y, width: pianoW, height: keyH)),
                             with: .color(bg))

                    var sep = Path()
                    sep.move(to: CGPoint(x: 0, y: y + keyH))
                    sep.addLine(to: CGPoint(x: pianoW, y: y + keyH))
                    ctx.stroke(sep, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)

                    guard namesAll || pitch % 12 == 0 else { continue }
                    ctx.draw(
                        Text(pitchName(pitch))
                            .font(.system(size: nameSize, weight: .medium))
                            .foregroundColor(isBlack(pitch) ? .white : .black),
                        at: CGPoint(x: pianoW - 4, y: y + keyH / 2),
                        anchor: .trailing
                    )
                }
            }

            var border = Path()
            border.move(to: CGPoint(x: pianoW - 0.5, y: max(0, top)))
            border.addLine(to: CGPoint(x: pianoW - 0.5, y: min(size.height, top + gridH * shot.zoom)))
            ctx.stroke(border, with: .color(.gray.opacity(0.5)), lineWidth: 1)
        }
    }

    // MARK: - Piano roll grid canvas

    private var rollCanvas: some View {
        let shown = liveNotes
        let shownGhosts = liveGhosts
        let overlaps = overlapSpans(in: shown)
        let ghostCovers = ghostCoverSpans(of: shown, by: shownGhosts)
        let labelScales = textScales
        return RollCameraCanvas(camera: camera) { ctx, size, shot in
            // Drawn in the roll's own space, zoomed into the viewport. Lines are a
            // screen point (or a few) wide whatever the zoom: `pt` is one of those in
            // the roll's own space.
            let pt = 1 / shot.zoom
            ctx.scaleBy(x: shot.zoom, y: shot.zoom)
            ctx.translateBy(x: -shot.origin.x, y: -shot.origin.y)

            // The dead margin: flat black, no rows and no lines, so it's plain that
            // nothing goes there. Only a label hanging off the front reaches over it —
            // the labels are drawn last, on top.
            ctx.fill(Path(CGRect(x: 0, y: 0, width: leadW, height: gridH)), with: .color(.black))
            ctx.translateBy(x: leadW, y: 0)

            // The stretch of the grid on screen. Only the rows, lines, notes and labels
            // in it are drawn: zoomed in on a long pattern, that's a sliver of them.
            let visible = CGRect(x: shot.origin.x - leadW, y: shot.origin.y,
                                 width: size.width * pt, height: size.height * pt)
            let left = max(0, visible.minX)
            let right = min(gridW, visible.maxX)
            let rows = wholeSpan(visible.minY / rowH, visible.maxY / rowH, within: 0...(totalRows - 1))

            if let rows, right > left {
                // Row backgrounds
                for row in rows {
                    let pitch = hiPitch - row
                    let y = CGFloat(row) * rowH
                    let bg: Color = isBlack(pitch) ? Color(white: 0.1) : Color(white: 0.17)
                    ctx.fill(Path(CGRect(x: left, y: y, width: right - left, height: rowH)),
                             with: .color(bg))
                }

                // Horizontal row separators
                var hGrid = Path()
                for row in rows.lowerBound...(rows.upperBound + 1) {
                    let y = CGFloat(row) * rowH
                    hGrid.move(to: CGPoint(x: left, y: y))
                    hGrid.addLine(to: CGPoint(x: right, y: y))
                }
                ctx.stroke(hGrid, with: .color(white: 0.22), lineWidth: 0.5 * pt)
            }

            // Vertical beat lines
            if let beats = wholeSpan(visible.minX / beatW, visible.maxX / beatW, within: 0...totalBeats) {
                for beat in beats {
                    let x = CGFloat(beat) * beatW
                    let isBar = beat % 4 == 0
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: gridH))
                    ctx.stroke(line,
                               with: .color(white: isBar ? 0.45 : 0.25),
                               lineWidth: (isBar ? 1.5 : 0.5) * pt)
                }
            }

            // A note's name is as big on screen as it is unzoomed, a little bigger zoomed
            // in, and written only where it fits.
            let nameSize = (8 * shot.zoom).clamped(to: 8...11)
            func fitsName(_ box: CGRect) -> Bool {
                box.width * shot.zoom > 20 && box.height * shot.zoom >= nameSize
            }

            // Notes
            for note in shown {
                let rect = rect(for: note)
                guard rect.intersects(visible) else { continue }
                let inner = rect.insetBy(dx: 1, dy: 1)
                let dimmed = note.id == inProgressID
                let notePath = Path(roundedRect: inner, cornerRadius: 3)
                ctx.fill(notePath, with: .color(.green.opacity(dimmed ? 0.6 : 0.88)))
                ctx.stroke(notePath, with: .color(.green), lineWidth: pt)

                // Where a ghost note of the same pitch lies over the note. Under the
                // red, which marks something to fix; this only says where it is.
                for span in ghostCovers[note.id] ?? [] {
                    let x0 = max(inner.minX, CGFloat(span.start) * beatW)
                    let x1 = min(inner.maxX, CGFloat(span.end) * beatW)
                    guard x1 > x0 else { continue }
                    let covered = CGRect(x: x0, y: inner.minY, width: x1 - x0, height: inner.height)
                    ctx.fill(Path(roundedRect: covered, cornerRadius: 2),
                             with: .color(ghostOverNoteColor.opacity(dimmed ? 0.6 : 0.95)))
                }

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
                    ctx.stroke(notePath, with: .color(.red), lineWidth: 1.5 * pt)
                }

                if fitsName(inner) {
                    ctx.draw(
                        Text(pitchName(note.pitch))
                            .font(.system(size: nameSize * pt, weight: .medium))
                            .foregroundColor(.black),
                        at: CGPoint(x: inner.minX + 3 * pt, y: inner.midY),
                        anchor: .leading
                    )
                }
            }

            // Ghost notes, over the notes: see-through, so a note one is laid on still
            // shows beneath it, and outlined in dashes, so a ghost note laid exactly
            // over a note can still be told apart from it. Where one lies on a note of
            // its own pitch, that note has painted the stretch already, and the green
            // is kept off it so the colour there stays clear.
            for ghost in shownGhosts {
                let box = rect(for: ghost)
                guard box.intersects(visible) else { continue }
                let inner = box.insetBy(dx: 1, dy: 1)
                let dimmed = ghost.id == inProgressID
                let ghostPath = Path(roundedRect: inner, cornerRadius: 3)
                var fill = ctx
                for note in shown where note.pitch == ghost.pitch {
                    fill.clip(to: Path(rect(for: note).insetBy(dx: 1, dy: 1)), options: .inverse)
                }
                fill.fill(ghostPath, with: .color(.green.opacity(dimmed ? 0.18 : 0.3)))
                ctx.stroke(ghostPath, with: .color(.green.opacity(0.9)),
                           style: StrokeStyle(lineWidth: pt, dash: [3 * pt, 2 * pt]))

                // A note of the same pitch already has its name written there.
                let named = shown.contains {
                    $0.pitch == ghost.pitch && ghost.beat >= $0.beat - beatEpsilon
                        && ghost.beat < $0.beat + $0.length - beatEpsilon
                }
                if fitsName(inner), !named {
                    ctx.draw(
                        Text(pitchName(ghost.pitch))
                            .font(.system(size: nameSize * pt, weight: .medium))
                            .foregroundColor(.white.opacity(0.75)),
                        at: CGPoint(x: inner.minX + 3 * pt, y: inner.midY),
                        anchor: .leading
                    )
                }
            }

            // The snap line: while a label is being dragged onto a note's middle, a
            // stroke down the beat the two share, so it's plain they line up. Drawn
            // over the notes but under the labels, so the text on top of it stays
            // readable.
            if let line = textSnapLine {
                var path = Path()
                path.move(to: CGPoint(x: line.x, y: line.top))
                path.addLine(to: CGPoint(x: line.x, y: line.bottom))
                ctx.stroke(path, with: .color(.appAccent),
                           style: StrokeStyle(lineWidth: 2 * pt, lineCap: .round))
            }

            // Text labels, each shrunk as far as it has to be to keep clear of the
            // others. They grow and shrink with the roll: a label covers the beats it
            // was written over, however far the roll is zoomed.
            for (label, scale) in zip(texts, labelScales) {
                let rect = drawnTextRect(for: label, scale: scale)
                guard rect.intersects(visible) else { continue }
                let chip = Path(roundedRect: rect.insetBy(dx: 1, dy: 3), cornerRadius: 3)
                ctx.fill(chip, with: .color(.orange.opacity(0.22)))
                ctx.stroke(chip, with: .color(.orange.opacity(0.6)), lineWidth: pt)
                ctx.draw(
                    Text(label.text.isEmpty ? " " : label.text)
                        .font(.system(size: midiTextFontSize * CGFloat(scale), weight: .semibold))
                        .foregroundColor(.orange),
                    at: CGPoint(x: rect.midX, y: rect.midY),
                    anchor: .center
                )
            }
        }
    }

    // MARK: - Gesture

    // Read in the viewport's space rather than the roll's own, so where the finger is
    // on screen is known exactly however the roll is scrolled: edge scrolling goes by
    // that, and moves the roll on under it (see `rollTouch(for:)`).
    private var rollGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(rollViewportSpace))
            .updating($fingerOnRoll) { _, down, _ in down = true }
            .onChanged { v in
                // Not a press two fingers have taken over, or one that was only there
                // to stop the roll gliding; and not one on the keys, where a finger
                // scrolls the roll instead.
                guard !press.toolLocked, v.startLocation.x >= pianoW else { return }
                if !rollTouched { rollTouched = true }
                if press.before == nil { press.before = patternSnapshot() }
                applyTool(rollTouch(for: v))
                updateEdgeScroll()
            }
            .onEnded { v in
                edge.end()
                guard !press.toolLocked, v.startLocation.x >= pianoW else { return }
                press.before = nil
                switch tool {
                case .pen:   noteEnded(in: .melody)
                case .ghost: noteEnded(in: .ghost)
                case .text:  textEnded()
                case .erase: interaction = .idle
                case .hand:  break
                }
            }
    }

    /// Hands the drag to the tool in use.
    private func applyTool(_ touch: RollTouch) {
        switch tool {
        case .pen:   noteChanged(touch, in: .melody)
        case .ghost: noteChanged(touch, in: .ghost)
        case .text:  textChanged(touch)
        case .erase: eraseChanged(touch)
        case .hand:  break
        }
    }

    /// The drag `v` in the roll's own space, noting down where the finger is on screen
    /// for edge scrolling.
    private func rollTouch(for v: DragGesture.Value) -> RollTouch {
        // A drag the system cancelled never ended, so a press somewhere else is a new
        // one whatever was noted down.
        if let drag = edge.drag, drag.pressedAt != v.startLocation { edge.end() }
        let shot = camera.shot
        let start = edge.drag?.start ?? rollPoint(v.startLocation, in: shot)
        edge.drag = RollEdgeScroll.Drag(start: start, pressedAt: v.startLocation, finger: v.location)
        return RollTouch(startLocation: start, location: rollPoint(v.location, in: shot))
    }

    /// `point` in the viewport's space, where the drag reports the finger, in the roll's
    /// own space as `shot` shows it. The grid starts right of the keys.
    private func rollPoint(_ point: CGPoint, in shot: RollShot) -> CGPoint {
        shot.roll(CGPoint(x: point.x - pianoW, y: point.y))
    }

    // MARK: Two fingers
    //
    // Two fingers on the roll move and zoom it whatever the tool, and the tools never
    // hear of it. The first of the two usually lands a moment before the second, and
    // has been handed to the tool by then: whatever it did with it is put back as soon
    // as the press turns out to be moving the roll.

    /// The first finger of a press has landed on the roll. A press that lands while the
    /// roll is still gliding only stops it, as a scroll view's does.
    private func pressBegan() {
        press.isDown = true
        press.toolLocked = camera.stopMotion()
        if press.toolLocked { takeBackToolDrag() }
    }

    /// The last finger of the press has lifted.
    private func pressEnded() {
        press.isDown = false
        releaseToolLockIfDone()
        camera.resumeSettling()
    }

    /// The press has turned into moving the roll.
    private func navigationBegan() {
        if !rollTouched { rollTouched = true }
        press.toolLocked = true
        takeBackToolDrag()
    }

    /// Hands the roll back to the tools once a press they were locked out of is over:
    /// its fingers lifted and the tools' drag ended, which come in either order. Until
    /// both have, whatever the drag still reports belongs to that press.
    private func releaseToolLockIfDone() {
        if !press.isDown, !fingerOnRoll { press.toolLocked = false }
    }

    /// The pattern as it stands now, and the exercise's dates with it.
    private func patternSnapshot() -> PatternSnapshot {
        PatternSnapshot(notes: notes, ghosts: ghosts, texts: texts,
                        dates: exercise.flatMap { ExerciseDates.timestamps(for: $0.id) })
    }

    /// Puts back whatever the press's drag had done with the tool, and leaves the tool
    /// waiting for the next one, with nothing to say about this one.
    private func takeBackToolDrag() {
        edge.end()
        hitLengthLimit = false
        if let before = press.before {
            press.before = nil
            var changed = false
            if notes != before.notes { notes = before.notes; changed = true }
            if ghosts != before.ghosts { ghosts = before.ghosts; changed = true }
            if texts != before.texts { texts = before.texts; changed = true }
            // The edit is taken back, so the date it stamped goes with it, as leaving
            // without saving does.
            if changed, let exercise { ExerciseDates.restore(before.dates, for: exercise.id) }
        }
        if case .idle = interaction {} else { interaction = .idle }
    }

    // MARK: Edge scrolling
    //
    // A drag that carries something about, stretches a note or erases can bring the
    // finger up against the edge of what's on screen. Held there, the roll scrolls
    // that way under it, faster the nearer the edge it is, and the tool goes on
    // working wherever the finger comes to be on the roll, exactly as if it had moved.

    /// Which ways the roll scrolls when a drag brings the finger near its edge: either
    /// way for a note or label being carried about, and for the eraser; only sideways
    /// while a note is drawn or one of its ends dragged, which can only make it longer
    /// or shorter; not at all for anything else.
    private var edgeScrollAxes: Axis.Set {
        switch interaction {
        case .movingNote, .erasing:
            return [.horizontal, .vertical]
        case .movingText(_, _, let moved):
            // A label that hasn't moved yet may still turn out to be a tap.
            return moved ? [.horizontal, .vertical] : []
        case .creating, .pendingNote, .resizing:
            return .horizontal
        case .idle, .pendingText, .deadSpace, .refused:
            return []
        }
    }

    /// How fast the roll scrolls under the finger, in points a second either way: zero
    /// unless the drag has brought the finger near an edge it may scroll towards.
    private var edgeScrollVelocity: CGVector {
        let viewport = camera.viewport
        guard let drag = edge.drag, viewport.width > 0, viewport.height > 0 else { return .zero }
        let axes = edgeScrollAxes
        var velocity = CGVector.zero
        if axes.contains(.horizontal) {
            let left = pianoW, right = pianoW + viewport.width
            let zone = min(edgeScrollZone, viewport.width / 4)
            velocity.dx = edgeSpeed(distance: right - drag.finger.x, pressed: right - drag.pressedAt.x, zone: zone)
                - edgeSpeed(distance: drag.finger.x - left, pressed: drag.pressedAt.x - left, zone: zone)
        }
        if axes.contains(.vertical) {
            let height = viewport.height
            let zone = min(edgeScrollZone, height / 4)
            velocity.dy = edgeSpeed(distance: height - drag.finger.y, pressed: height - drag.pressedAt.y, zone: zone)
                - edgeSpeed(distance: drag.finger.y, pressed: drag.pressedAt.y, zone: zone)
        }
        return velocity
    }

    /// How fast the roll scrolls towards one edge with the finger `distance` from it
    /// (less than nothing past it) after pressing `pressed` from it: not at all until
    /// the finger is inside `zone` and has come `edgeScrollSlop` nearer the edge than it
    /// pressed, then faster the nearer it gets, flat out at the edge and past it.
    private func edgeSpeed(distance: CGFloat, pressed: CGFloat, zone: CGFloat) -> CGFloat {
        guard distance < zone, pressed - distance >= edgeScrollSlop else { return 0 }
        let depth = min(1, (zone - distance) / zone)
        return edgeScrollMaxSpeed * depth * depth
    }

    /// Starts the roll scrolling once a drag has brought the finger near an edge, and
    /// stops it once it no longer is.
    private func updateEdgeScroll() {
        if edgeScrollVelocity == .zero {
            edge.stop()
        } else {
            edge.start()
        }
    }

    /// One frame of edge scrolling: the roll moves on as far as the finger's place near
    /// the edge asks, and the tool works on at wherever that leaves the finger.
    private func edgeScrollStep(_ frame: RollEdgeScroll.Frame) {
        let velocity = edgeScrollVelocity
        guard let drag = edge.drag, velocity != .zero else {
            edge.stop()
            return
        }
        // A hitch doesn't jump the roll, or the eraser past a note: never more than a
        // 60th of a second's worth at once.
        let seconds = CGFloat(min(frame.step, 1.0 / 60) * min(1, frame.elapsed / edgeScrollEaseIn))
        let shot = camera.shot
        // As fast across the screen whatever the zoom, but never faster through the
        // roll itself than the eraser can keep up with (see `edgeScrollMaxSpeed`).
        let limit = edgeScrollMaxSpeed
        let from = shot.origin
        let to = camera.clamped(
            CGPoint(x: from.x + (velocity.dx / shot.zoom).clamped(to: -limit...limit) * seconds,
                    y: from.y + (velocity.dy / shot.zoom).clamped(to: -limit...limit) * seconds),
            zoom: shot.zoom)
        // Held against the end the finger points at, there's nowhere further to go
        // until the drag makes room (a note carried right lengthens the grid).
        guard to != from else { return }
        edge.steered = true
        camera.scroll(to: to)
        applyTool(RollTouch(startLocation: drag.start, location: rollPoint(drag.finger, in: camera.shot)))
    }

    // MARK: Pen and ghost tools — create, move, resize notes (no delete)
    //
    // The two tools work exactly alike, each on its own `layer` of notes and under
    // that layer's rules for which of them may sound at once.

    private func noteChanged(_ v: RollTouch, in layer: NoteLayer) {
        switch interaction {
        case .idle:
            guard beatValue(v.startLocation.x) >= 0 else {
                interaction = .deadSpace
                break
            }
            if let hit = noteAt(v.startLocation, in: layer) {
                if let edge = resizeEdge(of: hit, x: gridPoint(v.startLocation).x) {
                    interaction = .resizing(id: hit.id, edge: edge)
                } else {
                    interaction = .movingNote(id: hit.id,
                                              grabDX: beatValue(v.startLocation.x) - hit.beat)
                }
            } else {
                // Only one note may sound at a time, so a press that lands on a beat
                // another note already covers — even several rows away — draws nothing
                // yet; it waits to see whether the drag leaves the taken stretch. The
                // same goes for a ghost note where as many as there's room for sound.
                let start = snappedBeat(v.startLocation.x)
                let pitch = pitchAt(v.startLocation.y)
                // Before any of that, whether the exercise has room for another note
                // at all, and for one starting this far along.
                if let refusal = refusalOfNewNote(in: layer, startingAt: start) {
                    interaction = .refused(refusal)
                    break
                }
                guard !isOccupied(start, in: layer, pitch: pitch),
                      spaceAfter(start, in: layer, pitch: pitch) >= minLength else {
                    interaction = .pendingNote(pitch: pitch, origin: start)
                    break
                }
                let note = MIDINote(
                    pitch: pitch,
                    beat: start,
                    length: minLength
                )
                interaction = .creating(note: note, anchor: start, layer: layer)
            }

        case .pendingNote(let pitch, let origin):
            // The drag started over a beat that was already taken. As soon as it reaches
            // free timeline the note begins there, as if the press had landed as close to
            // the blocking note as a note can start — on whichever side the drag went.
            let pointer = beatValue(v.location.x)
            let from = beatValue(v.startLocation.x)
            if pointer > from, let anchor = nextFreeStart(atOrAfter: origin, in: layer, pitch: pitch),
               pointer >= anchor {
                // The free timeline the drag reached may lie past the length limit.
                guard anchor + minLength <= noteEndLimit + beatEpsilon else {
                    interaction = .refused(.tooLong)
                    break
                }
                let note = MIDINote(pitch: pitch, beat: anchor, length: minLength)
                interaction = .creating(note: grown(note, anchor: anchor, pointer: pointer, in: layer),
                                        anchor: anchor, layer: layer)
            } else if pointer < from, let end = previousFreeEnd(atOrBefore: origin, in: layer, pitch: pitch),
                      pointer <= end {
                guard end <= noteEndLimit + beatEpsilon else {
                    interaction = .refused(.tooLong)
                    break
                }
                let anchor = end - minLength
                let note = MIDINote(pitch: pitch, beat: anchor, length: minLength)
                interaction = .creating(note: grown(note, anchor: anchor, pointer: pointer, in: layer),
                                        anchor: anchor, layer: layer)
            }

        case .creating(let note, let anchor, let creatingLayer):
            interaction = .creating(note: grown(note, anchor: anchor,
                                                pointer: beatValue(v.location.x), in: creatingLayer),
                                    anchor: anchor, layer: creatingLayer)

        case .resizing(let id, let edge):
            if var note = layerNotes(layer).first(where: { $0.id == id }) {
                let pointer = beatValue(v.location.x)
                switch edge {
                case .trailing:
                    // Never past the length limit: the end is what makes a run longer.
                    let wanted = max(minLength, snapped(pointer - note.beat))
                    let room = max(minLength, noteEndLimit - note.beat)
                    if wanted > room + beatEpsilon { hitLengthLimit = true }
                    note.length = min(wanted, room,
                                      spaceAfter(note.beat, in: layer, pitch: note.pitch, excluding: id))
                case .leading:
                    // Dragging the start of the note: the end of it stays put.
                    let rightEdge = note.beat + note.length
                    let leftLimit = rightEdge - spaceBefore(rightEdge, in: layer, pitch: note.pitch,
                                                             excluding: id)
                    let beat = min(max(snapped(pointer), leftLimit), rightEdge - minLength)
                    note.beat = beat
                    note.length = rightEdge - beat
                }
                replace(note, in: layer)
            }

        case .movingNote(let id, let grabDX):
            if var note = layerNotes(layer).first(where: { $0.id == id }) {
                var desired = max(0, snapped(beatValue(v.location.x) - grabDX))
                // Held short of the length limit: a note moved later makes the run
                // longer just as one drawn there would.
                let limit = noteEndLimit
                if desired + note.length > limit + beatEpsilon {
                    desired = max(0, limit - note.length)
                    hitLengthLimit = true
                }
                // The row first: a ghost note's room depends on the pitch it lands on.
                note.pitch = pitchAt(v.location.y)
                let landing = placement(desired: desired,
                                        length: note.length,
                                        in: layer,
                                        pitch: note.pitch,
                                        excluding: id) ?? note.beat
                // The nearest free gap can lie further on than the limit; then the
                // note stays where it is.
                guard landing + note.length <= limit + beatEpsilon else {
                    hitLengthLimit = true
                    break
                }
                note.beat = landing
                replace(note, in: layer)
            }

        default:
            break
        }
    }

    private func noteEnded(in layer: NoteLayer) {
        // Said once, as the finger lifts, however many moves ran into it.
        if hitLengthLimit {
            hitLengthLimit = false
            showRefusal(.tooLong)
        }
        switch interaction {
        case .creating(let note, _, .melody):
            notes.append(note)

        case .creating(let note, _, .ghost):
            ghosts.append(note)

        case .refused(let refusal):
            showRefusal(refusal)

        case .pendingNote:
            // Never left the taken stretch, so nothing was drawn — say why, since the
            // press looks like it should have worked. For a ghost note it's always that
            // as many as may sound already do: one on the same pitch never turns a press
            // away, since the press either lands on it and picks it up, or snaps down to
            // a beat of the 1/4-beat grid that leaves room before it.
            switch layer {
            case .melody:
                toasts.show(L("Notes Can't Overlap"), icon: "exclamationmark.triangle.fill")
            case .ghost:
                toasts.show(L("Up to %d Ghost Notes at Once", maxGhostsAtOnce),
                            icon: "exclamationmark.triangle.fill")
            }

        default:
            break
        }
        interaction = .idle
    }

    /// The note being drawn, stretched to the pointer: right of `anchor` it grows right
    /// from that edge, left of it the right edge the note started with stays put. Either
    /// way it stops at the notes of its `layer` on both sides of it.
    private func grown(_ note: MIDINote, anchor: Double, pointer: Double,
                       in layer: NoteLayer) -> MIDINote {
        var note = note
        if pointer >= anchor {
            note.beat = anchor
            // Stopped at the length limit as well as at the next note.
            let wanted = max(minLength, snapped(pointer - anchor))
            let room = max(minLength, noteEndLimit - anchor)
            if wanted > room + beatEpsilon { hitLengthLimit = true }
            note.length = min(wanted, room, spaceAfter(anchor, in: layer, pitch: note.pitch))
        } else {
            let rightEdge = anchor + minLength
            let leftLimit = rightEdge - spaceBefore(rightEdge, in: layer, pitch: note.pitch)
            note.beat = min(max(snapped(pointer), leftLimit), anchor)
            note.length = rightEdge - note.beat
        }
        return note
    }

    // MARK: Text tool — place, move, edit labels

    private func textChanged(_ v: RollTouch) {
        switch interaction {
        case .idle:
            if let hit = textAt(v.startLocation) {
                // A label reaching over the margin is grabbed by that part of it too.
                interaction = .movingText(id: hit.id,
                                          grabDX: beatValue(v.startLocation.x) - hit.centreBeat,
                                          moved: false)
            } else if beatValue(v.startLocation.x) < 0 {
                interaction = .deadSpace
            } else {
                interaction = .pendingText(v.startLocation)
            }

        case .movingText(let id, let grabDX, _):
            // Six screen points, whatever the zoom.
            let moved = hypot(v.translation.width, v.translation.height) > 6 / camera.shot.zoom
            if moved, let i = texts.firstIndex(where: { $0.id == id }) {
                // No further along than a stored label may sit (see ExerciseLimits).
                let centre = min(snappedTextCentre(beatValue(v.location.x) - grabDX),
                                 ExerciseLimits.patternBeats)
                texts[i].beat = midiTextBeat(centring: texts[i].text, at: centre,
                                             firstNoteCentre: firstNoteCentre)
                texts[i].pitch = pitchAt(v.location.y)
            }
            interaction = .movingText(id: id, grabDX: grabDX, moved: moved)

        default:
            break
        }
    }

    private func textEnded() {
        switch interaction {
        case .pendingText(let p):
            guard hasRoomForLabel else {
                showRefusal(.tooManyLabels)
                break
            }
            // The press marks where the middle of the label goes; it's empty for now, so
            // it sits there half a beat wide until the typed text is committed.
            let centre = min(snappedTextCentre(beatValue(p.x)), ExerciseLimits.patternBeats)
            let label = MIDIText(text: "", pitch: pitchAt(p.y),
                                 beat: midiTextBeat(centring: "", at: centre,
                                                    firstNoteCentre: firstNoteCentre))
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
        // Cut to a label's length before trimming, so a cut landing on a space
        // doesn't leave one hanging at the end. The alert's field shows whatever
        // was typed past the limit, so this is where the limit really bites.
        let trimmed = textInput.limited(to: TextLimit.label)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            texts.removeAll { $0.id == id }
        } else if let i = texts.firstIndex(where: { $0.id == id }) {
            // Re-hang the label off its middle so the new text grows (or shrinks) to
            // both sides of where the old text sat, keeping it over the same beat.
            let centre = texts[i].centreBeat
            texts[i].text = trimmed
            texts[i].beat = midiTextBeat(centring: trimmed, at: centre,
                                         firstNoteCentre: firstNoteCentre)
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

    // MARK: Erase tool — scrub over notes, ghost notes and text to delete

    private func eraseChanged(_ v: RollTouch) {
        // Ghost notes first: they're drawn over the notes.
        if let g = noteAt(v.location, in: .ghost) {
            ghosts.removeAll { $0.id == g.id }
        } else if let n = noteAt(v.location, in: .melody) {
            notes.removeAll { $0.id == n.id }
        } else if let t = textAt(v.location) {
            texts.removeAll { $0.id == t.id }
        }
        interaction = .erasing
    }

    // MARK: - Limits
    //
    // What the pattern may hold (see ExerciseLimits): a run of at most half an
    // hour, and no more notes, ghost notes and labels than the app can lay out at
    // once. A press that would break one draws nothing, and a drag that would is
    // stopped where it still keeps it; either way a toast says why when the finger
    // lifts. The settings screen holds the repetitions and the tempo to the same
    // limits, and the tempo slider here does too.

    /// The exercise as the store holds it now, which the tempo slider writes
    /// through, so the limits go by the tempo it has been dragged to.
    private var limitedExercise: Exercise {
        guard let exercise else { return Exercise(name: "") }
        return store.exercises.first { $0.id == exercise.id } ?? exercise
    }

    /// What the pattern on the roll asks of a run: where it ends, and how many
    /// things each repetition lays out.
    private var patternExtent: PatternExtent {
        PatternExtent(notes: notes, ghosts: ghosts, labels: texts)
    }

    /// The furthest beat a note or ghost note may reach: as far along the 1/4-beat
    /// grid as keeps the run within half an hour at the exercise's tempo and
    /// repetitions. An exercise already longer than that, from before the limit,
    /// keeps what it has: the limit is wherever its furthest note already reaches.
    private var noteEndLimit: Double {
        let exercise = limitedExercise
        let current = patternExtent
        let currentEnd = current.end ?? 0
        let allowance = exercise.lengthAllowance(over: current)
        let quarters = ExerciseLimits.furthest(from: Int((currentEnd * 4).rounded(.down)),
                                               to: Int(ExerciseLimits.patternBeats * 4)) { quarter in
            exercise.fitsLength(over: PatternExtent(end: Double(quarter) / 4, items: current.items),
                                allowance: allowance)
        }
        return max(currentEnd, Double(quarters) / 4)
    }

    /// Why a note or ghost note pressed at `start` can't be drawn, or nil when it
    /// can be: the pattern, or the run with every repetition, already holds as
    /// many as it may, or a note there would reach past the length limit.
    private func refusalOfNewNote(in layer: NoteLayer, startingAt start: Double) -> Refusal? {
        let held = layer == .melody ? notes.count : ghosts.count
        let limit = layer == .melody ? ExerciseLimits.notesPerRepetition : ExerciseLimits.ghostsPerRepetition
        guard held < limit, limitedExercise.fitsTimeline(items: patternExtent.items + 1) else {
            return .tooManyNotes
        }
        guard start + minLength <= noteEndLimit + beatEpsilon else { return .tooLong }
        return nil
    }

    /// Whether another label fits: in the pattern, and in the run with every
    /// repetition.
    private var hasRoomForLabel: Bool {
        texts.count < ExerciseLimits.labelsPerRepetition
            && limitedExercise.fitsTimeline(items: patternExtent.items + 1)
    }

    /// `proposed`, or the slowest whole BPM between it and the current tempo that
    /// keeps the run within the length limit when it doesn't, with the toast that
    /// says why the slider stops there.
    private func slowestFittingTempo(_ proposed: Double) -> Double {
        let base = limitedExercise
        let target = proposed.clamped(to: Exercise.tempoRange)
        let current = patternExtent
        let allowance = base.lengthAllowance(over: current)
        var trial = base
        trial.bpm = target
        guard !trial.fitsLength(over: current, allowance: allowance) else { return target }
        let slowest = ExerciseLimits.furthest(from: Int(base.bpm.rounded(.up)),
                                              to: Int(target.rounded(.down))) { value in
            var trial = base
            trial.bpm = Double(value)
            return trial.fitsLength(over: current, allowance: allowance)
        }
        showRefusal(.tooLong)
        return min(base.bpm, Double(slowest))
    }

    private func showRefusal(_ refusal: Refusal) {
        let message: String
        switch refusal {
        case .tooLong:
            message = L("Exercises Can Last Up to %d Minutes", ExerciseLimits.maxDurationMinutes)
        case .tooManyNotes:
            message = L("Too Many Notes")
        case .tooManyLabels:
            message = L("Too Many Labels")
        }
        toasts.show(message, icon: "exclamationmark.triangle.fill")
    }

    // MARK: - Overlap rules
    //
    // An exercise is sung, so only one note may sound at any moment: two notes must
    // never share a stretch of the timeline, no matter how far apart their pitches
    // are. Editing clamps every placement to keep that true; anything that slipped
    // through anyway (an older pattern, a downloaded one) is drawn red instead.
    //
    // Ghost notes are held to the very same rules among themselves, under two limits
    // at once: room for `maxGhostsAtOnce` of them at any moment, and on any one pitch
    // room for only one, just like notes. The two layers never block each other: a
    // ghost note sounding over a note is what it's for. So every rule below takes the
    // layer and pitch it's about and asks each of that note's limits, and with the
    // melody's single limit of one note comes down to its rule as it has always been.

    /// The limits a note of `layer` on `pitch` is held to, with `id`'s own note left
    /// out. The melody has room for one note at a time, whatever the pitches. Ghost
    /// notes have room for `maxGhostsAtOnce`, but for only one on the same pitch:
    /// two overlapping there would be heard as one note anyway.
    private func limits(in layer: NoteLayer, pitch: Int, excluding id: UUID?) -> [SoundingLimit] {
        let others = layerNotes(layer).filter { $0.id != id }
        switch layer {
        case .melody:
            return [SoundingLimit(notes: others, capacity: 1)]
        case .ghost:
            return [SoundingLimit(notes: others, capacity: maxGhostsAtOnce),
                    SoundingLimit(notes: others.filter { $0.pitch == pitch }, capacity: 1)]
        }
    }

    /// Free stretches of the timeline for a note of `layer` on `pitch`, as `(start,
    /// end)` beat pairs, with `id`'s own note left out: everywhere none of its limits
    /// is full. The last stretch runs to infinity.
    private func freeGaps(in layer: NoteLayer, pitch: Int,
                          excluding id: UUID?) -> [(start: Double, end: Double)] {
        var gaps: [(start: Double, end: Double)] = []
        var cursor = 0.0
        for span in fullSpans(in: layer, pitch: pitch, excluding: id) {
            if span.start > cursor + beatEpsilon { gaps.append((cursor, span.start)) }
            cursor = max(cursor, span.end)
        }
        gaps.append((cursor, .infinity))
        return gaps
    }

    /// The stretches over which a note of `layer` on `pitch` has no room left — one of
    /// its limits with as many notes sounding as it may hold — in the order they
    /// start, with `id`'s own note left out.
    private func fullSpans(in layer: NoteLayer, pitch: Int,
                           excluding id: UUID?) -> [(start: Double, end: Double)] {
        limits(in: layer, pitch: pitch, excluding: id)
            .flatMap(fullSpans(of:))
            .sorted { $0.start < $1.start }
    }

    /// The stretches over which `limit` is full. With room for a single note, that's
    /// every note it counts.
    private func fullSpans(of limit: SoundingLimit) -> [(start: Double, end: Double)] {
        guard limit.capacity > 1 else {
            return limit.notes.map { ($0.beat, $0.beat + $0.length) }
        }
        // How many sound only changes where a note starts or ends, so between two of
        // those edges it's whatever it is halfway along.
        let edges = Set(limit.notes.flatMap { [$0.beat, $0.beat + $0.length] }).sorted()
        return zip(edges, edges.dropFirst()).compactMap { start, end in
            let middle = (start + end) / 2
            let sounding = limit.notes.count { $0.beat < middle && $0.beat + $0.length > middle }
            return sounding >= limit.capacity ? (start, end) : nil
        }
    }

    /// How many of `notes` are sounding at `beat`.
    private func soundingCount(at beat: Double, of notes: [MIDINote]) -> Int {
        notes.count { note in
            beat >= note.beat - beatEpsilon
                && beat < note.beat + note.length - beatEpsilon
        }
    }

    /// How many of `notes` are sounding just before `beat` — the ones still going as
    /// it's reached, not the ones starting on it.
    private func soundingCount(before beat: Double, of notes: [MIDINote]) -> Int {
        notes.count { note in
            note.beat < beat - beatEpsilon
                && note.beat + note.length > beat - beatEpsilon
        }
    }

    /// The note sounding at `beat`, if any — at most one ever is, since the editor
    /// keeps notes off each other. Ghost notes aren't asked about: this is what a
    /// label snaps to, and a label belongs to what is sung.
    private func noteSounding(at beat: Double, excluding id: UUID? = nil) -> MIDINote? {
        notes.first { note in
            note.id != id
                && beat >= note.beat - beatEpsilon
                && beat < note.beat + note.length - beatEpsilon
        }
    }

    /// Is there no room at `beat` for a note of `layer` on `pitch` — a note already
    /// sounding there, or for a ghost note as many as may sound at once, or one on
    /// the same pitch?
    private func isOccupied(_ beat: Double, in layer: NoteLayer, pitch: Int,
                            excluding id: UUID? = nil) -> Bool {
        limits(in: layer, pitch: pitch, excluding: id).contains {
            soundingCount(at: beat, of: $0.notes) >= $0.capacity
        }
    }

    /// How long a note of `layer` on `pitch` starting at `beat` may grow before it
    /// runs into the next one — for a ghost note, the next one to start where that
    /// leaves no room, or the next on the same pitch.
    private func spaceAfter(_ beat: Double, in layer: NoteLayer, pitch: Int,
                            excluding id: UUID? = nil) -> Double {
        let next = limits(in: layer, pitch: pitch, excluding: id)
            .flatMap { limit in
                limit.notes.filter {
                    $0.beat > beat + beatEpsilon
                        && soundingCount(at: $0.beat, of: limit.notes) >= limit.capacity
                }
            }
            .map(\.beat)
            .min()
        return (next ?? .infinity) - beat
    }

    /// How far a note of `layer` on `pitch` ending at `beat` may grow leftwards before
    /// it runs into the previous one — for a ghost note, the previous one to end where
    /// that leaves no room, or the previous on the same pitch — or the start of the
    /// timeline.
    private func spaceBefore(_ beat: Double, in layer: NoteLayer, pitch: Int,
                             excluding id: UUID? = nil) -> Double {
        let previousEnd = limits(in: layer, pitch: pitch, excluding: id)
            .flatMap { limit in
                limit.notes.filter {
                    let end = $0.beat + $0.length
                    return end < beat + beatEpsilon
                        && soundingCount(before: end, of: limit.notes) >= limit.capacity
                }
            }
            .map { $0.beat + $0.length }
            .max()
        return beat - max(0, previousEnd ?? 0)
    }

    /// The first beat from `origin` rightwards a new note of `layer` on `pitch` may
    /// start on: `origin` itself when there's room, otherwise the end of whatever is
    /// in the way. `nil` if nothing to the right can hold a note.
    private func nextFreeStart(atOrAfter origin: Double, in layer: NoteLayer, pitch: Int) -> Double? {
        for gap in freeGaps(in: layer, pitch: pitch, excluding: nil) {
            let start = max(gap.start, origin)
            if gap.end - start >= minLength - beatEpsilon { return start }
        }
        return nil
    }

    /// The last beat up to `origin` a new note of `layer` on `pitch` may end on:
    /// `origin` itself when there's room in front of it, otherwise the start of
    /// whatever is in the way. `nil` if nothing to the left can hold a note.
    private func previousFreeEnd(atOrBefore origin: Double, in layer: NoteLayer, pitch: Int) -> Double? {
        var result: Double? = nil
        for gap in freeGaps(in: layer, pitch: pitch, excluding: nil) where gap.start <= origin + beatEpsilon {
            let end = min(gap.end, origin)
            if end - gap.start >= minLength - beatEpsilon { result = end }
        }
        return result
    }

    /// Where a note of `layer` on `pitch` and `length` dragged to `desired` may
    /// actually land: inside the free gap the drag is centred on, or the nearest gap
    /// big enough if that one is taken. `nil` when nothing on the timeline can hold it.
    private func placement(desired: Double, length: Double, in layer: NoteLayer, pitch: Int,
                           excluding id: UUID?) -> Double? {
        let fitting = freeGaps(in: layer, pitch: pitch, excluding: id)
            .filter { $0.end - $0.start >= length - beatEpsilon }
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
            let others = all.enumerated().filter { $0.offset != i }.map(\.element)
            let spans = stretches(of: a, under: others)
            if !spans.isEmpty { result[a.id] = spans }
        }
        return result
    }

    /// Stretches of each note that a ghost note of the same pitch lies over, which
    /// are painted a colour of their own: drawn see-through green on green, a ghost
    /// note laid over a note would all but vanish into it.
    private func ghostCoverSpans(of notes: [MIDINote],
                                 by ghosts: [MIDINote]) -> [UUID: [(start: Double, end: Double)]] {
        var result: [UUID: [(start: Double, end: Double)]] = [:]
        for note in notes {
            let spans = stretches(of: note, under: ghosts.filter { $0.pitch == note.pitch })
            if !spans.isEmpty { result[note.id] = spans }
        }
        return result
    }

    /// The stretches of `note` that any of `others` sounds over, merged.
    private func stretches(of note: MIDINote,
                           under others: [MIDINote]) -> [(start: Double, end: Double)] {
        var spans: [(start: Double, end: Double)] = []
        for other in others {
            let start = max(note.beat, other.beat)
            let end = min(note.beat + note.length, other.beat + other.length)
            if end - start > beatEpsilon { spans.append((start, end)) }
        }
        var merged: [(start: Double, end: Double)] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, span.start <= last.end + beatEpsilon {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        return merged
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
        CGRect(
            x: CGFloat(label.beat) * beatW,
            y: CGFloat(hiPitch - label.pitch) * rowH,
            width: midiTextChipWidth(label.text),
            height: rowH
        )
    }

    /// How far each of `texts` is shrunk where it's drawn, in the same order. Labels
    /// whose chips would overlap, or come closer than `textLabelMargin`, shrink alike
    /// until that margin is clear between them: the chip and the text in it, about
    /// the label's middle. Chips on different rows always clear each other, so in
    /// practice that's labels side by side on one row.
    private var textScales: [Double] {
        fittedTextLabelScales(texts.map { label in
            let rect = textRect(for: label)
            // The chip as it's drawn, inset from the label's rect (see `rollCanvas`).
            return TextLabelBox(centre: CGPoint(x: rect.midX, y: rect.midY),
                                size: CGSize(width: rect.width - 2, height: rect.height - 6))
        })
    }

    /// `textRect` with the chip narrowed about its middle to `scale` of its width, the
    /// way `textScales` shrinks it: what's drawn, and what a touch has to land in to
    /// pick the label up. Still the full row high.
    private func drawnTextRect(for label: MIDIText, scale: Double) -> CGRect {
        let rect = textRect(for: label)
        // The chip is drawn 1 pt in from either side of the rect, and it's the chip
        // that's narrowed.
        return rect.insetBy(dx: (rect.width - 2) * (1 - CGFloat(scale)) / 2, dy: 0)
    }

    /// Where a label's middle lands when it's dropped at `centre`: on the middle of
    /// whatever note it's over — however many rows above or below that note it is,
    /// since only the sideways position is snapped — and otherwise on the 1/4-beat
    /// grid, like everything else on the roll.
    private func snappedTextCentre(_ centre: Double) -> Double {
        if let note = noteSounding(at: centre) { return note.beat + note.length / 2 }
        return snapped(centre)
    }

    /// The line shown while a label under the finger is snapped to a note's middle, in
    /// grid coordinates: the beat both middles stand on, and how far up and down it
    /// reaches. `nil` whenever there's nothing to mark — no label being held, or one
    /// that has fallen back to the 1/4-beat grid — so the line goes as the finger
    /// lifts, and the moment the label is dragged off the note.
    ///
    /// Drawn for a label being held still as well as one being dragged: the drag's own
    /// `moved` flag turns off again whenever the finger comes back within the tap
    /// threshold of where it started, which would blink the line off under a finger
    /// that hasn't left the note.
    ///
    /// A label dragged onto the note's own row has its middle *on* the note's, leaving
    /// no gap between the two to draw across. There the line is the note's own height
    /// instead, so the alignment still shows without reaching outside the note.
    private var textSnapLine: (x: CGFloat, top: CGFloat, bottom: CGFloat)? {
        guard case .movingText(let id, _, _) = interaction,
              let label = texts.first(where: { $0.id == id }),
              let note = noteSounding(at: label.centreBeat),
              abs(note.beat + note.length / 2 - label.centreBeat) < beatEpsilon
        else { return nil }

        let noteBox = rect(for: note).insetBy(dx: 1, dy: 1)
        let x = CGFloat(label.centreBeat) * beatW
        guard label.pitch != note.pitch else { return (x, noteBox.minY, noteBox.maxY) }
        let textMid = textRect(for: label).midY
        return (x, min(textMid, noteBox.midY), max(textMid, noteBox.midY))
    }

    /// Touches land in the roll's own space, which starts at the dead margin; notes
    /// and labels are laid out in the grid's, which starts at beat 0.
    private func gridPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - leadW, y: point.y)
    }

    private func noteAt(_ point: CGPoint, in layer: NoteLayer) -> MIDINote? {
        let p = gridPoint(point)
        return layerNotes(layer).last { rect(for: $0).contains(p) }
    }

    private func textAt(_ point: CGPoint) -> MIDIText? {
        let p = gridPoint(point)
        let scales = textScales
        return texts.indices.last { drawnTextRect(for: texts[$0], scale: scales[$0]).contains(p) }
            .map { texts[$0] }
    }

    /// Which end of `note` a press at `x` takes hold of, or `nil` for the middle of it,
    /// which moves the note instead. The grab zones are as wide on screen whatever the
    /// zoom, and shrink along with the note so even the shortest one keeps a middle to
    /// move it by.
    private func resizeEdge(of note: MIDINote, x: CGFloat) -> ResizeEdge? {
        let box = rect(for: note)
        let zone = min(14 / camera.shot.zoom, box.width / 3)
        if x - box.minX < zone { return .leading }
        if box.maxX - x < zone { return .trailing }
        return nil
    }

    private func pitchAt(_ y: CGFloat) -> Int {
        let row = Int(y / rowH)
        return max(loPitch, min(hiPitch, hiPitch - row))
    }

    private func beatValue(_ x: CGFloat) -> Double {
        Double(x - leadW) / Double(beatW)
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

    private var ghostSaveKey: String {
        "midighost_\(exercise?.id.uuidString ?? "standalone")"
    }

    private func saveNotes() { writeNotes(notes) }

    private func writeNotes(_ value: [MIDINote]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: saveKey)
        recordEdit(if: value != savedNotes)
        scheduleServerSync()
    }

    /// Writes the labels through, all but one that's been placed and not typed yet:
    /// that one only joins the pattern once its text is committed, so placing a label
    /// and cancelling it (or committing it empty) leaves what's stored, the
    /// exercise's dates and its server copies as they were. Nothing is written when
    /// the stored labels wouldn't change, or the write would stamp the date afresh
    /// over an earlier edit (see `recordEdit`).
    private func saveTexts() {
        let committed = texts.filter { $0.id != pendingTextID }
        guard committed != loadPattern([MIDIText].self, forKey: textSaveKey) else { return }
        writeTexts(committed)
    }

    /// The label the text tool has just placed, while the alert asks for its text for
    /// the first time.
    private var pendingTextID: UUID? { isNewText ? editingTextID : nil }

    private func writeTexts(_ value: [MIDIText]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: textSaveKey)
        recordEdit(if: value != savedTexts)
        scheduleServerSync()
    }

    /// Stamps the exercise as just edited when a write leaves its pattern
    /// different from how the editor found it. Leaving without saving writes back
    /// what the editor opened with, and that isn't an edit.
    private func recordEdit(if changed: Bool) {
        guard changed, let exercise else { return }
        ExerciseDates.markEdited(exercise.id)
    }

    /// Pattern edits write to UserDefaults directly, bypassing the store the
    /// server syncs observe — so kick them explicitly. Keeps a public exercise's
    /// server copy current without toggling its visibility.
    private func scheduleServerSync() {
        guard exercise != nil else { return }
        ProfileSync.shared.scheduleUpload()
        CommunitySync.shared.scheduleUpload()
    }

    private func saveGhosts() { writeGhosts(ghosts) }

    private func writeGhosts(_ value: [MIDINote]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: ghostSaveKey)
        recordEdit(if: value != savedGhosts)
        scheduleServerSync()
    }

    /// What's stored under `key`, or nothing when there's nothing there yet.
    private func loadPattern<Item: Decodable>(_ type: [Item].Type, forKey key: String) -> [Item] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(type, from: data)
        else { return [] }
        return saved
    }
}

// MARK: - Edge scrolling

/// What scrolling the roll while a drag holds the finger near its edge keeps from one
/// frame to the next. None of it is drawn, so it lives in a reference the screen doesn't
/// watch: the finger moving, or the roll scrolling up and down, redraws nothing by
/// itself.
private final class RollEdgeScroll {
    /// A drag on the roll while the finger is down, in the space of the roll's
    /// viewport, which stays put however the roll is scrolled.
    struct Drag {
        /// Where the press landed, in the roll's own space.
        var start: CGPoint
        /// Where the press landed in the viewport.
        var pressedAt: CGPoint
        /// Where the finger is now in the viewport.
        var finger: CGPoint
    }

    /// One tick of the display link.
    struct Frame {
        /// Seconds since the last tick.
        var step: CFTimeInterval
        /// Seconds since this run of scrolling began.
        var elapsed: CFTimeInterval
    }

    var drag: Drag?

    /// Set the first time a drag has the roll moved under it (a step of edge scrolling,
    /// or the margin in front of beat 0 changing) until the finger lifts: from then on
    /// the finger has the say over where the roll is, and playback leaves it there.
    var steered = false

    /// Ticks once a frame while edge scrolling runs.
    let frames = PassthroughSubject<Frame, Never>()

    private var link: CADisplayLink?
    private var startedAt: CFTimeInterval?
    private var lastTick: CFTimeInterval?

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: RollEdgeScrollTarget(self),
                                 selector: #selector(RollEdgeScrollTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        startedAt = nil
        lastTick = nil
    }

    /// Done with the drag: stops any scrolling and forgets it.
    func end() {
        stop()
        drag = nil
        steered = false
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        // The first tick goes by the frame it's for: there's no last one to go by.
        let step = lastTick.map { now - $0 } ?? (link.targetTimestamp - now)
        let startedAt = startedAt ?? now
        self.startedAt = startedAt
        lastTick = now
        frames.send(Frame(step: step, elapsed: now - startedAt))
    }
}

/// The whole numbers from `lower` rounded down to `upper` rounded up, held to `limits`:
/// the rows or beats a stretch of the roll reaches. `nil` when it reaches none of them.
private func wholeSpan(_ lower: CGFloat, _ upper: CGFloat,
                       within limits: ClosedRange<Int>) -> ClosedRange<Int>? {
    guard lower.isFinite, upper.isFinite else { return nil }
    let first = max(limits.lowerBound, Int(max(lower, CGFloat(limits.lowerBound - 1)).rounded(.down)))
    let last = min(limits.upperBound, Int(min(upper, CGFloat(limits.upperBound + 1)).rounded(.up)))
    return first <= last ? first...last : nil
}

// MARK: - Presses on the roll

/// What a press on the roll keeps while its fingers are down, none of it drawn: whether
/// the tools may still have it, and the pattern from before they did anything with it.
private final class RollPress {
    /// Whether a finger of the press is on the roll.
    var isDown = false
    /// Set once the press has turned into moving the roll, or turned out to be there
    /// only to stop it gliding, until both its fingers and the tools' drag are done
    /// with it: the tools hear no more of it.
    var toolLocked = false
    /// The pattern as the tools' drag found it, to put back if two fingers take the
    /// press over. Kept from the drag's first move until it ends.
    var before: PatternSnapshot?
}

/// A pattern, and the exercise's dates, at one moment.
private struct PatternSnapshot {
    var notes: [MIDINote]
    var ghosts: [MIDINote]
    var texts: [MIDIText]
    var dates: ExerciseTimestamps?
}

/// What the display link calls. A display link keeps its target, so this holds the
/// edge scrolling only weakly, and stops the link should that ever be gone.
private final class RollEdgeScrollTarget: NSObject {
    private weak var owner: RollEdgeScroll?

    init(_ owner: RollEdgeScroll) {
        self.owner = owner
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.tick(link)
    }
}
