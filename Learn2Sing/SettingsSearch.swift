//
//  SettingsSearch.swift
//  Learn2Sing
//
//  The search field on the Settings tab and every screen under it. A screen
//  searches itself and the screens below it — searching from "Visuals" never
//  turns up something on "Exercises" — which is why the field is labelled after
//  the screen it sits on ("Search Visuals").
//
//  What it searches is `SettingsCatalog`: one entry per settings row, holding
//  the row's title and the press-and-hold explanation it shows. The catalogue is
//  where those explanations live now — a row asks for its own with
//  `.setting(_:)` — so a result and the bubble the user eventually holds down
//  can't drift apart.
//
//  A result never changes anything. Tapping one navigates to the screen the row
//  is on, scrolls it into view and flashes it, exactly as a newly created
//  exercise is pointed out on the Exercises tab (see ExerciseCollectionList's
//  `highlight(_:)`) — the user still makes the change themselves.
//

import SwiftUI
import UIKit
import Combine

// MARK: - Screens

/// A screen of the Settings tab that carries a search field. Screens whose rows
/// are the user's own content rather than settings — the exercise pickers, the
/// detail screen of an uploaded instrument, the tests — are deliberately absent:
/// there is nothing on them to search for.
enum SettingsScreen: String, CaseIterable, Hashable {
    case root
    case profile
    case audio
    case instruments
    case delayChoice
    case visuals
    case menus
    case playback
    case voice
    case exercises
    case backup
    case reset
    case resetScores
    case resetSettings
    case resetExercises
    case resetHome
    case language
    case feedback

    /// The screen this one is pushed from; nil for the tab's own root.
    var parent: SettingsScreen? {
        switch self {
        case .root:                                                  nil
        case .profile, .audio, .visuals, .voice, .exercises,
             .backup, .reset, .language, .feedback:                  .root
        case .instruments, .delayChoice:                             .audio
        case .menus, .playback:                                      .visuals
        case .resetScores, .resetSettings,
             .resetExercises, .resetHome:                            .reset
        }
    }

    /// The screen's navigation title, which is also what its search field is
    /// labelled after. Resolved on each read so a language change reaches it.
    var title: String {
        switch self {
        case .root:           L("Settings")
        case .profile:        L("Profile")
        case .audio:          L("Audio")
        case .instruments:    L("Instruments")
        case .delayChoice:    L("Test for delay")
        case .visuals:        L("Visuals")
        case .menus:          L("Menus")
        case .playback:       L("Playback")
        case .voice:          L("Voice")
        case .exercises:      L("Exercises")
        case .backup:         L("Backup")
        case .reset:          L("Reset")
        case .resetScores:    L("Scores")
        case .resetSettings:  L("Settings")
        case .resetExercises: L("Exercises")
        case .resetHome:      L("Home")
        case .language:       L("Language")
        case .feedback:       L("Request a new Feature/ Report a Bug")
        }
    }

    /// This screen and everything reachable below it: what a search started here
    /// covers.
    var subtree: Set<SettingsScreen> {
        var found: Set<SettingsScreen> = [self]
        // The tree is four levels deep at most, so repeated passes over the
        // cases cost nothing next to keeping a child list by hand.
        var didAdd = true
        while didAdd {
            didAdd = false
            for screen in SettingsScreen.allCases {
                if let parent = screen.parent, found.contains(parent),
                   !found.contains(screen) {
                    found.insert(screen)
                    didAdd = true
                }
            }
        }
        return found
    }

    /// The chain from `origin` down to this screen, both ends included — what a
    /// result is labelled with, so "Size" says which screen and section it is
    /// the size of.
    func trail(from origin: SettingsScreen) -> [SettingsScreen] {
        var chain: [SettingsScreen] = []
        var screen: SettingsScreen? = self
        while let current = screen {
            chain.append(current)
            if current == origin { break }
            screen = current.parent
        }
        return chain.reversed()
    }
}

// MARK: - Keys

/// Names one searchable settings row. A string underneath rather than an enum so
/// the rows that come from a list of something else — the built-in instruments,
/// the reset categories, the languages — can name themselves from it.
struct SettingKey: Hashable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

extension SettingKey {
    // Settings hub
    static let profile        = SettingKey("profile")
    static let audio          = SettingKey("audio")
    static let visuals        = SettingKey("visuals")
    static let voice          = SettingKey("voice")
    static let exercises      = SettingKey("exercises")
    static let backup         = SettingKey("backup")
    static let reset          = SettingKey("reset")
    static let language       = SettingKey("language")
    static let feedback       = SettingKey("feedback")
    static let tutorial       = SettingKey("tutorial")

    // Profile
    static let profilePicture     = SettingKey("profile.picture")
    static let username           = SettingKey("profile.username")
    static let profileDescription = SettingKey("profile.description")
    static let joinDatePublic     = SettingKey("profile.joinDate")

    // Section headings. Only the ones that say something the rows under them
    // don't: a heading that repeats the title of its own row (Profile's
    // "Username", the message form's "E-Mail") would only turn up twice.
    static let audioDevices          = SettingKey("section.audio.devices")
    static let audioScoring          = SettingKey("section.audio.scoring")
    static let instrumentsBuiltIn    = SettingKey("section.instruments.builtIn")
    static let instrumentsCustom     = SettingKey("section.instruments.custom")
    static let delayChooseTest       = SettingKey("section.delay.choose")
    static let visualsOrientation    = SettingKey("section.visuals.orientation")
    static let menusExerciseLists    = SettingKey("section.menus.exerciseLists")
    static let playbackNotes         = SettingKey("section.playback.notes")
    static let playbackZoom          = SettingKey("section.playback.zoom")
    static let playbackBackground    = SettingKey("section.playback.background")
    static let playbackText          = SettingKey("section.playback.text")
    static let playbackSinger        = SettingKey("section.playback.singer")
    static let playbackVerticalLine  = SettingKey("section.playback.verticalLine")
    static let playbackRepetitions   = SettingKey("section.playback.repetitions")
    static let playbackScreen        = SettingKey("section.playback.screen")
    static let playbackTemplates     = SettingKey("section.playback.templates")
    static let voiceRange            = SettingKey("section.voice.range")
    static let voiceScoreCalculation = SettingKey("section.voice.score")
    static let exercisesRecommendations = SettingKey("section.exercises.recommendations")
    static let backupExercises       = SettingKey("section.backup.exercises")
    static let resetRecordedScores   = SettingKey("section.reset.scores")
    static let resetCategories       = SettingKey("section.reset.categories")
    static let resetYourExercises    = SettingKey("section.reset.yourExercises")
    static let resetBundledExercises = SettingKey("section.reset.bundledExercises")
    static let languageAppLanguage   = SettingKey("section.language.app")

