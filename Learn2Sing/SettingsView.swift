//
//  SettingsView.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 23.06.26.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore

    @State private var settingsPath: [SettingsRoute] = []

    /// Carries a tapped search result from whichever screen found it to the
    /// screen its row is on. Owned here because this is where the stack the
    /// result travels through lives.
    @StateObject private var search = SettingsSearchCoordinator()

    /// The exercise driving the clap delay test. Built once so the intro and
    /// playback screens share the same instance; it isn't stored in the library.
    private let delayTestExercise = SettingsView.makeDelayTestExercise()

    var body: some View {
        NavigationStack(path: $settingsPath) {
            Form {
                Section {
                    hubLink(L("Profile"), systemImage: "person.crop.circle", route: .profile)
                        .setting(.profile)

                    hubLink(L("Audio"), systemImage: "speaker.wave.2", route: .audio)
                        .setting(.audio)

                    hubLink(L("Visuals"), systemImage: "paintpalette", route: .visualsHub)
                        .setting(.visuals)

                    hubLink(L("Voice"), systemImage: "music.mic", route: .voice)
                        .setting(.voice)

                    hubLink(L("Exercises"), systemImage: "list.bullet", route: .exercises)
                        .setting(.exercises)

                    hubLink(L("Backup"), systemImage: "externaldrive", route: .backup)
                        .setting(.backup)

                    hubLink(L("Reset"), systemImage: "arrow.counterclockwise", route: .reset)
                        .setting(.reset)

                    hubLink(L("Language"), systemImage: "globe", route: .language)
                        .setting(.language)

                    hubLink(L("Request a new Feature/ Report a Bug"),
                            systemImage: "exclamationmark.bubble", route: .feedback)
                        .setting(.feedback)

                    // No chevron: it opens over the whole app rather than pushing
                    // onto this stack, so it isn't one of the rows above.
                    Button { IntroTutorial.shared.present() } label: {
                        Label(L("Tutorial"), systemImage: "graduationcap")
                    }
                    .foregroundStyle(.primary)
                    .setting(.tutorial)
                }
            }
            .navigationTitle(L("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .settingsSearchable(.root)
            .stableTopEdgeFade()
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .audio:
                    AudioSettingsView(
                        openInstruments: { settingsPath.append(SettingsRoute.instruments) },
                        openDelayTest: { settingsPath.append(SettingsRoute.delayChoice) })
                case .instruments:
                    InstrumentsView { settingsPath.append(SettingsRoute.customInstrument($0)) }
                case .customInstrument(let id):
                    CustomInstrumentDetailView(instrument: CustomInstrumentStore.shared.binding(for: id))
                case .delayChoice:
                    DelayTestChoiceView(
                        openClapTest: { settingsPath.append(SettingsRoute.delayIntro) },
                        openSungTest: { settingsPath.append(SettingsRoute.delayExercisePicker) })
                case .delayIntro:
                    // No difficulty: this one is the delay test's stand-in, not
                    // an exercise anyone practises.
                    ExerciseIntroView(exercise: delayTestExercise, showsDifficulty: false) {
                        settingsPath.append(SettingsRoute.delayPlayback)
                    }
                case .delayPlayback:
                    PlaybackView(exercise: delayTestExercise, mode: .clapDelayTest)
                case .delayExercisePicker:
                    DelayTestExercisePickerView {
                        settingsPath.append(SettingsRoute.delayExercisePlayback($0))
                    }
                case .delayExercisePlayback(let id):
                    // The exercise is looked up on the way in rather than carried in
                    // the route, so the run always plays what the library holds now.
                    if let exercise = store.exercises.first(where: { $0.id == id }) {
                        PlaybackView(exercise: exercise, mode: .sungDelayTest,
                                     onDelayTestExit: returnToAudioSettings)
                    }
                case .voice:
                    VoiceSettingsView { settingsPath.append(SettingsRoute.vocalRangeTest) }
                case .vocalRangeTest:
                    VocalRangeTestView { settingsPath = [] }
                case .visualsHub:
                    VisualsHubView(
                        openMenus: { settingsPath.append(SettingsRoute.visualsMenus) },
                        openPlayback: { settingsPath.append(SettingsRoute.visualsPlayback) })
                case .visualsMenus:
                    MenusVisualsView()
                case .visualsPlayback:
                    PlaybackVisualsView()
                case .profile:
                    ProfileView()
                case .exercises:
                    ExercisesSettingsView {
                        settingsPath.append(SettingsRoute.recommendationWhitelist)
                    }
                case .recommendationWhitelist:
                    RecommendationWhitelistView()
                case .backup:
                    BackupSettingsView(
                        openExport: { settingsPath.append(SettingsRoute.backupExport) },
                        openImport: { settingsPath.append(SettingsRoute.backupImport($0)) })
                case .backupExport:
                    ExerciseExportSelectionView()
                case .backupImport(let file):
                    ExerciseImportSelectionView(bundle: file.bundle)
                case .reset:
                    ResetSettingsView(
                        openScores: { settingsPath.append(SettingsRoute.resetScores) },
                        openSettings: { settingsPath.append(SettingsRoute.resetSettings) },
                        openExercises: { settingsPath.append(SettingsRoute.resetExercises) },
                        openHome: { settingsPath.append(SettingsRoute.resetHome) })
                case .resetScores:
                    ScoresResetView()
                case .resetSettings:
                    SettingsResetView()
                case .resetExercises:
                    ExercisesResetView()
                case .resetHome:
                    HomeResetView()
                case .language:
                    LanguageSettingsView()
                case .feedback:
                    FeedbackView()
                }
            }
            // Select the whole number when a numeric field anywhere on this stack is
            // tapped (e.g. the microphone delay on the Audio screen), so typing a new
            // value replaces the old one instead of inserting alongside it. Scoped to
            // numeric fields by keyboard type, matching the repetition fields.
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { notification in
                guard let textField = notification.object as? UITextField else { return }
                let numericKeyboards: [UIKeyboardType] = [.numberPad, .numbersAndPunctuation, .decimalPad]
                guard numericKeyboards.contains(textField.keyboardType) else { return }
                DispatchQueue.main.async {
                    textField.selectedTextRange = textField.textRange(
                        from: textField.beginningOfDocument, to: textField.endOfDocument)
                }
            }
        }
        // Every screen on this stack reads the coordinator from here, which is
        // also what tells them they are inside the Settings tab and may show a
        // search field at all.
        .environment(\.settingsSearch, search)
        // A tapped result: open the screen its row is on, then hand the row over
        // for that screen to scroll to and flash.
        .onChange(of: search.request) { _, request in
            guard let request, let entry = SettingsCatalog.entry(for: request) else { return }
            let path = SettingsRoute.path(to: entry.screen)
            // The search only ever finds rows on the screen it was started on or
            // below it, so the route to one always begins with the screens
            // already on the stack: assigning the whole path leaves those in
            // place and pushes the rest.
            if settingsPath != path { settingsPath = path }
            search.request = nil
            search.pending = request
        }
    }

    /// Back to the Audio screen from the far end of the sung delay test, rather than
    /// to the exercise picker the test happens to have been reached through: the
    /// value it just measured is on that screen, in the microphone-delay field.
    /// Audio is the first thing pushed onto this stack — the test is only reachable
    /// from there — so everything after it goes.
    private func returnToAudioSettings() {
        guard settingsPath.count > 1 else { return }
        settingsPath.removeLast(settingsPath.count - 1)
    }

    /// A row that pushes a settings category screen onto the navigation stack.
    private func hubLink(_ title: String, systemImage: String, route: SettingsRoute) -> some View {
        SettingsHubRow(title: title, systemImage: systemImage) {
            settingsPath.append(route)
        }
    }

    /// Screens pushed onto the Settings navigation stack: the category hubs
    /// (Audio with its instruments screens, Visuals, Voice, Exercises, Backup,
    /// Reset with its four screens, Language, Profile, and the message form) and
    /// the microphone-delay and vocal-range tests they lead to. The delay test
    /// branches in two: the clap test's intro and playback, or the sung test's
    /// exercise picker and the run it starts.
    private enum SettingsRoute: Hashable {
        case audio
        case instruments
        case customInstrument(UUID)
        case delayChoice
        case delayIntro
        case delayPlayback
        case delayExercisePicker
        case delayExercisePlayback(UUID)
        case voice
        case vocalRangeTest
        case visualsHub
        case visualsMenus
        case visualsPlayback
        case profile
        case exercises
        case recommendationWhitelist
        case backup
        case backupExport
        // The file travels in the route rather than in a `@State` beside it: a
        // destination closure reading state set in the same update as the push
        // is built from the value it had *before* that update, and lands empty.
        case backupImport(PendingImportFile)
        case reset
        case resetScores
        case resetSettings
        case resetExercises
        case resetHome
        case language
        case feedback

        /// The pushes that lead from the tab's root to `screen`, which is how a
        /// search result reaches the screen its row is on.
        static func path(to screen: SettingsScreen) -> [SettingsRoute] {
            switch screen {
            case .root:           []
            case .profile:        [.profile]
            case .audio:          [.audio]
            case .instruments:    [.audio, .instruments]
            case .delayChoice:    [.audio, .delayChoice]
            case .visuals:        [.visualsHub]
            case .menus:          [.visualsHub, .visualsMenus]
            case .playback:       [.visualsHub, .visualsPlayback]
            case .voice:          [.voice]
            case .exercises:      [.exercises]
            case .backup:         [.backup]
            case .reset:          [.reset]
            case .resetScores:    [.reset, .resetScores]
            case .resetSettings:  [.reset, .resetSettings]
            case .resetExercises: [.reset, .resetExercises]
            case .resetHome:      [.reset, .resetHome]
            case .language:       [.language]
            case .feedback:       [.feedback]
            }
        }
    }

    /// The throwaway exercise that drives the clap delay test, with the description
    /// shown on its intro screen. Its notes are generated in PlaybackView's clap-test
    /// mode rather than loaded from storage, so it never enters the user's library.
    private static func makeDelayTestExercise() -> Exercise {
        var exercise = Exercise(name: L("Microphone Delay Test"))
        exercise.bpm = 80
        exercise.details = L("""
        This test measures how long it takes your microphone to pick up sound, so \
        the app can line your singing up with the notes when scoring.

        A steady metronome will tick along with short markers labelled “clap”. \
        Clap your hands once on every tick. The first four ticks are just to help \
        you settle into the beat and aren't counted — keep clapping through the \
        rest, sixteen in all.

        When it finishes, the delay between your claps and the ticks is measured \
        and your microphone delay setting is updated automatically.

        For the most accurate result, use headphones so the metronome isn't picked \
        up by the microphone, and clap firmly.
        """)
        return exercise
    }
}

