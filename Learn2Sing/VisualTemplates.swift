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
    var autoPitchNameColor: Bool
    var pitchNameColor: String
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
         autoPitchNameColor: Bool, pitchNameColor: String,
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
        self.autoPitchNameColor = autoPitchNameColor
        self.pitchNameColor = pitchNameColor
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
        autoPitchNameColor = try c.decodeIfPresent(Bool.self, forKey: .autoPitchNameColor) ?? VisualDefaults.autoPitchNameColor
        pitchNameColor = try c.decodeIfPresent(String.self, forKey: .pitchNameColor) ?? VisualDefaults.pitchNameColor
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
            autoPitchNameColor: bool(VisualKeys.autoPitchNameColor, VisualDefaults.autoPitchNameColor),
            pitchNameColor: str(VisualKeys.pitchNameColor, VisualDefaults.pitchNameColor),
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
        d.set(autoPitchNameColor, forKey: VisualKeys.autoPitchNameColor)
        d.set(pitchNameColor, forKey: VisualKeys.pitchNameColor)
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

    /// True when `other` holds exactly the same settings as this template — the same
    /// look, whichever template it is and whatever it is called.
    func hasSameValues(as other: VisualTemplate) -> Bool {
        var normalised = other
        normalised.id = id
        normalised.name = name
        return normalised == self
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
///
/// Selecting is always the user's own doing — tapping a row, saving or importing a
/// template. Where the app puts a look on screen by itself (the first launch, a theme
/// change, Settings ▸ Reset) it applies one of its own two without selecting it, so
/// nothing it does on its own starts writing later edits into a template.
final class VisualTemplateStore: ObservableObject {
    @Published private(set) var templates: [VisualTemplate] = []

    /// The template the playback visuals are currently being edited *as*, or `nil`
    /// when the settings on screen belong to no template.
    @Published private(set) var selectedID: UUID?

    private static let storageKey = "vis_templates"
    /// The ids of the bundled templates already added to the list. Remembered per
    /// template so one the user deletes isn't handed straight back at the next launch,
    /// while a look a later version starts shipping still arrives.
    private static let seededIDsKey = "vis_seededBundledTemplates"
    /// The flag an earlier version set once it had seeded the one bundled template
    /// there was then — the dark look. Read so an install carrying it is handed only
    /// the light one instead of both.
    private static let legacySeededKey = "didSeedBundledVisualTemplates"
    /// The bundled templates as this device was last given them — see
    /// `refreshBundledTemplates()`.
    private static let asShippedKey = "vis_bundledAsShipped"
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
        // Ids first, so seeding and the refresh below recognise a look this device
        // already has as one of the app's own rather than as a stranger.
        migrateLegacyBundledIDs()
        seedBundledIfNeeded()
        refreshBundledTemplates()
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

    /// What changing the app's appearance should do to the playback look.
    enum AppearanceChange: Equatable {
        /// Switch the playback screen over to the new appearance's standard look
        /// without asking — nothing of the user's is lost by it.
        case apply
        /// The look on screen is held by no template, so switching would throw it away.
        case askReplacingCurrent
        /// A template of the user's own is selected, holding a look of their own.
        /// Switching leaves it, but it stays in the list holding exactly what they
        /// made, so this is the milder question; carries the name to point at in it.
        case askLeavingSelected(name: String)
    }

    /// The question the playback screen has, if any, when the app's appearance changes
    /// from `oldScheme` to `newScheme`.
    ///
    /// The standard look for the new appearance goes on silently wherever the user has
    /// nothing to lose by it. That covers being on one of the app's own two templates —
    /// including one they have made their own, since their edits stay in it and going
    /// back to that appearance is what brings them back — and, with nothing selected,
    /// a look that some template of theirs holds.
    ///
    /// What is left to ask about is a look that exists nowhere but on screen, which
    /// switching really does replace, and a template of the user's own holding
    /// something other than a standard look — which switching only steps away from.
    func appearanceChange(from oldScheme: ColorScheme, to newScheme: ColorScheme) -> AppearanceChange {
        if let selected {
            if Self.isBundled(selected.id) { return .apply }
            // A template of theirs holding nothing but a standard look — the one being
            // switched to, or the one being left — costs no more to switch than the
            // app's own copy of it would.
            let standards = [standard(for: newScheme), standard(for: oldScheme)].compactMap { $0 }
            if standards.contains(where: selected.hasSameValues(as:)) { return .apply }
            return .askLeavingSelected(name: selected.name)
        }
        return templates.contains(where: \.matchesCurrent) ? .apply : .askReplacingCurrent
    }

    /// The saved templates as stored, read when building the profile JSON. The list
    /// is written on every change, so this is what the live store holds.
    static var stored: [VisualTemplate] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([VisualTemplate].self, from: data)
        else { return [] }
        return decoded
    }

    /// Replaces the templates and the selection with a restored profile's, without
    /// applying the selected one: the playback-visual settings are restored from the
    /// same profile alongside this (see `UserSettings.apply`), so they already hold
    /// the selected template's values. A selection naming a template the list ends up
    /// without is dropped, exactly as `init` drops a stale one.
    func restore(_ restored: [VisualTemplate], selectedID: UUID?) {
        templates = restored
        // Carried over before the migration, so a selection naming one of the app's own
        // templates under an id an earlier version shipped it with moves along with it.
        self.selectedID = selectedID
        // The templates the app ships aren't the user's to carry: a profile written by
        // an earlier version knows neither a look this version has started shipping nor
        // the id or name it ships it under, so all three are put back rather than
        // restored — the playback screen has a standard look for each appearance to
        // switch between.
        migrateLegacyBundledIDs()
        addMissingBundledTemplates()
        refreshBundledTemplates()
        persist()
        // Checked against the list as it now stands rather than against the restored
        // one, so a selection naming a bundled template the profile didn't carry — it
        // was written before this version started shipping that one — is kept: the
        // template it names is right there, just put back a line earlier. The id
        // checked is likewise the one the migration may have moved it to.
        self.selectedID = templates.contains { $0.id == self.selectedID } ? self.selectedID : nil
        persistSelection()
    }

    /// The id the look the app ships for `scheme` keeps for good: the identity of its
    /// row in the list, of its entry in the record of what has been seeded, and of a
    /// selection pointing at it.
    ///
    /// It is pinned here rather than read from the bundled file because exporting a
    /// template mints a fresh id (`capturingCurrent` gives every capture its own), so
    /// re-exporting one of these two to update the look it ships used to hand every
    /// device that already had it a second, identically named copy. The id in the file
    /// is ignored; ids it has been shipped under before are folded back into this one
    /// by `migrateLegacyBundledIDs()`.
    static func bundledID(for scheme: ColorScheme) -> UUID {
        scheme == .dark
            ? UUID(uuidString: "28C54FBC-F67E-4664-939A-5A58E1568775")!
            : UUID(uuidString: "7C8FE5CA-4357-4229-96BF-943DBB39CCAE")!
    }

    /// True for the id of one of the two looks the app ships. Ids they went out under
    /// before are folded into these at launch (`migrateLegacyBundledIDs()`), so the
    /// current pair is the whole list.
    static func isBundled(_ id: UUID) -> Bool {
        id == bundledID(for: .dark) || id == bundledID(for: .light)
    }

    /// The ids these two looks went out under before the ids were pinned, oldest first.
    /// A list holding one of them holds an earlier copy of a template the app ships, so
    /// it is folded into the current one rather than left sitting beside it.
    private static let legacyBundledIDs: [(id: UUID, scheme: ColorScheme)] = [
        (UUID(uuidString: "7CDFBFB2-F341-4BBD-A115-B32CA3D0E910")!, .dark),  // "Standard"
        (UUID(uuidString: "496CC35D-8851-45AF-9350-BF13C968F1EA")!, .dark),  // "Custom"
        (UUID(uuidString: "C99A6176-3CDA-4459-8D15-D8942AAE9756")!, .dark),  // "SimplestTemplate"
        (UUID(uuidString: "55FE33D2-ACA5-4330-8826-1EB6579ACE1B")!, .dark),  // "Simplest frfr"
        (UUID(uuidString: "8B0FEFFB-A0C8-448F-8A6A-7552A0542D01")!, .light), // "Simplest - light"
    ]

    /// The standard playback look for an appearance: one of the two templates shipped
    /// in the app bundle. This is the look a fresh install starts on, what Settings ▸
    /// Reset puts the visuals back to, and what changing the app's theme offers to
    /// switch the playback screen over to.
    static func bundledTemplate(for scheme: ColorScheme) -> VisualTemplate? {
        let name = scheme == .dark ? "Simplest - dark" : "Simplest - light"
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              var template = VisualTemplate.decode(from: data)
        else { return nil }
        template.id = bundledID(for: scheme)
        return template
    }

    /// Both shipped looks, dark first — the order they're listed in on the visuals
    /// screen once seeded.
    static var bundledTemplates: [VisualTemplate] {
        [ColorScheme.dark, .light].compactMap { bundledTemplate(for: $0) }
    }

    /// Adds the bundled templates this device hasn't been given yet, and on a fresh
    /// install applies the one matching the appearance the app is in — so the playback
    /// visuals start on that look, without it being selected (see
    /// `applyStandard(for:)`). An install that only gains a newly shipped template keeps
    /// the look it is on; and because the seeding is remembered per template, one the
    /// user deleted isn't put back here. Asking for the standard look
    /// (`applyStandard(for:)`) and resetting the visuals are what bring a deleted one
    /// back.
    private func seedBundledIfNeeded() {
        let defaults = UserDefaults.standard
        var seededIDs = Set(defaults.stringArray(forKey: Self.seededIDsKey) ?? [])
        if seededIDs.isEmpty, defaults.bool(forKey: Self.legacySeededKey) {
            seededIDs.insert(Self.bundledID(for: .dark).uuidString)
        }
        // Nothing seeded at all: this is the first launch.
        let isFreshInstall = seededIDs.isEmpty
        let missing = Self.bundledTemplates.filter { !seededIDs.contains($0.id.uuidString) }
        guard !missing.isEmpty else { return }

        // One the list already holds — put back by a profile restore, which doesn't go
        // through the seeding — is recorded as seeded rather than added a second time.
        let unseeded = missing.filter { bundled in !templates.contains { $0.id == bundled.id } }
        if !unseeded.isEmpty {
            templates.append(contentsOf: unseeded)
            persist()
        }
        defaults.set(seededIDs.union(missing.map(\.id.uuidString)).sorted(), forKey: Self.seededIDsKey)
        // Through the same call the reset and the theme change go through, so the look
        // that lands on screen is the list's own copy of the template in every case.
        if isFreshInstall {
            applyStandard(for: AppTheme.currentScheme)
        }
    }

    /// Folds a copy of one of the app's own templates that this device carries under an
    /// id an earlier version shipped it with into the copy this version knows, so an
    /// install that has been through such a change is left with one row per look
    /// instead of two identically named ones.
    ///
    /// Nothing of the user's is thrown away by this: the legacy row *is* the app's
    /// template, carried across app updates and edited in place while selected, so it
    /// keeps its values under the current id. Only where this version's row is already
    /// there beside it — an install that ran a version which added rather than renamed
    /// — is one of the two dropped, and then it's the one not in use, so the look on
    /// screen stays put either way.
    private func migrateLegacyBundledIDs() {
        let defaults = UserDefaults.standard
        var seededIDs = defaults.stringArray(forKey: Self.seededIDsKey).map(Set.init)
        var seedingChanged = false
        var listChanged = false

        for (legacyID, scheme) in Self.legacyBundledIDs {
            let currentID = Self.bundledID(for: scheme)
            // The record of what has been seeded moves over even when the row itself is
            // long gone, so a look the user deleted isn't handed back as one this
            // device has never been given.
            if var ids = seededIDs, ids.remove(legacyID.uuidString) != nil {
                ids.insert(currentID.uuidString)
                seededIDs = ids
                seedingChanged = true
            }
            guard let legacyIndex = templates.firstIndex(where: { $0.id == legacyID }) else { continue }
            var legacy = templates.remove(at: legacyIndex)
            legacy.id = currentID
            if let currentIndex = templates.firstIndex(where: { $0.id == currentID }) {
                // Keep the one in use; with neither in use the row this version added
                // stays, being the look the app ships now.
                if selectedID == legacyID { templates[currentIndex] = legacy }
            } else {
                templates.insert(legacy, at: legacyIndex)
            }
            if selectedID == legacyID {
                selectedID = currentID
                persistSelection()
            }
            listChanged = true
        }

        if listChanged { persist() }
        if seedingChanged, let seededIDs {
            defaults.set(seededIDs.sorted(), forKey: Self.seededIDsKey)
        }
    }

    /// Hands over a shipped look this version has changed, and keeps the app's own
    /// templates named the way it ships them.
    ///
    /// A copy still holding exactly what the app last gave this device hasn't been
    /// touched, so it is replaced with what is shipped now — that is how improving one
    /// of the two looks reaches installs sitting on it. A copy that differs is the
    /// user's: a bundled template is what a fresh install starts on and what every edit
    /// on the visuals screen is then saved into, so an app update must not paint over
    /// it. Only the name follows there, so a list that gained one under an earlier name
    /// still shows the name the rest of the app — including the translations — knows it
    /// by. Templates the user saved or imported have neither a bundled id nor a shipped
    /// copy, and are never touched.
    private func refreshBundledTemplates() {
        let shipped = Self.bundledTemplates
        var asShipped: [UUID: VisualTemplate] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.asShippedKey),
           let decoded = try? JSONDecoder().decode([VisualTemplate].self, from: data) {
            asShipped = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        var changed = false
        for template in shipped {
            guard let index = templates.firstIndex(where: { $0.id == template.id }),
                  templates[index] != template else { continue }
            if templates[index] == asShipped[template.id] {
                templates[index] = template
            } else if templates[index].name != template.name {
                templates[index].name = template.name
            } else {
                continue
            }
            changed = true
        }
        if changed { persist() }

        // Record what this version ships, so the next one can tell an untouched copy
        // apart again. Written only when it has actually changed: every write is one
        // more change for the profile upload to look at.
        if let data = try? JSONEncoder().encode(shipped),
           data != UserDefaults.standard.data(forKey: Self.asShippedKey) {
            UserDefaults.standard.set(data, forKey: Self.asShippedKey)
        }
    }

    /// Puts back the bundled templates the list doesn't hold, for a list that didn't
    /// come from this device — see `restore(_:selectedID:)`. Unlike seeding, this
    /// ignores what has been seeded here before; on this device deleting one is what
    /// takes it out of the list, and that goes through `remove(atOffsets:)`.
    private func addMissingBundledTemplates() {
        for bundled in Self.bundledTemplates where !templates.contains(where: { $0.id == bundled.id }) {
            templates.append(bundled)
        }
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

    /// This device's copy of the standard look for `scheme` — the template
    /// `applyStandard(for:)` puts on screen, carrying whatever the user has made of it —
    /// falling back to the values the app ships where the list no longer holds it.
    func standard(for scheme: ColorScheme) -> VisualTemplate? {
        guard let bundled = Self.bundledTemplate(for: scheme) else { return nil }
        return templates.first { $0.id == bundled.id } ?? bundled
    }

    /// Puts the playback visuals on the standard look for `scheme` — the template the
    /// app ships for that appearance — *without* selecting it.
    ///
    /// The app's own two are only ever applied here, never selected: the first launch,
    /// a theme change and Settings ▸ Reset all put one on screen, and none of them is
    /// the user saying they want their edits saved into it. Selecting one stays
    /// something they do by hand, by tapping its row on the visuals screen; until they
    /// do, the look is simply on screen, belonging to no template.
    ///
    /// What is applied is this device's copy of that template, which is the look the
    /// user last left the appearance on: while they had it selected, edits on the
    /// visuals screen were written into it. `resetToBundled()` is the one caller that
    /// first puts the shipped values back, being the one time that has to undo those
    /// edits.
    ///
    /// A template the user has deleted is put back as the app ships it, so the look now
    /// on screen is one they can find in the list and select. Deleting one still holds
    /// everywhere else — nothing hands it back at launch — it just doesn't outlast the
    /// app asking for the look it holds.
    func applyStandard(for scheme: ColorScheme) {
        guard let bundled = Self.bundledTemplate(for: scheme) else { return }
        if let stored = templates.first(where: { $0.id == bundled.id }) {
            applyWithoutSelecting(stored)
            return
        }
        templates.append(bundled)
        persist()
        applyWithoutSelecting(bundled)
    }

    /// Puts `template`'s look on screen without it becoming the selected one, leaving
    /// the settings belonging to no template — the state a look the user hasn't adopted
    /// is in. Any selection is dropped *before* the values are written: applying changes
    /// UserDefaults, and that change comes back through `syncSelectedWithCurrent()`,
    /// which would otherwise write the new look into the template being left.
    private func applyWithoutSelecting(_ template: VisualTemplate) {
        deselect()
        template.apply()
    }

    /// Settings ▸ Reset ▸ Visuals: the templates list as a fresh install finds it —
    /// the two the app ships, exactly as it ships them, and nothing else.
    ///
    /// So the templates the user saved or imported go, the app's own two come back with
    /// the values they are shipped with however the user had since edited them, and one
    /// they had deleted is there again. Then the standard look for the appearance the
    /// app is in is applied — and, as everywhere the app applies one of its own looks,
    /// left unselected. The theme is reset alongside this, so by now the appearance is
    /// the device's own light/dark setting.
    func resetToBundled() {
        templates = Self.bundledTemplates
        persist()
        // Both are in the list, so both count as handed over — otherwise the next launch
        // would seed a second copy of either.
        UserDefaults.standard.set(templates.map(\.id.uuidString).sorted(), forKey: Self.seededIDsKey)
        applyStandard(for: AppTheme.currentScheme)
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