    // Audio
    static let instruments     = SettingKey("audio.instruments")
    static let speaker         = SettingKey("audio.speaker")
    static let microphone      = SettingKey("audio.microphone")
    static let microphoneDelay = SettingKey("audio.micDelay")
    static let delayTest       = SettingKey("audio.delayTest")

    /// One of the sounds the app ships with, on the Instruments screen.
    static func instrument(_ instrument: Instrument) -> SettingKey {
        SettingKey("instrument.\(instrument.rawValue)")
    }

    // Delay test
    static let clapTest = SettingKey("delay.clap")
    static let sungTest = SettingKey("delay.sung")

    // Visuals
    static let theme                = SettingKey("visuals.theme")
    static let orientationLock      = SettingKey("visuals.orientation")
    static let menus                = SettingKey("visuals.menus")
    static let playbackVisuals      = SettingKey("visuals.playback")
    static let exercisePreviewColor = SettingKey("menus.previewColor")

    // Playback visuals
    static let noteColor            = SettingKey("playback.noteColor")
    static let playingNoteColor     = SettingKey("playback.playingNoteColor")
    static let noteRoundness        = SettingKey("playback.noteRoundness")
    static let verticalZoom         = SettingKey("playback.verticalZoom")
    static let horizontalZoom       = SettingKey("playback.horizontalZoom")
    static let followVertical       = SettingKey("playback.followVertical")
    static let showLines            = SettingKey("playback.showLines")
    static let backgroundColor      = SettingKey("playback.background")
    static let showKeyboard         = SettingKey("playback.showKeyboard")
    static let showPitches          = SettingKey("playback.showPitches")
    static let autoPitchNameColor   = SettingKey("playback.autoPitchNameColor")
    static let pitchNameColor       = SettingKey("playback.pitchNameColor")
    static let textColor            = SettingKey("playback.textColor")
    static let textFont             = SettingKey("playback.textFont")
    static let singerSize           = SettingKey("playback.singerSize")
    static let singerInnerColor     = SettingKey("playback.singerInner")
    static let singerOuterColor     = SettingKey("playback.singerOuter")
    static let singerLineColor      = SettingKey("playback.singerLine")
    static let playheadColor        = SettingKey("playback.playheadColor")
    static let playheadStyle        = SettingKey("playback.playheadStyle")
    static let hideUnusedDots       = SettingKey("playback.hideUnusedDots")
    static let showRepetitionCounter = SettingKey("playback.showRepetitions")
    static let repetitionPosition   = SettingKey("playback.repetitionPosition")
    static let hideTabBar           = SettingKey("playback.hideTabBar")
    static let saveTemplate         = SettingKey("playback.saveTemplate")
    static let exportTemplate       = SettingKey("playback.exportTemplate")
    static let importTemplate       = SettingKey("playback.importTemplate")

    // Voice
    static let vocalRange     = SettingKey("voice.range")
    static let lowestNote     = SettingKey("voice.lowestNote")
    static let highestNote    = SettingKey("voice.highestNote")
    static let testVocalRange = SettingKey("voice.test")
    static let targetWindow   = SettingKey("voice.targetWindow")

    // Exercises
    static let recommendationsAsList = SettingKey("exercises.asList")
    static let dailyPracticeTime     = SettingKey("exercises.practiceTime")
    static let autoWhitelist         = SettingKey("exercises.autoWhitelist")
    static let whitelist             = SettingKey("exercises.whitelist")

    // Backup
    static let exportExercises = SettingKey("backup.export")
    static let importExercises = SettingKey("backup.import")

    // Reset
    static let resetScoresRow    = SettingKey("reset.scores")
    static let resetSettingsRow  = SettingKey("reset.settings")
    static let resetExercisesRow = SettingKey("reset.exercises")
    static let resetHomeRow      = SettingKey("reset.home")

    static let deleteAllScores = SettingKey("reset.scores.all")

    /// One settings category on the Reset ▸ Settings screen.
    static func resetCategory(_ category: ResettableSettings) -> SettingKey {
        SettingKey("reset.settings.\(category.rawValue)")
    }
    static let resetAllSettings = SettingKey("reset.settings.all")

    static let deleteOwnExercises        = SettingKey("reset.exercises.own")
    static let deleteDownloadedExercises = SettingKey("reset.exercises.downloaded")
    static let revertAllBundled          = SettingKey("reset.exercises.bundled")

    static let clearFavourites     = SettingKey("reset.home.favourites")
    static let deleteRoutines      = SettingKey("reset.home.routines")
    static let clearRecentlyPlayed = SettingKey("reset.home.recent")
    static let clearPracticeTime   = SettingKey("reset.home.practice")

    /// One language on the Language screen.
    static func appLanguage(_ language: AppLanguage) -> SettingKey {
        SettingKey("language.\(language.rawValue)")
    }

    // Feedback
    static let feedbackType     = SettingKey("feedback.type")
    static let feedbackLocation = SettingKey("feedback.location")
    static let feedbackMessage  = SettingKey("feedback.message")
    static let feedbackEmail    = SettingKey("feedback.email")
    static let feedbackSend     = SettingKey("feedback.send")
}

// MARK: - Catalogue