/// A row that pushes another settings screen onto the navigation stack: a label
/// on the leading edge and a chevron on the trailing one. Shared by the Settings
/// hub and the Reset screens so they look identical. The title arrives already
/// translated (via `L(_:)`), since a `Label` built from a plain `String` is shown
/// verbatim.
struct SettingsHubRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
    }
}

/// The "Voice" hub reached from Settings: the user's vocal range, the test that
/// measures it, and how much of a note counts as hit when a run is scored.
struct VoiceSettingsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @AppStorage(VocalRange.storageKey) private var vocalRangeRaw = ""
    @AppStorage(VocalRange.customLowKey)  private var customLow  = VocalRange.customDefault.low
    @AppStorage(VocalRange.customHighKey) private var customHigh = VocalRange.customDefault.high
    @AppStorage(ScoreTargetWindow.storageKey) private var targetWindow = ScoreTargetWindow.defaultPercent

    /// True from the first value a drag moves the target-window slider to until that
    /// drag ends, which is the only time the picture of the note below it is shown:
    /// it is there to explain the number being chosen, not to sit on the screen
    /// afterwards.
    @State private var isAdjustingTargetWindow = false

    /// Bumped on every sign of life from that slider: it starting, it stopping, and
    /// each value it passes through. A drag that is *cancelled* rather than ended
    /// never reports stopping — the press-and-hold help tears the control down
    /// mid-gesture to cancel the touch under its bubble, and a system gesture taking
    /// over does the same — so the picture is also taken away once this has been
    /// still for a moment. See `targetWindowIdleTimeout`.
    @State private var targetWindowActivity = 0

    /// Push the vocal-range test onto the shared Settings navigation stack.
    let openRangeTest: () -> Void

    private var isCustom: Bool { vocalRangeRaw == VocalRange.custom.rawValue }

    var body: some View {
        Form {
            Section {
                Picker("Vocal range", selection: $vocalRangeRaw) {
                    Text("Not set").tag("")
                    ForEach(VocalRange.allCases) { range in
                        Text(L(range.rawValue)).tag(range.rawValue)
                    }
                }
                .setting(.vocalRange)

                if isCustom {
                    Picker("Lowest note", selection: $customLow) {
                        ForEach(loPitch...hiPitch, id: \.self) { pitch in
                            Text(verbatim: pitchName(pitch)).tag(pitch)
                        }
                    }
                    .onChange(of: customLow) { _, newLow in
                        if newLow > customHigh { customHigh = newLow }
                    }
                    .setting(.lowestNote)

                    Picker("Highest note", selection: $customHigh) {
                        ForEach(loPitch...hiPitch, id: \.self) { pitch in
                            Text(verbatim: pitchName(pitch)).tag(pitch)
                        }
                    }
                    .onChange(of: customHigh) { _, newHigh in
                        if newHigh < customLow { customLow = newHigh }
                    }
                    .setting(.highestNote)
                }

                Button(action: openRangeTest) {
                    Label("Test Vocal Range", systemImage: "waveform")
                }
                .setting(.testVocalRange)
            } header: {
                Text("Vocal Range").settingSection(.voiceRange)
            }

            Section {
                HStack {
                    Text("Target window size")
                    Spacer()
                    Text(verbatim: "\(targetWindow)%").foregroundStyle(.secondary)
                }
                .setting(.targetWindow)

                Slider(value: targetWindowBinding,
                       in: Double(ScoreTargetWindow.range.lowerBound)...Double(ScoreTargetWindow.range.upperBound),
                       step: 1,
                       onEditingChanged: { editing in
                           targetWindowActivity += 1
                           // Only the *end* of a drag is believed. A Slider reports
                           // editing beginning again the instant it ends — the same
                           // value, no movement behind it — so a handler that trusts
                           // `true` puts the picture back up the moment the finger
                           // leaves, and, having spent its beginning, the slider has
                           // none left to report when the next drag really does start:
                           // that one would run with no picture at all. What a drag is
                           // under way is told instead by the values it writes, in
                           // `targetWindowBinding`.
                           guard !editing else { return }
                           withAnimation(.easeInOut(duration: 0.2)) {
                               isAdjustingTargetWindow = false
                           }
                       })
                    .settingHelp(targetWindowHelp)
                    // The slider says the same thing as the row above it, but
                    // only that row is what a search result points at.

                if isAdjustingTargetWindow {
                    TargetWindowPreview(percent: targetWindow)
                        .transition(.opacity)
                }
            } header: {
                Text("Score Calculation").settingSection(.voiceScoreCalculation)
            }
        }
        // The safety net the comment on `targetWindowActivity` describes: restarted by
        // every bump, so a drag that is still moving keeps the picture, and one that
        // vanished without a word loses it a moment later.
        .task(id: targetWindowActivity) {
            guard isAdjustingTargetWindow else { return }
            try? await Task.sleep(for: .seconds(targetWindowIdleTimeout))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { isAdjustingTargetWindow = false }
        }
        .onDisappear { isAdjustingTargetWindow = false }
        .navigationTitle(L("Voice"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsSearchable(.voice)
    }

    /// How long the slider may go without a sign of life before the picture is taken
    /// away anyway. Comfortably longer than the pause between two steps of even a very
    /// slow drag, and a finger held stiller than this has already brought the
    /// press-and-hold bubble up over the picture.
    private var targetWindowIdleTimeout: Double { 2 }

    /// The percentage, as the whole number it is stored as, through the `Double` a
    /// slider works in.
    ///
    /// Writing through here is also what puts the picture of the note up. The first
    /// value a drag moves to is the earliest sign of a finger on the slider that can
    /// be trusted — see the slider's `onEditingChanged` for what is wrong with the
    /// obvious one — and only the slider ever writes here, so a value arriving from
    /// somewhere else (a restored profile, a reset) doesn't flash the picture onto a
    /// screen nobody is touching.
    private var targetWindowBinding: Binding<Double> {
        Binding(get: { Double(targetWindow) },
                set: { newValue in
                    let percent = ScoreTargetWindow.clamped(Int(newValue.rounded()))
                    guard percent != targetWindow else { return }
                    targetWindow = percent
                    targetWindowActivity += 1
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isAdjustingTargetWindow = true
                    }
                })
    }

    /// Said the same way on the row and on the slider under it, the way the other
    /// settings screens pair a value with the control that sets it.
    private var targetWindowHelp: String {
        SettingsCatalog.help(for: .targetWindow)
    }
}

