//
//  UserSettings.swift
//  Learn2Sing
//
//  The settings the profile JSON carries, so they survive a reinstall the same
//  way the exercise library and the Home tab's lists already do.
//

import Foundation

/// Every setting that rides along in the profile ProfileSync uploads: the Audio,
/// Visuals, Voice and Exercises categories of the Settings tab, plus the two
/// preferences kept outside it — the categories hidden from the Home tab and the
/// Community tab's sort order. Each one is read from, and written back to, the
/// very UserDefaults key its settings screen binds to with @AppStorage, so a
/// restored setting is indistinguishable from one picked on the device.
///
/// Three things are deliberately absent. The app's language belongs to the device
/// it was chosen on (Settings says as much on its row), so it is never carried.
/// The instruments the user uploaded are audio files in the documents directory
/// rather than settings, and a selection pointing at one is skipped on restore for
/// the same reason. And the visual templates' *contents* do come along, but the
/// scores, exercises and Home lists stay where they are — `UserProfile` carries
/// those itself.
///
/// Every field is optional, so a profile written before a setting existed still
/// decodes and `apply(store:templates:)` simply leaves that setting alone.
struct UserSettings: Codable {

    // MARK: Audio

    /// Playback output and recording input, as the device names the pickers store
    /// (including the "Automatic" / built-in sentinels).
    var speaker: String?
    var microphone: String?
    /// Microphone-delay compensation in milliseconds, as measured by the delay test.
    var microphoneDelayMs: Double?
    /// The selected instrument's raw value. A `custom:` selection names an uploaded
    /// sound, which the profile can't carry — see `apply(store:templates:)`.
    var instrument: String?

    // MARK: Visuals

    var theme: String?
    var orientationLock: String?
    /// The Menus visual settings; one colour so far, hence no nested type.
    var exercisePreviewColor: String?
    /// The playback-visual settings as they are right now. A `VisualTemplate` is
    /// exactly this set of values — that is what a template *is* — so it doubles as
    /// their transport here and re-applying them is already written.
    var playbackVisuals: VisualTemplate?
    /// The templates the user saved, and which of them is selected (a UUID string,
    /// nil when the settings on screen belong to no template). They come along so a
    /// restored device doesn't have the look restored above written back into the
    /// template it happens to have selected.
    var visualTemplates: [VisualTemplate]?
    var selectedVisualTemplate: String?

    // MARK: Voice

    /// The chosen voice type's raw value, "" when the user hasn't set one.
    var vocalRange: String?
    /// The custom range's lowest and highest MIDI notes, used when the range above
    /// is "Custom".
    var vocalRangeCustomLow: Int?
    var vocalRangeCustomHigh: Int?

    // MARK: Exercises

    /// How many exercises the Home tab's "Recommended" category shows.
    var recommendedExercisesAmount: Int?
    /// Whether that category lists them or shows its single card instead.
    var recommendationsAsList: Bool?
    /// The exercises recommendations are picked from.
    var recommendationWhitelist: [UUID]?

    // MARK: Home

    /// The Home tab's hidden categories. Its category *order* is carried by
    /// `UserProfile.homeCategoryOrder`, which predates this type.
    var hiddenHomeCategories: [String]?

    // MARK: Community

    /// The Community tab's sort order and its reverse switch.
    var communitySort: String?
    var communitySortReversed: Bool?