/// One searchable settings row.
struct SettingsSearchEntry: Identifiable {
    let key: SettingKey
    /// The screen the row is on.
    let screen: SettingsScreen
    /// The section it sits in, where the screen has more than one — shown after
    /// the screen in a result's trail, since several titles ("Size", "Colour")
    /// only mean something under their heading. nil on a heading, which *is* a
    /// section.
    let section: String?
    /// What the row is called, as it reads on the screen.
    let title: String
    /// The press-and-hold explanation, which is also searched.
    let help: String
    /// Whether the row is on its screen at all right now: some are hidden by
    /// another setting (a custom vocal range's notes, the playhead's dot
    /// options), and a result must never point at a row that isn't there. Asked
    /// on each search rather than stored, since the setting it depends on can
    /// change while the catalogue is cached.
    let isAvailable: () -> Bool

    var id: SettingKey { key }
}

/// Every searchable settings row, in the order the screens list them.
///
/// Rebuilt when the language changes — the strings are resolved as it is built —
/// and cached in between, since it is read once per row on every settings screen
/// as well as on every keystroke in the search field.
@MainActor
enum SettingsCatalog {
    private static var cachedLanguage: AppLanguage?
    private static var cached: [SettingsSearchEntry] = []
    private static var cachedByKey: [SettingKey: SettingsSearchEntry] = [:]

    static var entries: [SettingsSearchEntry] {
        rebuildIfNeeded()
        return cached
    }

    static func entry(for key: SettingKey) -> SettingsSearchEntry? {
        rebuildIfNeeded()
        return cachedByKey[key]
    }

    /// The press-and-hold text a row shows, which `.setting(_:)` looks up. An
    /// unknown key gives an empty string rather than a crash: a missing bubble
    /// is a far smaller problem than a settings screen that won't open.
    static func help(for key: SettingKey) -> String {
        entry(for: key)?.help ?? ""
    }

    /// The rows `query` finds under `screen`, its own rows included. Rows whose
    /// title matches come before rows only their explanation matches, and each
    /// group keeps the order the screens list them in.
    static func results(for query: String, under screen: SettingsScreen) -> [SettingsSearchEntry] {
        let reachable = screen.subtree
        var byTitle: [SettingsSearchEntry] = []
        var byHelp: [SettingsSearchEntry] = []
        for entry in entries where reachable.contains(entry.screen) && entry.isAvailable() {
            if matches(entry.title, query) {
                byTitle.append(entry)
            } else if matches(entry.help, query) {
                byHelp.append(entry)
            }
        }
        return byTitle + byHelp
    }

