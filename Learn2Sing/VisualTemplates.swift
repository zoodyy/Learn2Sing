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

    init(id: UUID = UUID(), name: String,
         noteColor: String, noteRoundness: Double, verticalZoom: Double,
         horizontalZoom: Double, followVertical: Bool, showLines: Bool,
         background: String, showKeyboard: Bool, showPitches: Bool,
         textColor: String, textFont: String) {
        self.id = id
        self.name = name
        self.noteColor = noteColor
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
            noteRoundness: dbl(VisualKeys.noteRoundness, VisualDefaults.noteRoundness),
            verticalZoom: dbl(VisualKeys.verticalZoom, VisualDefaults.verticalZoom),
            horizontalZoom: dbl(VisualKeys.horizontalZoom, VisualDefaults.horizontalZoom),
            followVertical: bool(VisualKeys.followVertical, VisualDefaults.followVertical),
            showLines: bool(VisualKeys.showLines, VisualDefaults.showLines),
            background: str(VisualKeys.background, VisualDefaults.background),
            showKeyboard: bool(VisualKeys.showKeyboard, VisualDefaults.showKeyboard),
            showPitches: bool(VisualKeys.showPitches, VisualDefaults.showPitches),
            textColor: str(VisualKeys.textColor, VisualDefaults.textColor),
            textFont: str(VisualKeys.textFont, VisualDefaults.textFont))
    }

    /// Writes this template's values into UserDefaults under the `VisualKeys`. The
    /// @AppStorage-bound controls and the live PlaybackView both read those keys, so
    /// applying a template updates the editor (and its preview) and the real playback.
    func apply() {
        let d = UserDefaults.standard
        d.set(noteColor, forKey: VisualKeys.noteColor)
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
    }

    /// True when this template's stored values match what is currently in UserDefaults,
    /// i.e. it is the look on screen right now. Used to mark the selected template and
    /// to clear the selection once the user starts editing again.
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
final class VisualTemplateStore: ObservableObject {
    @Published private(set) var templates: [VisualTemplate] = []

    private static let storageKey = "vis_templates"
    private static let bundledSeededKey = "didSeedBundledVisualTemplates"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([VisualTemplate].self, from: data) {
            templates = decoded
        }
        seedBundledIfNeeded()
    }

    /// On first launch, add the template shipped in the app bundle and apply it as the
    /// starting look for the playback visuals. Gated by a flag so the user's later
    /// edits or deletion of it are never undone.
    private func seedBundledIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.bundledSeededKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: Self.bundledSeededKey) }
        guard let url = Bundle.main.url(forResource: "SimplestTemplate", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let template = VisualTemplate.decode(from: data)
        else { return }
        templates.append(template)
        persist()
        template.apply()
    }

    func add(_ template: VisualTemplate) {
        templates.append(template)
        persist()
    }

    func remove(atOffsets offsets: IndexSet) {
        templates.remove(atOffsets: offsets)
        persist()
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

    private func persist() {
        if let data = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