/// The picture shown while the target-window slider is being dragged: a note with
/// the middle `percent` of its height in green, which is the part of it the singer
/// has to be inside for it to count. The caption is the same green, so it reads as
/// naming the coloured band rather than the note.
private struct TargetWindowPreview: View {
    /// Re-renders when the language is changed, the same as the screen around it.
    @ObservedObject private var appLanguage = LanguageManager.shared

    let percent: Int

    /// The green the playback screen paints a note in by default, so the band is the
    /// colour the singer already reads as "note" rather than one picked for this
    /// picture. The rest of the note is grey, which is the whole point of the
    /// drawing: at a glance, green counts and grey does not.
    private static let green = Color(hex: VisualDefaults.noteColor)

    /// Tall enough that a 5% band is still a band rather than a hairline, and wide
    /// enough to read as a note rather than as a bar across the row.
    private static let noteHeight: CGFloat = 64
    private static let noteWidth: CGFloat = 220

    /// The same rounding the playback screen gives a note by default.
    private static let cornerRadius = noteHeight * CGFloat(VisualDefaults.noteRoundness) / 2

    var body: some View {
        VStack(spacing: 10) {
            // The note's full height stays the same at every setting: what the slider
            // changes is how much of it is green, which is only legible against the
            // rest of the note still being there. The band is centred by the stack,
            // so it is the note's middle at every size.
            ZStack {
                Rectangle().fill(.secondary.opacity(0.35))
                Rectangle().fill(Self.green)
                    .frame(height: Self.noteHeight * CGFloat(ScoreTargetWindow.fraction(percent: percent)))
            }
            .frame(width: Self.noteWidth, height: Self.noteHeight)
            // Clipped to the note's own shape, so the band doesn't square off its
            // rounded ends at 100%.
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))