    /// The id given to the unnamed template `playbackVisuals` carries the live
    /// settings as. Fixed rather than freshly generated so two captures of an
    /// unchanged look encode identically — otherwise every upload would look like
    /// a change.
    private static let playbackVisualsID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Reads every setting as it currently stands. Values are resolved through the
    /// same defaults the settings screens show, so a setting the user never touched
    /// is captured as what they see rather than as a missing value.
    static func capturingCurrent(store: ExerciseStore) -> UserSettings {
        let d = UserDefaults.standard
        var visuals = VisualTemplate.capturingCurrent(name: "")
        visuals.id = playbackVisualsID
        let custom = VocalRange.customRange
        return UserSettings(
            speaker: d.string(forKey: AudioRouteManager.speakerKey) ?? AudioRouteManager.automatic,
            microphone: d.string(forKey: AudioRouteManager.micKey) ?? AudioRouteManager.builtInMic,
            microphoneDelayMs: d.double(forKey: microphoneDelayKey),
            instrument: d.string(forKey: Instrument.storageKey) ?? Instrument.piano.rawValue,
            theme: d.string(forKey: AppTheme.storageKey) ?? AppTheme.system.rawValue,
            orientationLock: d.string(forKey: OrientationLock.storageKey) ?? OrientationLock.none.rawValue,
            exercisePreviewColor: d.string(forKey: MenuVisualKeys.exercisePreviewColor)
                ?? MenuVisualDefaults.exercisePreviewColor,
            playbackVisuals: visuals,
            visualTemplates: VisualTemplateStore.stored,
            selectedVisualTemplate: d.string(forKey: VisualTemplateStore.selectionKey),
            vocalRange: d.string(forKey: VocalRange.storageKey) ?? "",
            vocalRangeCustomLow: custom.low,
            vocalRangeCustomHigh: custom.high,
            recommendedExercisesAmount: d.object(forKey: RecommendedExercises.amountKey) == nil
                ? RecommendedExercises.defaultAmount
                : d.integer(forKey: RecommendedExercises.amountKey),
            recommendationsAsList: d.object(forKey: RecommendedExercises.asListKey) == nil
                ? RecommendedExercises.defaultAsList
                : d.bool(forKey: RecommendedExercises.asListKey),
            // Sorted so an unchanged whitelist encodes the same way twice: the
            // whitelist itself is a set, which has no order to preserve.
            recommendationWhitelist: store.recommendationWhitelist.sorted { $0.uuidString < $1.uuidString },
            hiddenHomeCategories: HomeCategories.hidden.sorted(),
            communitySort: d.string(forKey: CommunityFeed.sortKey) ?? CommunitySort.hot.rawValue,
            communitySortReversed: d.bool(forKey: CommunityFeed.reversedKey))
    }

    /// Puts these settings back on this device: writes each one to the key its
    /// screen reads (the @AppStorage-bound controls and everything else reading
    /// those keys pick the new values up on their own) and hands the two that live
    /// on a store rather than in UserDefaults to it.
    ///
    /// Whatever the profile doesn't carry is left as it is, which is what makes a
    /// profile written by an older version safe to restore.
    @MainActor
    func apply(store: ExerciseStore, templates: VisualTemplateStore) {
        let d = UserDefaults.standard

        if let speaker { d.set(speaker, forKey: AudioRouteManager.speakerKey) }
        if let microphone { d.set(microphone, forKey: AudioRouteManager.micKey) }
        if let microphoneDelayMs { d.set(microphoneDelayMs, forKey: microphoneDelayKey) }
        // A "custom:" selection names an instrument the user uploaded, and its audio
        // file isn't part of the profile — restoring the selection would pick a sound
        // that isn't here, so the built-in one this device starts on is left alone.
        if let instrument, !instrument.hasPrefix(CustomInstrumentStore.selectionPrefix) {
            d.set(instrument, forKey: Instrument.storageKey)
        }

        if let theme { d.set(theme, forKey: AppTheme.storageKey) }
        if let orientationLock {
            d.set(orientationLock, forKey: OrientationLock.storageKey)
            // Same follow-up the picker makes, so the app rotates into the restored
            // lock instead of waiting for the next launch.
            OrientationLockManager.apply(OrientationLock(rawValue: orientationLock) ?? .none)
        }
        if let exercisePreviewColor {
            d.set(exercisePreviewColor, forKey: MenuVisualKeys.exercisePreviewColor)
        }
        // The look first, then the templates it was captured alongside: the selection
        // is only a pointer, so the restored template it points at already holds
        // exactly these values.
        playbackVisuals?.apply()
        if let visualTemplates {
            templates.restore(visualTemplates,
                              selectedID: selectedVisualTemplate.flatMap(UUID.init(uuidString:)))
        }

        if let vocalRange { d.set(vocalRange, forKey: VocalRange.storageKey) }
        if let vocalRangeCustomLow { d.set(vocalRangeCustomLow, forKey: VocalRange.customLowKey) }
        if let vocalRangeCustomHigh { d.set(vocalRangeCustomHigh, forKey: VocalRange.customHighKey) }

        if let recommendedExercisesAmount {
            d.set(recommendedExercisesAmount, forKey: RecommendedExercises.amountKey)
        }
        if let recommendationsAsList {
            d.set(recommendationsAsList, forKey: RecommendedExercises.asListKey)
        }
        if let recommendationWhitelist {
            store.restoreRecommendationWhitelist(Set(recommendationWhitelist))
        }

        if let hiddenHomeCategories { HomeCategories.hidden = Set(hiddenHomeCategories) }

        if let communitySort { d.set(communitySort, forKey: CommunityFeed.sortKey) }
        if let communitySortReversed { d.set(communitySortReversed, forKey: CommunityFeed.reversedKey) }
    }
}