    /// Case- and diacritic-insensitive substring match, as everywhere else the
    /// app searches, so "melodie" finds "Melodie" and "mélodie" alike.
    private static func matches(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func rebuildIfNeeded() {
        let language = LanguageManager.shared.language
        guard cachedLanguage != language else { return }
        cachedLanguage = language
        cached = build()
        cachedByKey = Dictionary(uniqueKeysWithValues: cached.map { ($0.key, $0) })
    }

    /// A stored switch's value, for the rows another setting hides.
    private static func flag(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    private static var showsLines: Bool { flag(VisualKeys.showLines, default: VisualDefaults.showLines) }
    private static var showsPitches: Bool { flag(VisualKeys.showPitches, default: VisualDefaults.showPitches) }
    private static var picksPitchNameColor: Bool {
        showsPitches && !flag(VisualKeys.autoPitchNameColor, default: VisualDefaults.autoPitchNameColor)
    }
    private static var playheadIsDots: Bool {
        (UserDefaults.standard.string(forKey: VisualKeys.playheadStyle) ?? VisualDefaults.playheadStyle)
            == PlayheadStyle.dots.rawValue
    }
    private static var countsRepetitions: Bool {
        flag(VisualKeys.showRepetitionCounter, default: VisualDefaults.showRepetitionCounter)
    }
    private static var hasCustomVocalRange: Bool {
        UserDefaults.standard.string(forKey: VocalRange.storageKey) == VocalRange.custom.rawValue
    }

    private static func build() -> [SettingsSearchEntry] {
        var entries: [SettingsSearchEntry] = []

        func add(_ key: SettingKey, _ screen: SettingsScreen, section: String? = nil,
                 title: String, help: String,
                 available: @escaping () -> Bool = { true }) {
            entries.append(SettingsSearchEntry(key: key, screen: screen, section: section,
                                               title: title, help: help, isAvailable: available))
        }

        /// A section heading, listed just before the rows it heads. It carries
        /// no section of its own — it *is* one — so a result names the screen it
        /// is on and nothing more.
        func heading(_ key: SettingKey, _ screen: SettingsScreen, _ title: String,
                     help: String = "") {
            add(key, screen, title: title, help: help)
        }

        // MARK: Settings hub
        add(.profile, .root, title: L("Profile"),
            help: L("Your username, picture and description, as other users see them on the Community tab."))
        add(.audio, .root, title: L("Audio"),
            help: L("Instruments, playback and recording devices, and the microphone delay used for scoring."))
        add(.visuals, .root, title: L("Visuals"),
            help: L("Theme, orientation and the look of the playback screen."))
        add(.voice, .root, title: L("Voice"),
            help: L("Your vocal range, the test that measures it, and how precisely you have to hit a note for it to count."))
        add(.exercises, .root, title: L("Exercises"),
            help: L("How your exercise library is presented, including the Home tab's recommendations."))
        add(.backup, .root, title: L("Backup"),
            help: L("Export your exercise library to a file, or import one."))
        add(.reset, .root, title: L("Reset"),
            help: L("Delete your scores, exercises and Home tab lists, or put your settings back to how the app started out."))
        add(.language, .root, title: L("Language"),
            help: L("The language the app is displayed in. Kept on this device only."))
        add(.feedback, .root, title: L("Request a new Feature/ Report a Bug"),
            help: L("Write to the developer: report something that's broken, ask for a feature, or say what you make of the app."))
        add(.tutorial, .root, title: L("Tutorial"),
            help: L("Play the introduction the app opens with on its first launch again."))

        // MARK: Profile
        add(.profilePicture, .profile, section: L("Profile Picture"), title: L("Profile Picture"),
            help: L("Picks a picture from your photos to show on your public profile."))
        add(.username, .profile, section: L("Username"), title: L("Username"),
            help: L("The name shown beside the exercises you share. No two users can have the same one."))
        add(.profileDescription, .profile, section: L("Profile Description"),
            title: L("Profile Description"),
            help: L("A few words about yourself, shown at the top of your profile in the Community tab."))
        add(.joinDatePublic, .profile, title: L("Make your join date public"),
            help: L("Shows other users how long you have had the app, under your profile description."))

        // MARK: Audio
        let routeHelp = L("“Automatic” uses connected earphones (e.g. AirPods) when available, otherwise the phone.")
        let delayHelp = L("Compensates for the lag between singing and pitch detection. Only the score is affected — playback and visuals are unchanged. Run the test to measure it automatically.")
        add(.instruments, .audio, title: L("Instruments"),
            help: L("Choose the sound that plays the notes, or upload your own."))
        heading(.audioDevices, .audio, L("Devices"))
        add(.speaker, .audio, section: L("Devices"), title: L("Speaker"), help: routeHelp)
        add(.microphone, .audio, section: L("Devices"), title: L("Microphone"), help: routeHelp)
        heading(.audioScoring, .audio, L("Scoring"))
        add(.microphoneDelay, .audio, section: L("Scoring"), title: L("Microphone delay"), help: delayHelp)
        add(.delayTest, .audio, section: L("Scoring"), title: L("Test for delay"), help: delayHelp)

        // MARK: Instruments
        let builtInHelp = L("Tap the name to play the exercises' notes with this sound. The speaker plays a sample of it.")
        heading(.instrumentsBuiltIn, .instruments, L("Built-in"))
        heading(.instrumentsCustom, .instruments, L("Custom"),
                help: L("Upload an MP3 or WAV file containing a single sound. Playback shifts it up and down from its pitch to reach every note. After uploading, set the pitch the recording actually has."))
        for instrument in Instrument.allCases {
            add(.instrument(instrument), .instruments, section: L("Built-in"),
                title: L(instrument.rawValue), help: builtInHelp)
        }

        // MARK: Delay test
        heading(.delayChooseTest, .delayChoice, L("Choose a Test"))
        add(.clapTest, .delayChoice, section: L("Choose a Test"), title: L("Clap Test"),
            help: L("Clap along with a metronome and the app works the delay out for you. Quick, but it needs headphones and firm claps to be accurate."))
        add(.sungTest, .delayChoice, section: L("Choose a Test"), title: L("Sing an Exercise"),
            help: L("Sing one of your own exercises, then slide your recorded singing until it lines up with the notes. Takes longer, but you see exactly what you're setting."))

        // MARK: Visuals
        add(.theme, .visuals, title: L("Theme"),
            help: L("Sets the app's appearance. “System” matches your device's light or dark setting."))
        heading(.visualsOrientation, .visuals, L("Orientation"))
        add(.orientationLock, .visuals, section: L("Orientation"), title: L("Lock orientation"),
            help: L("Keeps the app in the chosen orientation. “Don't lock” lets it rotate with your device."))
        add(.menus, .visuals, title: L("Menus"),
            help: L("Customise how the app's own screens and lists look."))
        add(.playbackVisuals, .visuals, title: L("Playback"),
            help: L("Customise how the note-scrolling playback screen looks."))

        // MARK: Menus
        heading(.menusExerciseLists, .menus, L("Exercise lists"))
        add(.exercisePreviewColor, .menus, section: L("Exercise lists"),
            title: L("Exercise preview colour"),
            help: L("Sets the colour of the small note pattern drawn beside each exercise in the lists."))

        // MARK: Playback visuals
        let repetitionHelp = L("Shows which repetition you're on out of the total, e.g. “2/5”. Hidden for exercises that don't repeat.")
        let templateFileHelp = L("Export saves the current visual settings as a template file you can share. Import loads a template file and applies it.")

        heading(.playbackNotes, .playback, L("Notes"))
        add(.noteColor, .playback, section: L("Notes"), title: L("Note colour"),
            help: L("The colour the notes to sing are drawn in."))
        add(.playingNoteColor, .playback, section: L("Notes"), title: L("Playing note colour"),
            help: L("The colour a note takes on while it is the one being sung."))
        add(.noteRoundness, .playback, section: L("Notes"), title: L("Note roundness"),
            help: L("How rounded the ends of the notes are, from square to fully rounded."))

        heading(.playbackZoom, .playback, L("Zoom & position"))
        add(.verticalZoom, .playback, section: L("Zoom & position"), title: L("Vertical zoom"),
            help: L("How tall a pitch is. Turn it up to spread the notes apart, down to fit more of your range on screen."))
        add(.horizontalZoom, .playback, section: L("Zoom & position"), title: L("Horizontal zoom"),
            help: L("How wide a beat is. Turn it down to see more of what is coming."))
        add(.followVertical, .playback, section: L("Zoom & position"), title: L("Follow notes vertically"),
            help: L("Scrolls the screen up and down so the notes being sung stay in the middle. Off, the whole exercise is shown at once."))

        heading(.playbackBackground, .playback, L("Background"))
        add(.showLines, .playback, section: L("Background"), title: L("Show horizontal lines"),
            help: L("Draws a striped lane for every pitch behind the notes, like piano keys laid on their side."))
        add(.backgroundColor, .playback, section: L("Background"), title: L("Background colour"),
            help: L("The colour behind the notes while the lanes are switched off."),
            available: { !showsLines })
        add(.showKeyboard, .playback, section: L("Background"), title: L("Show keyboard"),
            help: L("Draws a piano keyboard down the left-hand side, so you can see which key each note sits on."))
        add(.showPitches, .playback, section: L("Background"), title: L("Show pitches"),
            help: L("Writes the note names (C4, A3 …) down the left-hand side."))
        add(.autoPitchNameColor, .playback, section: L("Background"),
            title: L("Automatic pitch name colour"),
            help: L("Draws each pitch name in a colour that stands out where it sits: dark on the white keys, light on the black ones, and light over the background while the keyboard is hidden. Turn it off to pick the colour yourself."),
            available: { showsPitches })
        add(.pitchNameColor, .playback, section: L("Background"), title: L("Pitch name colour"),
            help: L("Sets the colour of the pitch names (C4, A3 …) down the left-hand side of the playback screen."),
            available: { picksPitchNameColor })

        heading(.playbackText, .playback, L("Text"))
        add(.textColor, .playback, section: L("Text"), title: L("Text colour"),
            help: L("The colour of the labels written over the notes in the note editor."))
        add(.textFont, .playback, section: L("Text"), title: L("Text font"),
            help: L("The typeface those labels are written in."))

        heading(.playbackSinger, .playback, L("Singing indicator"))
        add(.singerSize, .playback, section: L("Singing indicator"), title: L("Size"),
            help: L("How big the dot that follows your voice is."))
        add(.singerInnerColor, .playback, section: L("Singing indicator"), title: L("Inner colour"),
            help: L("The fill of the dot that follows your voice."))
        add(.singerOuterColor, .playback, section: L("Singing indicator"), title: L("Outer colour"),
            help: L("The ring around that dot."))
        add(.singerLineColor, .playback, section: L("Singing indicator"), title: L("Line colour"),
            help: L("The trail the dot leaves behind it, showing the pitch you have just sung."))

        heading(.playbackVerticalLine, .playback, L("Vertical line"))
        add(.playheadColor, .playback, section: L("Vertical line"), title: L("Colour"),
            help: L("Sets the colour of the vertical line the singing indicator runs along."))
        add(.playheadStyle, .playback, section: L("Vertical line"), title: L("Style"),
            help: L("“Line” draws one continuous line. “Dots” replaces it with a dot in the middle of every pitch."))
        add(.hideUnusedDots, .playback, section: L("Vertical line"),
            title: L("Hide dots in unused pitches"),
            help: L("Leaves a dot only on the pitches the repetition you're singing uses. The dots change to the next repetition's pitches as soon as its last note has finished."),
            available: { playheadIsDots })

        heading(.playbackRepetitions, .playback, L("Repetitions"))
        add(.showRepetitionCounter, .playback, section: L("Repetitions"),
            title: L("Show repetition counter"), help: repetitionHelp)
        add(.repetitionPosition, .playback, section: L("Repetitions"), title: L("Position"),
            help: repetitionHelp, available: { countsRepetitions })

        heading(.playbackScreen, .playback, L("Screen"))
        add(.hideTabBar, .playback, section: L("Screen"), title: L("Hide tab bar"),
            help: L("Hides the Home, Exercises, Community and Settings tabs at the bottom of the screen while an exercise plays."))

        heading(.playbackTemplates, .playback, L("Templates"))
        add(.saveTemplate, .playback, section: L("Templates"), title: L("Save current as template"),
            help: L("Tap a template to switch to it, or tap the selected one to deselect it. While a template is selected, the settings on this screen are saved into it as you change them."))
        add(.exportTemplate, .playback, title: L("Export template"), help: templateFileHelp)
        add(.importTemplate, .playback, title: L("Import template"), help: templateFileHelp)

        // MARK: Voice
        let customNotesHelp = L("The lowest and highest notes you can comfortably sing. Exercises are transposed to fit between them.")
        heading(.voiceRange, .voice, L("Vocal Range"))
        add(.vocalRange, .voice, section: L("Vocal Range"), title: L("Vocal range"),
            help: L("Choose your voice type, or pick “Custom” to enter your own lowest and highest notes. The test below can fill this in for you."))
        add(.lowestNote, .voice, section: L("Vocal Range"), title: L("Lowest note"),
            help: customNotesHelp, available: { hasCustomVocalRange })
        add(.highestNote, .voice, section: L("Vocal Range"), title: L("Highest note"),
            help: customNotesHelp, available: { hasCustomVocalRange })
        add(.testVocalRange, .voice, section: L("Vocal Range"), title: L("Test Vocal Range"),
            help: L("Sing your lowest and highest notes and the app sets them as your custom vocal range above."))
        heading(.voiceScoreCalculation, .voice, L("Score Calculation"))
        add(.targetWindow, .voice, section: L("Score Calculation"), title: L("Target window size"),
            help: L("How much of a note counts as hit when your score is worked out. At 100% the whole note counts, as it always has; lower, and only that share of the note's middle does, so you have to sing nearer the centre of the pitch for it to count."))

        // MARK: Exercises
        heading(.exercisesRecommendations, .exercises, L("Recommendations"))
        add(.recommendationsAsList, .exercises, section: L("Recommendations"),
            title: L("Show recommendations as list"),
            help: L("Lists the recommended exercises in the Home tab's “Recommended” category, one row each. Off, the category shows a single card instead, which plays them all as one queue."))
        add(.dailyPracticeTime, .exercises, section: L("Recommendations"),
            title: L("Daily practice time"),
            help: L("How long you mean to practise a day. The Home tab's “Recommended” category suggests exercises adding up to at least this long — favouring the whitelisted ones you haven't practised in the longest, pitched at your skill level — and a day of the Home tab's “Time Spent Singing” is filled in and ticked once you have practised this much."))
        add(.autoWhitelist, .exercises, section: L("Recommendations"),
            title: L("Automatically whitelisted exercises"),
            help: L("Which exercises are whitelisted for you: switching a group on whitelists everything in it, including what was already in your library, and switching it off takes them out again. Exercises you tick or untick yourself below are left as you left them."))
        add(.whitelist, .exercises, section: L("Recommendations"), title: L("Whitelisted exercises"),
            help: L("The exercises recommendations are picked from. The groups picked above are ticked for you; tap an exercise to add or remove it yourself, which the groups then leave alone."))

        // MARK: Backup
        heading(.backupExercises, .backup, L("Exercises"))
        add(.exportExercises, .backup, section: L("Exercises"), title: L("Export Exercises"),
            help: L("Pick the exercises to save, then send the file, copy it, or save it to Files."))
        add(.importExercises, .backup, section: L("Exercises"), title: L("Import Exercises"),
            help: L("Choose a file, then pick which of its exercises to add to your library or update."))

        // MARK: Reset
        add(.resetScoresRow, .reset, title: L("Scores"),
            help: L("Delete the scores recorded for a single exercise, or wipe them all."))
        add(.resetSettingsRow, .reset, title: L("Settings"),
            help: L("Put a single settings category — or every one of them — back to how the app started out."))
        add(.resetExercisesRow, .reset, title: L("Exercises"),
            help: L("Delete the exercises you made or downloaded, and undo your changes to the ones that came with the app."))
        add(.resetHomeRow, .reset, title: L("Home"),
            help: L("Clear the Home tab's favourites, routines and recently played list."))

        heading(.resetRecordedScores, .resetScores, L("Recorded scores"))
        add(.deleteAllScores, .resetScores, title: L("Delete All Scores"),
            help: L("Deletes the scores of every exercise, including any left behind by exercises you have since deleted. The exercises themselves are kept."))

        heading(.resetCategories, .resetSettings, L("Categories"))
        for category in ResettableSettings.allCases {
            add(.resetCategory(category), .resetSettings, section: L("Categories"),
                title: category.title, help: category.help)
        }
        add(.resetAllSettings, .resetSettings, title: L("Reset All Settings"),
            help: L("Puts every category above back at once. Your exercises, scores and routines are untouched."))

        heading(.resetYourExercises, .resetExercises, L("Your exercises"))
        add(.deleteOwnExercises, .resetExercises, section: L("Your exercises"),
            title: L("Delete Own Exercises"),
            help: L("Deletes every exercise you created yourself, with its MIDI pattern and scores. Exercises that came with the app or from the Community tab are kept."))
        add(.deleteDownloadedExercises, .resetExercises, section: L("Your exercises"),
            title: L("Delete Downloaded Exercises"),
            help: L("Deletes every exercise you downloaded from the Community tab, with its MIDI pattern and scores. Your own exercises and the ones that came with the app are kept."))
        heading(.resetBundledExercises, .resetExercises, L("Bundled Exercises"))
        add(.revertAllBundled, .resetExercises, section: L("Bundled Exercises"),
            title: L("Revert All Bundled Exercises"),
            help: L("Puts every exercise that came with the app back to how it shipped, bringing back any you deleted."))

        add(.clearFavourites, .resetHome, title: L("Clear Favourites"),
            help: L("Empties the Home tab's “Favourites” list. The exercises in it are kept."))
        add(.deleteRoutines, .resetHome, title: L("Delete Routines"),
            help: L("Deletes every routine you assembled. The exercises they were made of are kept."))
        add(.clearRecentlyPlayed, .resetHome, title: L("Clear Recently Played"),
            help: L("Forgets what you played and when, emptying the Home tab's “Recent” list and the order “Recommended” picks by."))
        add(.clearPracticeTime, .resetHome, title: L("Clear Practice Time"),
            help: L("Forgets how long you practised on each day, emptying the Home tab's “Time Spent Singing”."))

        // MARK: Language
        // Both names are searched, so the list answers to "German" as readily as
        // to "Deutsch" whichever language the app is currently in.
        heading(.languageAppLanguage, .language, L("App Language"))
        for language in AppLanguage.allCases {
            add(.appLanguage(language), .language, section: L("App Language"),
                title: language.nativeName, help: language.englishName)
        }

        // MARK: Feedback
        add(.feedbackType, .feedback, title: L("Type"),
            help: L("What the message is: something that's broken, something you'd like added, what you make of the app, or something you'd like to know."))
        add(.feedbackLocation, .feedback, title: L("Where in the app"),
            help: L("Optional. The tab your message is about, so it's clear where to look."))
        add(.feedbackMessage, .feedback, title: L("Message"),
            help: L("What you would like to say. The more exactly you describe it, the more can be done about it."))
        add(.feedbackEmail, .feedback, title: L("E-Mail"),
            help: L("Optional, and only needed if you'd like an answer. Left blank, your message is still read."))
        add(.feedbackSend, .feedback, title: L("Send"),
            help: L("Sends your message straight to the developer. It stays greyed out until the type and the message are filled in."))

        return entries
    }
}

// MARK: - Coordinator

/// Carries a tapped result from the search field to the screen the row is on:
/// `request` is what the results list sets, `SettingsView` turns it into the
/// pushes that get there, and `pending` is what the arriving screen scrolls to.
/// `flashing` is the row being tinted right now, which every row watches for
/// itself.
@MainActor
final class SettingsSearchCoordinator: ObservableObject {
    /// A result the user tapped, until `SettingsView` has navigated to it.
    @Published var request: SettingKey?
    /// The row the screen that just opened should scroll to.
    @Published var pending: SettingKey?
    /// The row being tinted, from when the tint starts until it has faded out.
    /// The fade itself is `SettingFlash`'s to run.
    @Published var flashing: SettingKey?

    /// Scroll `key` into view and flash it, once the screen it is on is up.
    /// The waits mirror the Exercises tab's `highlight(_:)`: one for the push to
    /// land, one for the scroll to finish, so the user sees both happen.
    func reveal(_ key: SettingKey, using proxy: ScrollViewProxy) {
        pending = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.4))
            withAnimation { proxy.scrollTo(key, anchor: .center) }
            try? await Task.sleep(for: .seconds(0.4))
            flashing = key
            // Held until the tint has faded all the way back out, so taking it
            // away is never something the user sees.
            try? await Task.sleep(for: .seconds(SettingFlashTiming.total))
            guard flashing == key else { return }
            flashing = nil
        }
    }
}