            Text(L("The part of the note you have to hit for it to count"))
                .font(.footnote)
                .foregroundStyle(Self.green)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
    }
}

/// The "Exercises" hub reached from Settings: how the exercise library is
/// presented — the shape and size of the Home tab's "Recommended" category and
/// which exercises it may draw from. Also reached from the toolbar of the screen
/// that category's card opens, which is where a suggestion is looked at.
struct ExercisesSettingsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore
    @AppStorage(RecommendedExercises.minutesKey)
    private var practiceMinutes = RecommendedExercises.defaultMinutes
    @AppStorage(RecommendedExercises.asListKey)
    private var recommendationsAsList = RecommendedExercises.defaultAsList

    /// Push the whitelist picker onto the shared Settings navigation stack.
    let openWhitelist: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Show recommendations as list", isOn: $recommendationsAsList)
                    .setting(.recommendationsAsList)

                Stepper(value: $practiceMinutes,
                        in: RecommendedExercises.minutesRange,
                        step: RecommendedExercises.minutesStep) {
                    HStack {
                        Text("Daily practice time")
                        Spacer()
                        Text(RecommendedExercises.formatted(minutes: practiceMinutes,
                                                            locale: appLanguage.language.locale))
                            .foregroundStyle(.secondary)
                    }
                }
                .setting(.dailyPracticeTime)

                Menu {
                    ForEach(ExerciseOrigin.allCases) { origin in
                        Toggle(isOn: store.autoWhitelistBinding(origin)) {
                            Label(origin.label, systemImage: origin.systemImage)
                        }
                    }
                } label: {
                    HStack {
                        Text("Automatically whitelisted exercises")
                        Spacer()
                        Text(verbatim: "\(store.autoWhitelistOrigins.count)/\(ExerciseOrigin.allCases.count)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                .setting(.autoWhitelist)

                Button(action: openWhitelist) {
                    HStack {
                        Text("Whitelisted exercises")
                        Spacer()
                        Text(verbatim: "\(store.recommendationWhitelist.count)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                .setting(.whitelist)
            } header: {
                Text("Recommendations").settingSection(.exercisesRecommendations)
            }
        }
        .navigationTitle(L("Exercises"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsSearchable(.exercises)
    }
}

/// The decoded file an import picker is pushed for. A route has to be Hashable
/// and a bundle isn't, so this is hashed by its identity alone — each chosen file
/// is its own push, whatever it holds.
struct PendingImportFile: Hashable {
    let id = UUID()
    let bundle: ExerciseBundle

    static func == (lhs: PendingImportFile, rhs: PendingImportFile) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The "Backup" hub reached from Settings: exporting the exercise library to a
/// file and importing one back in. Neither happens here — both rows lead to a
/// screen that picks which exercises are involved (see BackupSelectionViews),
/// and this one's job for an import is choosing the file that screen reads.
struct BackupSettingsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    /// Push the export picker onto the shared Settings navigation stack.
    let openExport: () -> Void
    /// Push the import picker for the file that was chosen and decoded.
    let openImport: (PendingImportFile) -> Void

    @State private var isImporting = false
    @State private var alertMessage: String?

    var body: some View {
        Form {
            Section {
                Button(action: openExport) {
                    Label("Export Exercises", systemImage: "square.and.arrow.up")
                }
                .setting(.exportExercises)

                Button {
                    isImporting = true
                } label: {
                    Label("Import Exercises", systemImage: "square.and.arrow.down")
                }
                .setting(.importExercises)
            } header: {
                Text("Exercises").settingSection(.backupExercises)
            }
        }
        .navigationTitle(L("Backup"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsSearchable(.backup)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url),
                      let bundle = try? JSONDecoder().decode(ExerciseBundle.self, from: data)
                else {
                    alertMessage = L("That file could not be imported.")
                    return
                }
                guard !bundle.exercises.isEmpty else {
                    alertMessage = L("That file holds no exercises.")
                    return
                }
                openImport(PendingImportFile(bundle: bundle.deduplicated))
            case .failure(let error):
                alertMessage = L("Import failed: %@", error.localizedDescription)
            }
        }
        .alert("Exercises", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }
}

/// A plain-JSON document wrapper used by the export/import file dialogs.
struct ExerciseDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
