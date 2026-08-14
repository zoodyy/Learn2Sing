import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Combine

/// App-wide appearance choice. "System" follows the device's light/dark setting.
enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case light  = "Light"
    case dark   = "Dark"

    var id: String { rawValue }

    static let storageKey = "appTheme"

    /// The `colorScheme` to force, or `nil` to follow the system (device) setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// The appearance this theme actually puts the app in — itself, or the device's own
    /// setting while following the system. Unlike `colorScheme`, this always names one
    /// of light and dark, which is what the parts of the app that keep a look per
    /// appearance (the playback visuals) need.
    var scheme: ColorScheme { colorScheme ?? AppTheme.deviceScheme }

    /// The theme as stored, defaulting to following the system exactly as the picker does.
    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    /// The appearance the app is in right now.
    static var currentScheme: ColorScheme { current.scheme }

    /// The device's own light/dark setting. Read from the screen rather than from the
    /// SwiftUI environment, because the in-app theme override changes the whole window's
    /// environment colour scheme — the device's setting has to show through that. Before
    /// a scene is connected, which is where the template store reads this at launch, the
    /// trait collection at hand answers instead.
    static var deviceScheme: ColorScheme {
        let style = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.traitCollection.userInterfaceStyle
            ?? UITraitCollection.current.userInterfaceStyle
        return style == .dark ? .dark : .light
    }
}

/// The "Visuals" hub reached from Settings. Holds the app-wide theme and
/// orientation choices and an entry to the Playback-visuals screen; it's a screen
/// of its own so further visual areas can be added.
struct VisualsHubView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(OrientationLock.storageKey) private var orientationLockRaw = OrientationLock.none.rawValue

    /// The playback screen has a standard look per appearance, so the theme choice
    /// carries it along — see `handleThemeChange(from:to:)`.
    @EnvironmentObject private var templates: VisualTemplateStore

    /// Set when a theme change should also switch the playback screen over but the user
    /// has customised its look — drives the "switch or keep?" alert.
    @State private var pendingPlaybackScheme: ColorScheme?

    /// Push the menus-visuals screen onto the shared Settings navigation stack.
    let openMenus: () -> Void

    /// Push the playback-visuals screen onto the shared Settings navigation stack.
    let openPlayback: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(L(theme.rawValue)).tag(theme.rawValue)
                    }
                }
                .onChange(of: themeRaw) { oldTheme, newTheme in
                    handleThemeChange(from: oldTheme, to: newTheme)
                }
                .settingHelp(L("Sets the app's appearance. “System” matches your device's light or dark setting."))
            }

            Section {
                Picker("Lock orientation", selection: $orientationLockRaw) {
                    ForEach(OrientationLock.allCases) { lock in
                        Text(L(lock.rawValue)).tag(lock.rawValue)
                    }
                }
                .onChange(of: orientationLockRaw) { _, newValue in
                    OrientationLockManager.apply(OrientationLock(rawValue: newValue) ?? .none)
                }
                .settingHelp(L("Keeps the app in the chosen orientation. “Don't lock” lets it rotate with your device."))
            } header: {
                Text("Orientation")
            }

            // One section, so "Menus" sits directly above "Playback" with no gap.
            Section {
                Button(action: openMenus) {
                    HStack {
                        Label("Menus", systemImage: "list.bullet.rectangle")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                .settingHelp(L("Customise how the app's own screens and lists look."))

                Button(action: openPlayback) {
                    HStack {
                        Label("Playback", systemImage: "play.rectangle")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                .settingHelp(L("Customise how the note-scrolling playback screen looks."))
            }
        }
        .navigationTitle(L("Visuals"))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Playback screen", isPresented: Binding(
            get: { pendingPlaybackScheme != nil },
            set: { if !$0 { pendingPlaybackScheme = nil } }
        )) {
            Button("Switch") {
                if let scheme = pendingPlaybackScheme {
                    templates.selectStandard(for: scheme)
                }
                pendingPlaybackScheme = nil
            }
            Button("Keep current", role: .cancel) {
                pendingPlaybackScheme = nil
            }
        } message: {
            // One whole sentence per appearance rather than the adjective on its own,
            // which not every language can slot into a sentence unchanged.
            Text(pendingPlaybackScheme == .dark
                 ? L("Do you also want to switch the playback screen to the standard dark look? Your customisations will be replaced.")
                 : L("Do you also want to switch the playback screen to the standard light look? Your customisations will be replaced."))
        }
    }

    /// When the theme change actually changes the appearance the app is in: switch an
    /// uncustomised playback screen over to the new appearance's standard look silently,
    /// or ask first when the user has made that look their own.
    private func handleThemeChange(from oldTheme: String, to newTheme: String) {
        let newScheme = (AppTheme(rawValue: newTheme) ?? .system).scheme
        guard (AppTheme(rawValue: oldTheme) ?? .system).scheme != newScheme else { return }

        if templates.currentSettingsAreStandard {
            templates.selectStandard(for: newScheme)
        } else {
            pendingPlaybackScheme = newScheme
        }
    }
}