private struct SettingsSearchCoordinatorKey: EnvironmentKey {
    static let defaultValue: SettingsSearchCoordinator? = nil
}

/// The row being flashed, handed down to the rows themselves. A plain value
/// rather than the coordinator, so a settings screen opened from somewhere other
/// than the Settings tab (the Exercises settings are also reached from the Home
/// tab) simply never flashes anything.
private struct SettingsFlashKey: EnvironmentKey {
    static let defaultValue: SettingKey? = nil
}

extension EnvironmentValues {
    var settingsSearch: SettingsSearchCoordinator? {
        get { self[SettingsSearchCoordinatorKey.self] }
        set { self[SettingsSearchCoordinatorKey.self] = newValue }
    }

    fileprivate var settingsFlash: SettingKey? {
        get { self[SettingsFlashKey.self] }
        set { self[SettingsFlashKey.self] = newValue }
    }
}

// MARK: - The mark a result leaves

/// The shape of the wash a search result leaves on the row or heading it points
/// at, taken from the one the Exercises tab gives a newly created exercise (see
/// `ExerciseCollectionList.flash(at:)`) so the two look alike.
enum SettingFlashTiming {
    static let fadeIn: Double = 0.25
    /// When the wash starts going again, measured from the moment it appeared.
    static let fadeOutStart: Double = 1.2
    static let fadeOut: Double = 0.4
    /// How long the mark has to stay switched on for all of that to happen, plus
    /// a moment so taking it away is never something the user sees.
    static var total: Double { fadeOutStart + fadeOut + 0.1 }
}

