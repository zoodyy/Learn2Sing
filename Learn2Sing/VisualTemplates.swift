import Foundation
import SwiftUI
import Combine

// Named snapshots of the playback-visual settings. A template stores exactly the same
// raw values that back the @AppStorage controls in PlaybackVisualsView, so capturing
// the current look and re-applying a saved one are both lossless. The list of
// templates is persisted as JSON in UserDefaults, and a single template can be shared
// to / loaded from a `.json` file via the export/import buttons.

/// A named set of playback-visual settings, stored as the raw values used by
/// `VisualKeys`/`VisualDefaults` (hex colour strings, numbers, bools, the font's raw
/// value) so it round-trips through UserDefaults and JSON without any lossy conversion.
struct VisualTemplate: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var noteColor: String
    var playingNoteColor: String
    var noteRoundness: Double
    var verticalZoom: Double
    var horizontalZoom: Double
    var followVertical: Bool
    var showLines: Bool
    var background: String
    var showKeyboard: Bool
    var showPitches: Bool
    var textColor: String
    var textFont: String
    var singerSize: Double
    var singerInnerColor: String
    var singerOuterColor: String
    var singerLineColor: String
    var playheadColor: String
    var playheadStyle: String
    var hideUnusedDots: Bool
    var showRepetitionCounter: Bool
    var repetitionCounterPosition: String
    var hideTabBar: Bool

    init(id: UUID = UUID(), name: String,
         noteColor: String, playingNoteColor: String, noteRoundness: Double,
         verticalZoom: Double, horizontalZoom: Double, followVertical: Bool,
         showLines: Bool, background: String, showKeyboard: Bool, showPitches: Bool,
         textColor: String, textFont: String,
         singerSize: Double, singerInnerColor: String,
         singerOuterColor: String, singerLineColor: String,
         playheadColor: String, playheadStyle: String, hideUnusedDots: Bool,
         showRepetitionCounter: Bool, repetitionCounterPosition: String,
         hideTabBar: Bool) {
        self.id = id
        self.name = name
        self.noteColor = noteColor
        self.playingNoteColor = playingNoteColor
        self.noteRoundness = noteRoundness
        self.verticalZoom = verticalZoom
        self.horizontalZoom = horizontalZoom
        self.followVertical = followVertical
        self.showLines = showLines
        self.background = background
        self.showKeyboard = showKeyboard
        self.showPitches = showPitches
        self.textColor = textColor
        self.textFont = textFont
        self.singerSize = singerSize
        self.singerInnerColor = singerInnerColor
        self.singerOuterColor = singerOuterColor
        self.singerLineColor = singerLineColor
        self.playheadColor = playheadColor
        self.playheadStyle = playheadStyle
        self.hideUnusedDots = hideUnusedDots
        self.showRepetitionCounter = showRepetitionCounter
        self.repetitionCounterPosition = repetitionCounterPosition
        self.hideTabBar = hideTabBar
    }

    /// Custom decoding so templates saved (or bundled) before a setting existed still
    /// load: any missing key falls back to its `VisualDefaults` value rather than
    /// failing the whole decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        noteColor = try c.decodeIfPresent(String.self, forKey: .noteColor) ?? VisualDefaults.noteColor
        playingNoteColor = try c.decodeIfPresent(String.self, forKey: .playingNoteColor) ?? VisualDefaults.playingNoteColor
        noteRoundness = try c.decodeIfPresent(Double.self, forKey: .noteRoundness) ?? VisualDefaults.noteRoundness
        verticalZoom = try c.decodeIfPresent(Double.self, forKey: .verticalZoom) ?? VisualDefaults.verticalZoom
        horizontalZoom = try c.decodeIfPresent(Double.self, forKey: .horizontalZoom) ?? VisualDefaults.horizontalZoom
        followVertical = try c.decodeIfPresent(Bool.self, forKey: .followVertical) ?? VisualDefaults.followVertical
        showLines = try c.decodeIfPresent(Bool.self, forKey: .showLines) ?? VisualDefaults.showLines
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? VisualDefaults.background
        showKeyboard = try c.decodeIfPresent(Bool.self, forKey: .showKeyboard) ?? VisualDefaults.showKeyboard
        showPitches = try c.decodeIfPresent(Bool.self, forKey: .showPitches) ?? VisualDefaults.showPitches
        textColor = try c.decodeIfPresent(String.self, forKey: .textColor) ?? VisualDefaults.textColor
        textFont = try c.decodeIfPresent(String.self, forKey: .textFont) ?? VisualDefaults.textFont
        singerSize = try c.decodeIfPresent(Double.self, forKey: .singerSize) ?? VisualDefaults.singerSize
        singerInnerColor = try c.decodeIfPresent(String.self, forKey: .singerInnerColor) ?? VisualDefaults.singerInnerColor
        singerOuterColor = try c.decodeIfPresent(String.self, forKey: .singerOuterColor) ?? VisualDefaults.singerOuterColor
        singerLineColor = try c.decodeIfPresent(String.self, forKey: .singerLineColor) ?? VisualDefaults.singerLineColor
        playheadColor = try c.decodeIfPresent(String.self, forKey: .playheadColor) ?? VisualDefaults.playheadColor
        playheadStyle = try c.decodeIfPresent(String.self, forKey: .playheadStyle) ?? VisualDefaults.playheadStyle
        hideUnusedDots = try c.decodeIfPresent(Bool.self, forKey: .hideUnusedDots) ?? VisualDefaults.hideUnusedDots
        showRepetitionCounter = try c.decodeIfPresent(Bool.self, forKey: .showRepetitionCounter) ?? VisualDefaults.showRepetitionCounter
        repetitionCounterPosition = try c.decodeIfPresent(String.self, forKey: .repetitionCounterPosition) ?? VisualDefaults.repetitionCounterPosition
        hideTabBar = try c.decodeIfPresent(Bool.self, forKey: .hideTabBar) ?? VisualDefaults.hideTabBar
    }

    /// Captures the settings currently stored in UserDefaults into a new template,
    /// using the same defaulting as `VisualSettings.current` so an untouched setting
    /// is captured as its default rather than as a missing value.
    static func capturingCurrent(name: String) -> VisualTemplate {
        let d = UserDefaults.standard
        func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        func str(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }
        return VisualTemplate(
            name: name,
            noteColor: str(VisualKeys.noteColor, VisualDefaults.noteColor),
            playingNoteColor: str(VisualKeys.playingNoteColor, VisualDefaults.playingNoteColor),
            noteRoundness: dbl(VisualKeys.noteRoundness, VisualDefaults.noteRoundness),
            verticalZoom: dbl(VisualKeys.verticalZoom, VisualDefaults.verticalZoom),
            horizontalZoom: dbl(VisualKeys.horizontalZoom, VisualDefaults.horizontalZoom),
            followVertical: bool(VisualKeys.followVertical, VisualDefaults.followVertical),
            showLines: bool(VisualKeys.showLines, VisualDefaults.showLines),
            background: str(VisualKeys.background, VisualDefaults.background),
            showKeyboard: bool(VisualKeys.showKeyboard, VisualDefaults.showKeyboard),
            showPitches: bool(VisualKeys.showPitches, VisualDefaults.showPitches),
            textColor: str(VisualKeys.textColor, VisualDefaults.textColor),
            textFont: str(VisualKeys.textFont, VisualDefaults.textFont),
            singerSize: dbl(VisualKeys.singerSize, VisualDefaults.singerSize),
            singerInnerColor: str(VisualKeys.singerInnerColor, VisualDefaults.singerInnerColor),
            singerOuterColor: str(VisualKeys.singerOuterColor, VisualDefaults.singerOuterColor),
            singerLineColor: str(VisualKeys.singerLineColor, VisualDefaults.singerLineColor),
            playheadColor: str(VisualKeys.playheadColor, VisualDefaults.playheadColor),
            playheadStyle: str(VisualKeys.playheadStyle, VisualDefaults.playheadStyle),
            hideUnusedDots: bool(VisualKeys.hideUnusedDots, VisualDefaults.hideUnusedDots),
            showRepetitionCounter: bool(VisualKeys.showRepetitionCounter, VisualDefaults.showRepetitionCounter),
            repetitionCounterPosition: str(VisualKeys.repetitionCounterPosition, VisualDefaults.repetitionCounterPosition),
            hideTabBar: bool(VisualKeys.hideTabBar, VisualDefaults.hideTabBar))
    }

    /// Writes this template's values into UserDefaults under the `VisualKeys`. The
    /// @AppStorage-bound controls and the live PlaybackView both read those keys, so
    /// applying a template updates the editor (and its preview) and the real playback.
    func apply() {
        let d = UserDefaults.standard
        d.set(noteColor, forKey: VisualKeys.noteColor)
        d.set(playingNoteColor, forKey: VisualKeys.playingNoteColor)
        d.set(noteRoundness, forKey: VisualKeys.noteRoundness)
        d.set(verticalZoom, forKey: VisualKeys.verticalZoom)
        d.set(horizontalZoom, forKey: VisualKeys.horizontalZoom)
        d.set(followVertical, forKey: VisualKeys.followVertical)
        d.set(showLines, forKey: VisualKeys.showLines)
        d.set(background, forKey: VisualKeys.background)
        d.set(showKeyboard, forKey: VisualKeys.showKeyboard)
        d.set(showPitches, forKey: VisualKeys.showPitches)
        d.set(textColor, forKey: VisualKeys.textColor)
        d.set(textFont, forKey: VisualKeys.textFont)
        d.set(singerSize, forKey: VisualKeys.singerSize)
        d.set(singerInnerColor, forKey: VisualKeys.singerInnerColor)
        d.set(singerOuterColor, forKey: VisualKeys.singerOuterColor)
        d.set(singerLineColor, forKey: VisualKeys.singerLineColor)
        d.set(playheadColor, forKey: VisualKeys.playheadColor)
        d.set(playheadStyle, forKey: VisualKeys.playheadStyle)
        d.set(hideUnusedDots, forKey: VisualKeys.hideUnusedDots)
        d.set(showRepetitionCounter, forKey: VisualKeys.showRepetitionCounter)
        d.set(repetitionCounterPosition, forKey: VisualKeys.repetitionCounterPosition)
        d.set(hideTabBar, forKey: VisualKeys.hideTabBar)
    }

    /// True when this template's stored values match what is currently in UserDefaults,
    /// i.e. it is the look on screen right now. The selection itself is explicit (see
    /// `VisualTemplateStore.selectedID`); this only answers whether the settings on
    /// screen are already stored somewhere, so nothing is lost by switching template.
    var matchesCurrent: Bool {
        var current = VisualTemplate.capturingCurrent(name: name)
        current.id = id
        return current == self
    }

    /// JSON encoding of a single template, used by the export file dialog.
    func jsonData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }

    /// Decodes a single template from exported JSON (rejecting anything else).
    static func decode(from data: Data) -> VisualTemplate? {
        try? JSONDecoder().decode(VisualTemplate.self, from: data)
    }
}