/// Customises the look of the app's menus — the lists and screens outside of
/// playback. Reached from the Visuals hub.
struct MenusVisualsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @AppStorage(MenuVisualKeys.exercisePreviewColor)
    private var exercisePreviewColor = MenuVisualDefaults.exercisePreviewColor

    var body: some View {
        Form {
            Section {
                ColorPicker("Exercise preview colour",
                            selection: Binding(get: { Color(hex: exercisePreviewColor) },
                                               set: { exercisePreviewColor = $0.hexString }),
                            supportsOpacity: false)
                .settingHelp(L("Sets the colour of the small note pattern drawn beside each exercise in the lists."))
            } header: {
                Text("Exercise lists")
            }
        }
        .navigationTitle(L("Menus"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Customises the look of the playback screen. A live preview at the top — a small
/// square cut-out of the real playback rendering — updates as the controls below
/// are changed, so the effect of each setting is immediately visible.
struct PlaybackVisualsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @AppStorage(VisualKeys.noteColor)        private var noteColor        = VisualDefaults.noteColor
    @AppStorage(VisualKeys.playingNoteColor) private var playingNoteColor = VisualDefaults.playingNoteColor
    @AppStorage(VisualKeys.noteRoundness)  private var noteRoundness  = VisualDefaults.noteRoundness
    @AppStorage(VisualKeys.verticalZoom)   private var verticalZoom   = VisualDefaults.verticalZoom
    @AppStorage(VisualKeys.horizontalZoom) private var horizontalZoom = VisualDefaults.horizontalZoom
    @AppStorage(VisualKeys.followVertical) private var followVertical = VisualDefaults.followVertical
    @AppStorage(VisualKeys.showLines)      private var showLines      = VisualDefaults.showLines
    @AppStorage(VisualKeys.background)     private var background      = VisualDefaults.background
    @AppStorage(VisualKeys.showKeyboard)   private var showKeyboard   = VisualDefaults.showKeyboard
    @AppStorage(VisualKeys.showPitches)    private var showPitches     = VisualDefaults.showPitches
    @AppStorage(VisualKeys.autoPitchNameColor) private var autoPitchNameColor = VisualDefaults.autoPitchNameColor
    @AppStorage(VisualKeys.pitchNameColor)     private var pitchNameColor     = VisualDefaults.pitchNameColor
    @AppStorage(VisualKeys.textColor)      private var textColor      = VisualDefaults.textColor
    @AppStorage(VisualKeys.textFont)       private var textFont       = VisualDefaults.textFont
    @AppStorage(VisualKeys.singerSize)       private var singerSize       = VisualDefaults.singerSize
    @AppStorage(VisualKeys.singerInnerColor) private var singerInnerColor = VisualDefaults.singerInnerColor
    @AppStorage(VisualKeys.singerOuterColor) private var singerOuterColor = VisualDefaults.singerOuterColor
    @AppStorage(VisualKeys.singerLineColor)  private var singerLineColor  = VisualDefaults.singerLineColor
    @AppStorage(VisualKeys.playheadColor)  private var playheadColor  = VisualDefaults.playheadColor
    @AppStorage(VisualKeys.playheadStyle)  private var playheadStyle  = VisualDefaults.playheadStyle
    @AppStorage(VisualKeys.hideUnusedDots) private var hideUnusedDots = VisualDefaults.hideUnusedDots
    @AppStorage(VisualKeys.showRepetitionCounter)     private var showRepetitionCounter     = VisualDefaults.showRepetitionCounter
    @AppStorage(VisualKeys.repetitionCounterPosition) private var repetitionCounterPosition = VisualDefaults.repetitionCounterPosition
    @AppStorage(VisualKeys.hideTabBar)     private var hideTabBar     = VisualDefaults.hideTabBar

    /// Saved named templates the user can switch between. Created at app launch and
    /// injected, so the bundled default is seeded before any playback.
    @EnvironmentObject private var templates: VisualTemplateStore

    /// Naming alert for "Save current as template".
    @State private var isNamingTemplate = false
    @State private var newTemplateName = ""

    /// A template the user tapped while the settings on screen weren't saved in any
    /// template. Non-nil while the warning alert is up; the template is only applied
    /// once the user confirms (or after they've saved the current look first).
    @State private var templateToSelect: VisualTemplate?

    /// Set when the user answered that warning with "Save current as template": the
    /// template to select once the new one has been named and saved.
    @State private var selectAfterSaving: VisualTemplate?

    /// Share-sheet / file-dialog state for export & import of a single template.
    @State private var exportDocument: ExerciseDocument?
    @State private var exportFilename = "Visual Template"
    @State private var isExportingTemplate = false
    @State private var isImportingTemplate = false
    @State private var templateAlert: String?

    /// Anchors the preview's scrolling clock so the demo notes start at beat 0 when
    /// the screen appears (rather than at the huge absolute timeline value).
    @State private var start = Date()

    /// The settings as currently chosen, rebuilt each render so the preview tracks
    /// every edit live.
    private var settings: VisualSettings {
        VisualSettings(
            noteColor: Color(hex: noteColor),
            playingNoteColor: Color(hex: playingNoteColor),
            noteRoundness: noteRoundness,
            verticalZoom: verticalZoom,
            horizontalZoom: horizontalZoom,
            followNotesVertically: followVertical,
            showHorizontalLines: showLines,
            backgroundColor: Color(hex: background),
            showKeyboard: showKeyboard,
            showPitches: showPitches,
            autoPitchNameColor: autoPitchNameColor,
            pitchNameColor: Color(hex: pitchNameColor),
            textColor: Color(hex: textColor),
            textFont: PlaybackFont(rawValue: textFont) ?? .system,
            singerSize: singerSize,
            singerInnerColor: Color(hex: singerInnerColor),
            singerOuterColor: Color(hex: singerOuterColor),
            singerLineColor: Color(hex: singerLineColor),
            playheadColor: Color(hex: playheadColor),
            playheadStyle: PlayheadStyle(rawValue: playheadStyle) ?? .line,
            hideUnusedDots: hideUnusedDots,
            showRepetitionCounter: showRepetitionCounter,
            repetitionCounterPosition: RepetitionCounterPosition(rawValue: repetitionCounterPosition) ?? .bottomRight)
    }

    // Demo content. A short three-note motif repeated many times so the preview can
    // scroll for a long while without running out. The notes sit well above the
    // default centre so "follow notes vertically" visibly recentres them.
    private static let demoPattern: [(pitch: Int, beat: Double)] = [(60, 0), (64, 1), (67, 2)]
    /// One repetition of the motif, in beats — the fourth beat is the gap before the
    /// next one. Passed to the renderer so "hide dots in unused pitches" can preview.
    private static let demoRepeatSpan: Double = 4
    private static let demoRepeatCount = 200
    private static let demoRepeatLayout = RepeatLayout(span: demoRepeatSpan, count: demoRepeatCount)
    private let demoNotes: [MIDINote] = {
        var ns: [MIDINote] = []
        for k in 0..<PlaybackVisualsView.demoRepeatCount {
            for note in PlaybackVisualsView.demoPattern {
                ns.append(MIDINote(pitch: note.pitch, beat: Double(k) * demoRepeatSpan + note.beat, length: 0.9))
            }
        }
        return ns
    }()
    private static let demoTextPitch = 70
    private let demoTexts: [MIDIText] = (0..<200).map {
        MIDIText(text: "La", pitch: PlaybackVisualsView.demoTextPitch, beat: Double($0) * 4 + 0.15)
    }
    /// Midpoint of the demo notes, used as the centre when following vertically.
    private let demoCenter = Double(60 + 67) / 2

    /// Highest / lowest pitch any demo element (note or text) is drawn at. The
    /// collapsed preview crops down to this band plus a one-row margin either side.
    private static let demoTopPitch = max(demoTextPitch, demoPattern.map(\.pitch).max() ?? demoTextPitch)
    private static let demoLowestPitch = min(demoTextPitch, demoPattern.map(\.pitch).min() ?? demoTextPitch)

    /// Layout of the pinned preview above the form.
    private static let previewSidePadding: CGFloat = 20
    private static let previewVerticalPadding: CGFloat = 6

    /// How far the form below the preview is scrolled (0 at rest, grows downward).
    /// Drives the collapsing crop of the pinned preview.
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let previewWidth = max(0, geo.size.width - 2 * Self.previewSidePadding)
            settingsForm
                .contentMargins(.top, previewWidth + 2 * Self.previewVerticalPadding)
                .onScrollGeometryChange(for: CGFloat.self) { scroll in
                    scroll.contentOffset.y + scroll.contentInsets.top
                } action: { _, offset in
                    scrollOffset = offset
                }
                .overlay(alignment: .top) {
                    collapsiblePreview(width: previewWidth, fullHeight: previewWidth)
                }
        }
        .navigationTitle(L("Playback"))
        .navigationBarTitleDisplayMode(.inline)
        // Every change to a control on this screen goes through UserDefaults, so one
        // observer is enough to keep the selected template up to date with all of them.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            templates.syncSelectedWithCurrent()
        }
        .alert("New Template", isPresented: $isNamingTemplate) {
            TextField("Name", text: $newTemplateName)
            Button("Save") { saveCurrentAsTemplate() }
            Button("Cancel", role: .cancel) { selectAfterSaving = nil }
        } message: {
            Text("Save the current visual settings as a template.")
        }
        .alert("Replace current settings?", isPresented: Binding(
            get: { templateToSelect != nil },
            set: { if !$0 { templateToSelect = nil } }
        ), presenting: templateToSelect) { template in
            Button("Save current as template") {
                selectAfterSaving = template
                newTemplateName = ""
                // Next runloop turn, so this alert is gone before the naming one is
                // asked for — SwiftUI drops a second alert presented in the same one.
                DispatchQueue.main.async { isNamingTemplate = true }
            }
            Button("Select anyway", role: .destructive) { templates.select(template) }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Your current visual settings aren’t saved in any template. Selecting this one replaces them.")
        }
        .fileExporter(
            isPresented: $isExportingTemplate,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                templateAlert = L("Export failed: %@", error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $isImportingTemplate,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url),
                      let template = VisualTemplate.decode(from: data) else {
                    templateAlert = L("That file isn’t a valid visual template.")
                    return
                }
                templates.select(templates.add(imported: template))
            case .failure(let error):
                templateAlert = L("Import failed: %@", error.localizedDescription)
            }
        }
        .alert("Templates", isPresented: Binding(
            get: { templateAlert != nil },
            set: { if !$0 { templateAlert = nil } }
        )) {
            Button("OK", role: .cancel) { templateAlert = nil }
        } message: {
            Text(templateAlert ?? "")
        }
    }

    private var settingsForm: some View {
        Form {
            Section("Notes") {
                ColorPicker("Note colour", selection: colorBinding($noteColor), supportsOpacity: false)
                ColorPicker("Playing note colour", selection: colorBinding($playingNoteColor), supportsOpacity: false)
                sliderRow(L("Note roundness"), value: $noteRoundness, range: 0...1)
            }

            Section("Zoom & position") {
                sliderRow(L("Vertical zoom"), value: $verticalZoom, range: 0.5...3)
                sliderRow(L("Horizontal zoom"), value: $horizontalZoom, range: 0.4...3)
                Toggle("Follow notes vertically", isOn: $followVertical)
            }

            Section("Background") {
                Toggle("Show horizontal lines", isOn: $showLines)
                if !showLines {
                    ColorPicker("Background colour", selection: colorBinding($background), supportsOpacity: false)
                }
                Toggle("Show keyboard", isOn: $showKeyboard)
                Toggle("Show pitches", isOn: $showPitches)
                if showPitches {
                    Toggle("Automatic pitch name colour", isOn: $autoPitchNameColor)
                        .settingHelp(L("Draws each pitch name in a colour that stands out where it sits: dark on the white keys, light on the black ones, and light over the background while the keyboard is hidden. Turn it off to pick the colour yourself."))
                    if !autoPitchNameColor {
                        ColorPicker("Pitch name colour",
                                    selection: opacityColorBinding($pitchNameColor),
                                    supportsOpacity: true)
                        .settingHelp(L("Sets the colour of the pitch names (C4, A3 …) down the left-hand side of the playback screen."))
                    }
                }
            }

            Section("Text") {
                ColorPicker("Text colour", selection: colorBinding($textColor), supportsOpacity: false)
                Picker("Text font", selection: $textFont) {
                    ForEach(PlaybackFont.allCases) { font in
                        Text(L(font.rawValue)).tag(font.rawValue)
                    }
                }
            }

            Section("Singing indicator") {
                sliderRow(L("Size"), value: $singerSize, range: 0.5...3)
                ColorPicker("Inner colour", selection: opacityColorBinding($singerInnerColor), supportsOpacity: true)
                ColorPicker("Outer colour", selection: opacityColorBinding($singerOuterColor), supportsOpacity: true)
                ColorPicker("Line colour", selection: opacityColorBinding($singerLineColor), supportsOpacity: true)
            }

            Section {
                ColorPicker("Colour", selection: opacityColorBinding($playheadColor), supportsOpacity: true)
                    .settingHelp(L("Sets the colour of the vertical line the singing indicator runs along."))
                Picker("Style", selection: $playheadStyle) {
                    ForEach(PlayheadStyle.allCases) { style in
                        Text(L(style.rawValue)).tag(style.rawValue)
                    }
                }
                .settingHelp(L("“Line” draws one continuous line. “Dots” replaces it with a dot in the middle of every pitch."))
                if playheadStyle == PlayheadStyle.dots.rawValue {
                    Toggle("Hide dots in unused pitches", isOn: $hideUnusedDots)
                        .settingHelp(L("Leaves a dot only on the pitches the repetition you're singing uses. The dots change to the next repetition's pitches as soon as its last note has finished."))
                }
            } header: {
                Text("Vertical line")
            }

            Section {
                Toggle("Show repetition counter", isOn: $showRepetitionCounter)
                    .settingHelp(L("Shows which repetition you're on out of the total, e.g. “2/5”. Hidden for exercises that don't repeat."))
                if showRepetitionCounter {
                    Picker("Position", selection: $repetitionCounterPosition) {
                        ForEach(RepetitionCounterPosition.allCases) { position in
                            Text(L(position.rawValue)).tag(position.rawValue)
                        }
                    }
                    .settingHelp(L("Shows which repetition you're on out of the total, e.g. “2/5”. Hidden for exercises that don't repeat."))
                }
            } header: {
                Text("Repetitions")
            }

            Section {
                Toggle("Hide tab bar", isOn: $hideTabBar)
                    .settingHelp(L("Hides the Home, Exercises, Community and Settings tabs at the bottom of the screen while an exercise plays."))
            } header: {
                Text("Screen")
            }

            templatesSection

            Section {
                Button {
                    exportCurrentTemplate()
                } label: {
                    Label("Export template", systemImage: "square.and.arrow.up")
                }
                .settingHelp(L("Export saves the current visual settings as a template file you can share. Import loads a template file and applies it."))

                Button {
                    isImportingTemplate = true
                } label: {
                    Label("Import template", systemImage: "square.and.arrow.down")
                }
                .settingHelp(L("Export saves the current visual settings as a template file you can share. Import loads a template file and applies it."))
            }
        }
    }

    // MARK: - Templates

    private var templatesSection: some View {
        Section {
            ForEach(templates.templates) { template in
                let isSelected = templates.selectedID == template.id
                Button {
                    tap(template)
                } label: {
                    HStack {
                        Text(VisualTemplateName.localized(template.name))
                            .foregroundStyle(.primary)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                }
                // The checkmark is the only thing marking the selected row, and it
                // carries no label of its own, so state the selection outright.
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
            .onDelete { templates.remove(atOffsets: $0) }

            Button {
                selectAfterSaving = nil
                newTemplateName = ""
                isNamingTemplate = true
            } label: {
                Label("Save current as template", systemImage: "plus")
            }
            .settingHelp(L("Tap a template to switch to it, or tap the selected one to deselect it. While a template is selected, the settings on this screen are saved into it as you change them."))
        } header: {
            Text("Templates")
        }
    }

    /// A tap on a template row: deselects it if it's the selected one, otherwise
    /// switches to it — first warning if that would throw away settings the user has
    /// changed without saving them anywhere.
    private func tap(_ template: VisualTemplate) {
        if templates.selectedID == template.id {
            templates.deselect()
        } else if templates.currentSettingsAreSaved {
            templates.select(template)
        } else {
            templateToSelect = template
        }
    }

    /// Captures the current settings under the entered name and stores them, selecting
    /// the new template so further edits keep going into it. When the naming came from
    /// the "replace current settings?" warning, the template that was tapped is
    /// selected once the current look is safely saved.
    private func saveCurrentAsTemplate() {
        let pending = selectAfterSaving
        selectAfterSaving = nil
        let name = newTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        templates.add(.capturingCurrent(name: name))
        if let pending { templates.select(pending) }
    }

    /// Prepares a JSON document of the current settings and presents the share dialog.
    private func exportCurrentTemplate() {
        let name = templates.selected?.name ?? "Custom"
        var template = VisualTemplate.capturingCurrent(name: name)
        // Exporting the selected template exports *it*, id and all, rather than a
        // like-for-like copy under a new id. Importing gives it a fresh id anyway (see
        // `add(imported:)`), so this costs nothing there — while a look the app ships,
        // re-exported to update the file it ships, keeps the identity every install
        // already knows it by.
        if let selected = templates.selected { template.id = selected.id }
        guard let data = template.jsonData() else {
            templateAlert = L("Could not prepare the template file.")
            return
        }
        exportFilename = name
        exportDocument = ExerciseDocument(data: data)
        isExportingTemplate = true
    }

    // MARK: - Preview

    /// The preview, pinned above the scrolling form. While the form scrolls, the
    /// preview doesn't move away; it collapses instead, cropping empty canvas from
    /// the top and bottom (never rescaling the drawing) until only the band of demo
    /// notes/text plus a one-row margin on each side remains.
    private func collapsiblePreview(width: CGFloat, fullHeight: CGFloat) -> some View {
        // Mirror the Canvas maths so the crop bounds line up with the drawn rows.
        let rowH = fullHeight / CGFloat(hiPitch - loPitch + 1) * CGFloat(verticalZoom)
        let centerPitch = followVertical ? demoCenter : Double(hiPitch + loPitch) / 2
        func y(_ pitch: Double) -> CGFloat {
            fullHeight / 2 - CGFloat(pitch - centerPitch) * rowH
        }
        // Top edge of the row one above the highest demo element and bottom edge of
        // the row one below the lowest, clamped for zooms that push the band off
        // the canvas.
        let bandTop = min(max(0, y(Double(Self.demoTopPitch) + 1.5)), fullHeight)
        let bandBottom = min(max(bandTop, y(Double(Self.demoLowestPitch) - 1.5)), fullHeight)
        let minHeight = max(bandBottom - bandTop, 44)
        let visibleHeight = min(fullHeight, max(minHeight, fullHeight - max(0, scrollOffset)))

        // Split the cropped-away amount between top and bottom in proportion to the
        // empty space on each side, so both margins reach one row simultaneously.
        let cropped = fullHeight - visibleHeight
        let slackAbove = bandTop
        let slackBelow = fullHeight - bandBottom
        let totalSlack = slackAbove + slackBelow
        let topCrop = totalSlack > 0 ? cropped * slackAbove / totalSlack : 0

        return previewCanvas(topCrop: topCrop, bottomCrop: cropped - topCrop)
            .frame(width: width, height: fullHeight)
            .offset(y: -topCrop)
            .frame(width: width, height: visibleHeight, alignment: .top)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15)))
            .padding(.horizontal, Self.previewSidePadding)
            .padding(.vertical, Self.previewVerticalPadding)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
    }

    /// The demo singer's pitch at a given beat: a gentle bob around the demo notes.
    /// Expressed as a function of the beat (rather than of the current frame) so the
    /// same curve can be replayed backwards to draw the trail behind the indicator.
    private func demoSingerPitch(at beat: Double) -> Double {
        demoCenter + 2.5 * sin(beat * 1.6)
    }

    /// `topCrop` / `bottomCrop` are how much of the full-height canvas the collapsing
    /// preview hides above and below; they're passed through as the scene's safe-area
    /// insets so the repetition badge stays inside the visible strip while the form
    /// scrolls, instead of being cropped away with the empty canvas.
    private func previewCanvas(topCrop: CGFloat, bottomCrop: CGFloat) -> some View {
        TimelineView(.animation) { timeline in
            let beat = timeline.date.timeIntervalSince(start) * 0.7   // slow scroll
            Canvas { ctx, size in
                let baseRowH = size.height / CGFloat(hiPitch - loPitch + 1)
                let rowH = baseRowH * CGFloat(settings.verticalZoom)
                let beatPx = playbackBeatWidth * CGFloat(settings.horizontalZoom)
                let pW: CGFloat = settings.showKeyboard ? playbackKeyboardWidth : 0
                let center = settings.followNotesVertically
                    ? demoCenter
                    : Double(hiPitch + loPitch) / 2
                let layout = SceneLayout(size: size, pianoW: pW, rowH: rowH, beatPx: beatPx,
                                         playheadX: size.width / 3, centerPitch: center)
                // A gently bobbing dot so the singer indicator is visible too.
                let singer = demoSingerPitch(at: beat)

                // The same curve sampled backwards from the playhead to the left edge
                // of the note area, so the indicator drags its pitch history behind it
                // just as it does during real playback. Sampled every couple of points
                // of width, and clamped to the canvas the same way the live view does.
                let trailSpan = max(0, layout.playheadX - pW)
                let steps = max(2, Int(trailSpan / 2))
                let trailBeats = Double(trailSpan / beatPx)
                let dotR = min(rowH * 0.85, 11)
                var trailPath = Path()
                for i in 0...steps {
                    let sampleBeat = beat - trailBeats * (1 - Double(i) / Double(steps))
                    let y = min(max(layout.y(demoSingerPitch(at: sampleBeat)), dotR),
                                size.height - dotR)
                    let pt = CGPoint(x: layout.x(sampleBeat, beat: beat), y: y)
                    if i == 0 { trailPath.move(to: pt) } else { trailPath.addLine(to: pt) }
                }

                // Cycle a demo counter (1/4 … 4/4) so the badge previews live.
                let demoTotal = 4
                let demoCurrent = min(demoTotal, Int(beat / 4) % demoTotal + 1)
                drawPlaybackScene(ctx: ctx, layout: layout, beat: beat,
                                  notes: demoNotes, texts: demoTexts,
                                  trailPath: trailPath, singerPitch: singer, settings: settings,
                                  repetition: (current: demoCurrent, total: demoTotal),
                                  safeTop: topCrop, safeBottom: bottomCrop,
                                  repeatLayout: Self.demoRepeatLayout)
            }
        }
    }

    // MARK: - Helpers

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Slider(value: value, in: range)
        }
    }

    /// Bridges a hex-string @AppStorage value to the `Color` a ColorPicker expects.
    private func colorBinding(_ raw: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(hex: raw.wrappedValue) },
                set: { raw.wrappedValue = $0.hexString })
    }

    /// Like `colorBinding`, but preserves the picked opacity (stored as "#RRGGBBAA")
    /// for colours where transparency is meaningful.
    private func opacityColorBinding(_ raw: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(hex: raw.wrappedValue) },
                set: { raw.wrappedValue = $0.hexStringWithAlpha })
    }
}