// MARK: - Rows and headings

extension View {
    /// A settings row the search can find. Shows the catalogue's explanation on
    /// a press and hold — the same text the search matched — and marks the row so
    /// a result can scroll to it and flash it.
    func setting(_ key: SettingKey) -> some View {
        settingHelp(SettingsCatalog.help(for: key)).settingAnchor(key)
    }

    /// The mark on its own, for a row whose press-and-hold help is attached to
    /// something inside it (the profile picture's buttons) or is written out on
    /// screen instead (the e-mail field's note).
    func settingAnchor(_ key: SettingKey) -> some View {
        modifier(SettingAnchor(key: key))
    }

    /// A section heading the search can find. Marks it so a result can scroll to
    /// it and wash it in the accent colour, the way a row is pointed out, and
    /// shows the catalogue's explanation on a press and hold where the heading
    /// has one.
    func settingSection(_ key: SettingKey) -> some View {
        modifier(SettingSectionAnchor(key: key))
    }
}

private struct SettingAnchor: ViewModifier {
    let key: SettingKey
    @Environment(\.settingsFlash) private var flash

    func body(content: Content) -> some View {
        content
            // Zero-sized, and only there to reach the list cell the row is drawn
            // in; see `SettingFlash`.
            .background(SettingFlash(isFlashing: flash == key).frame(width: 0, height: 0))
            .id(key)
    }
}