/// Holds the user's saved visual templates, persisting the list to UserDefaults as
/// JSON so it survives across launches.
///
/// Exactly one template can be *selected* at a time, and the selection is stored by
/// id rather than inferred from the values on screen — so a template stays selected
/// while it is being edited, and a newly saved template doesn't make every other
/// template that happens to hold the same values look selected too. While a template
/// is selected, `syncSelectedWithCurrent()` writes each change on the visuals screen
/// straight back into it.
final class VisualTemplateStore: ObservableObject {
    @Published private(set) var templates: [VisualTemplate] = []

    /// The template the playback visuals are currently being edited *as*, or `nil`
    /// when the settings on screen belong to no template.
    @Published private(set) var selectedID: UUID?

    private static let storageKey = "vis_templates"
    private static let bundledSeededKey = "didSeedBundledVisualTemplates"
    /// The selected template's id (a UUID string), so the selection survives launches.
    static let selectionKey = "vis_selectedTemplate"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([VisualTemplate].self, from: data) {
            templates = decoded
        }
        if let raw = UserDefaults.standard.string(forKey: Self.selectionKey),
           let id = UUID(uuidString: raw), templates.contains(where: { $0.id == id }) {
            selectedID = id
        }
        seedBundledIfNeeded()
    }

    /// The selected template, if any.
    var selected: VisualTemplate? {
        templates.first { $0.id == selectedID }
    }

    /// True when the settings currently on screen are stored in a template: either
    /// the selected one (which they are written into as they change), or — with
    /// nothing selected — a template that happens to hold exactly these values.
    /// When this is false, switching to a template would throw the settings away.
    var currentSettingsAreSaved: Bool {
        selectedID != nil || templates.contains(where: \.matchesCurrent)
    }

    /// The template shipped in the app bundle: the playback look a fresh install
    /// starts on, which is also what Settings ▸ Reset puts the visuals back to.
    static var bundledTemplate: VisualTemplate? {
        guard let url = Bundle.main.url(forResource: "SimplestTemplate", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return VisualTemplate.decode(from: data)
    }

    /// On first launch, add the template shipped in the app bundle, apply it as the
    /// starting look for the playback visuals and select it, so edits on the visuals
    /// screen go into it. Gated by a flag so the user's later edits or deletion of it
    /// are never undone.
    private func seedBundledIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.bundledSeededKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: Self.bundledSeededKey) }
        guard let template = Self.bundledTemplate else { return }
        templates.append(template)
        persist()
        select(template)
    }

    /// Applies `template` and makes it the selected one, so every later change on the
    /// visuals screen is saved back into it. The selection moves *before* the values
    /// are written: applying changes UserDefaults, and that change comes back through
    /// `syncSelectedWithCurrent()` — which would otherwise write the new look into the
    /// template the user is switching away from.
    func select(_ template: VisualTemplate) {
        selectedID = template.id
        persistSelection()
        template.apply()
    }

    /// Detaches from the selected template. The settings on screen stay exactly as
    /// they are; they just stop being written into a template.
    func deselect() {
        selectedID = nil
        persistSelection()
    }

    /// Writes the settings currently in UserDefaults into the selected template, which
    /// is what makes edits on the visuals screen save themselves. Does nothing when no
    /// template is selected or when nothing actually changed, so it is safe to call on
    /// every `UserDefaults` change.
    func syncSelectedWithCurrent() {
        guard let id = selectedID,
              let index = templates.firstIndex(where: { $0.id == id }) else { return }
        var updated = VisualTemplate.capturingCurrent(name: templates[index].name)
        updated.id = id
        guard updated != templates[index] else { return }
        templates[index] = updated
        persist()
    }

    /// Adds a newly saved template and selects it: its values are the ones on screen,
    /// so from here on they belong to it.
    func add(_ template: VisualTemplate) {
        templates.append(template)
        persist()
        select(template)
    }

    func remove(atOffsets offsets: IndexSet) {
        let removed = offsets.map { templates[$0].id }
        templates.remove(atOffsets: offsets)
        persist()
        // Deleting the selected template leaves its look on screen, but with nothing
        // to save changes into.
        if let id = selectedID, removed.contains(id) {
            selectedID = nil
            persistSelection()
        }
    }

    /// Adds an imported template, giving it a fresh id so importing the same file more
    /// than once doesn't overwrite or shadow an existing entry. Returns the stored copy
    /// (with its new id) so the caller can apply it.
    @discardableResult
    func add(imported template: VisualTemplate) -> VisualTemplate {
        var copy = template
        copy.id = UUID()
        templates.append(copy)
        persist()
        return copy
    }

    /// Settings ▸ Reset ▸ Visuals: back to the look a fresh install starts on. If a
    /// stored template still holds exactly that look — normally the seeded bundled one,
    /// untouched — it becomes the selected template again; otherwise the reset settings
    /// belong to no template, and the user's own templates are left alone.
    func resetToBundled() {
        // Detach first, so the reset values aren't saved into whatever was selected.
        selectedID = nil
        Self.bundledTemplate?.apply()
        selectedID = templates.first(where: \.matchesCurrent)?.id
        persistSelection()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func persistSelection() {
        let defaults = UserDefaults.standard
        if let selectedID {
            defaults.set(selectedID.uuidString, forKey: Self.selectionKey)
        } else {
            defaults.removeObject(forKey: Self.selectionKey)
        }
    }
}