/// The heading equivalent of `SettingAnchor`. A heading is not a list row, so
/// there is no cell background to tint: the wash is drawn behind the words
/// themselves, which is also what the user is looking for after searching for a
/// heading by name. Ordinary view content, so the fade animates from here rather
/// than from UIKit.
private struct SettingSectionAnchor: ViewModifier {
    let key: SettingKey
    @Environment(\.settingsFlash) private var flash

    /// How far the wash has faded in. Run on a timer of its own, because it has
    /// to hold at full for a moment before it goes again.
    @State private var wash: Double = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        // Constant for a given heading, so the branch costs the content no
        // identity: only the "Custom" instruments heading has help of its own.
        let help = SettingsCatalog.help(for: key)
        if help.isEmpty {
            marked(content)
        } else {
            marked(content.settingHelp(help))
        }
    }

    private func marked(_ view: some View) -> some View {
        view
            // The wash reaches a little past the words on every side; the
            // padding is then taken back, so the heading sits where it did.
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.3))
                    .opacity(wash)
            }
            .padding(.horizontal, -8)
            .padding(.vertical, -4)
            .id(key)
            .task(id: flash == key) {
                guard flash == key else {
                    wash = 0
                    return
                }
                withAnimation(.easeInOut(duration: SettingFlashTiming.fadeIn)) { wash = 1 }
                try? await Task.sleep(for: .seconds(SettingFlashTiming.fadeOutStart))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: SettingFlashTiming.fadeOut)) { wash = 0 }
            }
    }
}

/// Tints the row it sits in and fades the tint back out, to point out the
/// setting a search result named.
///
/// It reaches down to the list cell and animates the cell's own background,
/// which is exactly what the Exercises tab does to point out a newly created
/// exercise (see `ExerciseCollectionList.flash(at:)`) — and the only way to
/// animate a row's background from here at all: a background handed to a
/// SwiftUI list row is drawn once, from the colour it has at that moment, and
/// never redrawn.
private struct SettingFlash: UIViewRepresentable {
    let isFlashing: Bool

    func makeUIView(context: Context) -> FlashView { FlashView() }

    func updateUIView(_ view: FlashView, context: Context) {
        if isFlashing { view.flash() }
    }

    final class FlashView: UIView {
        /// So the repeated updates SwiftUI makes while the tint is on screen
        /// don't start it again from the top.
        private var isFlashing = false

        /// Tint the cell in the accent colour and fade back out. Through the
        /// cell's background configuration rather than a view of our own, so the
        /// tint picks up the inset-grouped rounded corners on a section's first
        /// and last row.
        func flash() {
            guard !isFlashing, let cell = enclosingCell else { return }
            isFlashing = true
            let base = (cell as? UICollectionViewListCell)?.defaultBackgroundConfiguration()
                ?? UIBackgroundConfiguration.listCell()
            var tinted = base
            tinted.backgroundColor = UIColor.tintColor.withAlphaComponent(0.3)
            // The cell would otherwise recompute its background from its state
            // at any moment and drop the tint mid-fade.
            cell.automaticallyUpdatesBackgroundConfiguration = false
            UIView.animate(withDuration: SettingFlashTiming.fadeIn) {
                cell.backgroundConfiguration = tinted
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + SettingFlashTiming.fadeOutStart
            ) { [weak self, weak cell] in
                guard let cell else { return }
                UIView.animate(withDuration: SettingFlashTiming.fadeOut) {
                    cell.backgroundConfiguration = base
                } completion: { _ in
                    // Hand the background back to the cell, so selection and
                    // highlight states drive it again.
                    cell.automaticallyUpdatesBackgroundConfiguration = true
                    cell.setNeedsUpdateConfiguration()
                    self?.isFlashing = false
                }
            }
        }

        /// The list cell this view was planted in, found by walking up from it.
        private var enclosingCell: UICollectionViewCell? {
            var view: UIView? = self
            while let current = view {
                if let cell = current as? UICollectionViewCell { return cell }
                view = current.superview
            }
            return nil
        }
    }
}

// MARK: - The search field

extension View {
    /// Puts a search field over this settings screen, covering it and every
    /// screen below it. Does nothing outside the Settings tab, where there is no
    /// navigation stack for a result to travel through.
    func settingsSearchable(_ screen: SettingsScreen) -> some View {
        modifier(SettingsSearchableModifier(screen: screen))
    }
}

private struct SettingsSearchableModifier: ViewModifier {
    let screen: SettingsScreen
    @Environment(\.settingsSearch) private var coordinator

    func body(content: Content) -> some View {
        if let coordinator {
            SettingsSearchContainer(screen: screen, coordinator: coordinator) { content }
        } else {
            content
        }
    }
}

private struct SettingsSearchContainer<Content: View>: View {
    /// Re-renders when the language is changed, so the field's label and the
    /// results follow it like the screen behind them.
    @ObservedObject private var appLanguage = LanguageManager.shared

    let screen: SettingsScreen
    @ObservedObject var coordinator: SettingsSearchCoordinator
    @ViewBuilder let content: () -> Content

    @State private var searchText = ""

    /// `searchText` without surrounding whitespace; empty means "not searching".
    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if query.isEmpty {
                    content()
                } else {
                    SettingsSearchResults(
                        results: SettingsCatalog.results(for: query, under: screen),
                        query: query,
                        origin: screen,
                        onSelect: { key in
                            searchText = ""
                            coordinator.request = key
                        })
                }
            }
            .environment(\.settingsFlash, coordinator.flashing)
            // `initial` because the push that opens this screen happens before it
            // is built: the row to point out is already waiting by the time the
            // screen can watch for it.
            .onChange(of: coordinator.pending, initial: true) { _, pending in
                guard let pending,
                      SettingsCatalog.entry(for: pending)?.screen == screen else { return }
                coordinator.reveal(pending, using: proxy)
            }
        }
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: L("Search %@", screen.title))
        // Swiping down over the keyboard puts it away, as everywhere else.
        .scrollDismissesKeyboard(.interactively)
        .background(SearchFieldHider())
    }
}

/// The list a search shows in place of the screen. Nothing here can be changed:
/// a row says where its setting lives and takes the user there, which is the
/// whole point of finding it.
private struct SettingsSearchResults: View {
    /// Re-renders this list when the language is changed, like every screen.
    @ObservedObject private var appLanguage = LanguageManager.shared

    let results: [SettingsSearchEntry]
    let query: String
    /// The screen the search was started on, which the trail is measured from.
    let origin: SettingsScreen
    let onSelect: (SettingKey) -> Void

    @Environment(\.dismissSearch) private var dismissSearch

    var body: some View {
        if results.isEmpty {
            // In a scroll view of its own — filling it, so it still reads as
            // centred — because swiping down over the keyboard needs something
            // scrollable to travel with. The Exercises tab's empty state is
            // built the same way.
            GeometryReader { geo in
                ScrollView {
                    ContentUnavailableView.search(text: query)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        } else {
            List(results) { entry in
                Button {
                    dismissSearch()
                    onSelect(entry.key)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            Text(trail(to: entry))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                .settingHelp(L("Takes you to the screen this setting is on and points it out. Nothing is changed from here."))
            }
        }
    }

    /// Where the row is, read from the screen the search was started on: the
    /// screens down to it, then the section it sits in.
    private func trail(to entry: SettingsSearchEntry) -> String {
        var parts = entry.screen.trail(from: origin).map(\.title)
        if let section = entry.section, section != parts.last {
            parts.append(section)
        }
        return parts.joined(separator: " › ")
    }
}

// MARK: - Hiding the field until the list is pulled down

/// Scrolls the screen down by the height of its search field once, so the field
/// starts out of sight and is revealed by pulling the list down — the behaviour
/// the Exercises tab's list has (see `ExerciseCollectionList.hideSearchBarIfNeeded`,
/// which does the same thing to its collection view directly).
private struct SearchFieldHider: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private var hasHidden = false
        /// When to give up. SwiftUI installs the search controller and sizes the
        /// form after this view appears, and how long that takes varies — a
        /// budget in runloop turns can be spent before either exists, so the
        /// retries are given a stretch of time instead.
        private var deadline: Date?

        override func viewDidLoad() {
            super.viewDidLoad()
            // Nothing is drawn here and nothing is tapped here: it sits behind
            // the screen's own list and must never take a touch from it.
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard deadline == nil else { return }
            deadline = Date().addingTimeInterval(3)
            attempt()
        }

        private func attempt() {
            guard !hasHidden, let deadline, Date() < deadline else { return }
            if !hideSearchField() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 / 60) { [weak self] in
                    self?.attempt()
                }
            }
        }

        /// True once it has actually scrolled, so the retries stop.
        private func hideSearchField() -> Bool {
            // The search controller sits on the navigation item of the SwiftUI
            // hosting controller, one of this controller's ancestors.
            var searchBar: UISearchBar?
            var ancestor: UIViewController? = self
            while let controller = ancestor, searchBar == nil {
                searchBar = controller.navigationItem.searchController?.searchBar
                ancestor = controller.parent
            }
            guard let searchBar, searchBar.bounds.height > 0,
                  let scrollView = screenScrollView(),
                  scrollView.bounds.height > 0, scrollView.contentSize.height > 0
            else { return false }
            hasHidden = true
            // Never past the end: a short screen has nothing to scroll, and the
            // field simply stays visible (as it would in Mail).
            let insets = scrollView.adjustedContentInset
            let maxOffset = max(-insets.top,
                                scrollView.contentSize.height + insets.bottom - scrollView.bounds.height)
            scrollView.contentOffset.y = min(scrollView.contentOffset.y + searchBar.bounds.height,
                                             maxOffset)
            return true
        }

        /// The screen's own scrolling list. This controller's view is a
        /// zero-sized background behind it, so the search starts at the top of
        /// the screen's view hierarchy and comes back down.
        private func screenScrollView() -> UIScrollView? {
            guard let root = parent?.view ?? view.superview else { return nil }
            var queue = [root]
            while !queue.isEmpty {
                let next = queue.removeFirst()
                if let scrollView = next as? UIScrollView, scrollView.contentSize.height > 0 {
                    return scrollView
                }
                queue.append(contentsOf: next.subviews)
            }
            return nil
        }
    }
}
