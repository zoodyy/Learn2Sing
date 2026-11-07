//
//  Localization.swift
//  Learn2Sing
//
//  The app's language is chosen in Settings › Language: "Automatic", the default,
//  follows the device's language (English where the app doesn't have it), and
//  every other row fixes one language whatever the device is set to. The choice
//  lives entirely in UserDefaults: it is deliberately absent from `UserProfile`,
//  which is what ProfileSync mirrors to the server. UserDefaults is wiped when the
//  app is deleted, so a reinstall always comes back up on Automatic.
//

import Foundation
import SwiftUI
import UIKit
import Combine
import ObjectiveC.runtime

/// A language the app can be displayed in. The raw value is the localization
/// code, matching the `.lproj` folders produced from `Localizable.xcstrings`.
enum AppLanguage: String, CaseIterable, Identifiable, Hashable {
    case english    = "en"
    case german     = "de"
    case spanish    = "es"
    case french     = "fr"
    case italian    = "it"
    case portuguese = "pt-BR"
    case dutch      = "nl"
    case russian    = "ru"
    case polish     = "pl"
    case turkish    = "tr"
    case swedish    = "sv"
    case japanese   = "ja"
    case korean     = "ko"
    case chinese    = "zh-Hans"
    case arabic     = "ar"

    var id: String { rawValue }

    /// The language's own name for itself, which is what a speaker of it scans
    /// the list for. Hard-coded rather than taken from `Locale` so the list reads
    /// identically no matter which language is currently active.
    var nativeName: String {
        switch self {
        case .english:    return "English"
        case .german:     return "Deutsch"
        case .spanish:    return "Español"
        case .french:     return "Français"
        case .italian:    return "Italiano"
        case .portuguese: return "Português (Brasil)"
        case .dutch:      return "Nederlands"
        case .russian:    return "Русский"
        case .polish:     return "Polski"
        case .turkish:    return "Türkçe"
        case .swedish:    return "Svenska"
        case .japanese:   return "日本語"
        case .korean:     return "한국어"
        case .chinese:    return "简体中文"
        case .arabic:     return "العربية"
        }
    }

    /// The English name, shown underneath the native one so the list stays
    /// navigable for someone who picked a script they can't read by mistake.
    var englishName: String {
        switch self {
        case .english:    return "English"
        case .german:     return "German"
        case .spanish:    return "Spanish"
        case .french:     return "French"
        case .italian:    return "Italian"
        case .portuguese: return "Portuguese (Brazil)"
        case .dutch:      return "Dutch"
        case .russian:    return "Russian"
        case .polish:     return "Polish"
        case .turkish:    return "Turkish"
        case .swedish:    return "Swedish"
        case .japanese:   return "Japanese"
        case .korean:     return "Korean"
        case .chinese:    return "Chinese (Simplified)"
        case .arabic:     return "Arabic"
        }
    }

    /// `nativeName` and `englishName` as they read inside a parenthesis of their
    /// own, on the Language screen's Automatic row: the two names that carry one
    /// already are said another way there, so the row never reads
    /// "Automático (Português (Brasil))".
    var nativeNameInline: String {
        self == .portuguese ? "Português do Brasil" : nativeName
    }

    var englishNameInline: String {
        switch self {
        case .portuguese: return "Brazilian Portuguese"
        case .chinese:    return "Simplified Chinese"
        default:          return englishName
        }
    }

    /// Drives SwiftUI's own resolution of `LocalizedStringKey` as well as number
    /// and date formatting, and is what makes a language change repaint the
    /// screens that are already on screen.
    var locale: Locale { Locale(identifier: rawValue) }

    /// Which way the app is laid out while this language is chosen: mirrored for a
    /// script read from right to left. Asked of the language rather than listed, so
    /// a right-to-left language added later mirrors the app without being told to.
    var layoutDirection: LayoutDirection {
        Locale.Language(identifier: rawValue).characterDirection == .rightToLeft
            ? .rightToLeft : .leftToRight
    }

    /// The `.lproj` the strings are read from. English is resolved explicitly
    /// rather than left to the main bundle's own lookup, which would follow the
    /// device's preferred languages on its own terms — the app shows the language
    /// picked in Settings, and even Automatic decides for itself (see `device`).
    var bundle: Bundle? {
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj")
        else { return nil }
        return Bundle(path: path)
    }

    /// The language Automatic shows the app in: the one the device is set to,
    /// when the app has it, and English when it doesn't. Only the device's first
    /// language counts, not the fallbacks listed under it in the system settings,
    /// so a device set to a language the app lacks gets English even if one of
    /// the app's languages is further down that list. Which of the app's
    /// languages the device's one comes out as is left to Apple's own matching,
    /// the rule iOS picks an app's localization by: a device in Portuguese
    /// (Portugal) gets Portuguese (Brazil), one in Spanish (Mexico) gets Spanish,
    /// and one in Traditional Chinese gets English rather than the Simplified
    /// script. Where nothing matches, that matching answers English.
    static var device: AppLanguage {
        guard let preferred = Locale.preferredLanguages.first,
              let match = Bundle.preferredLocalizations(
                  from: allCases.map(\.rawValue), forPreferences: [preferred]).first
        else { return .english }
        return AppLanguage(rawValue: match) ?? .english
    }
}

/// The row checked in Settings › Language: one of the app's languages, or
/// Automatic, which stands for whichever of them the device's language is.
enum LanguageChoice: Hashable {
    case automatic
    case specific(AppLanguage)
}

/// Holds the chosen language and the one the app is displayed in, and republishes
/// them so the view tree repaints. A singleton because `L(_:)` — used from
/// plain-`String` call sites that have no access to the environment — has to be
/// able to read it synchronously.
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    /// Local only, and never added to `UserProfile`: deleting the app resets the
    /// choice to Automatic, which is the intended behaviour. Holds the code of a
    /// language picked on the Language screen; Automatic is the key's absence, so
    /// a new install follows the device, and so does an install from before
    /// Automatic existed whose user never picked a language (English was only the
    /// default then, and nothing was stored for it).
    static let storageKey = "appLanguage"

    /// The row checked on the Language screen. The only thing anything sets: the
    /// language the app is displayed in follows from it.
    @Published var choice: LanguageChoice {
        didSet {
            guard choice != oldValue else { return }
            switch choice {
            case .automatic:
                UserDefaults.standard.removeObject(forKey: Self.storageKey)
            case .specific(let picked):
                UserDefaults.standard.set(picked.rawValue, forKey: Self.storageKey)
            }
            resolve()
        }
    }

    /// The language the app is displayed in: the chosen one, or the device's for
    /// Automatic. What every screen reads, its locale and its strings both.
    @Published private(set) var language: AppLanguage

    /// What Automatic stands for, which the Language screen shows beside it whether
    /// or not it is the row checked. Worked out at launch: changing the device's
    /// language quits every app, so the next launch is where the change arrives,
    /// and an app on Automatic simply comes up in the new language. Asked again
    /// should the system announce a locale change to the running app.
    @Published private(set) var deviceLanguage: AppLanguage

    /// Brings `language` in line with the choice and the device.
    private func resolve() {
        let resolved: AppLanguage
        switch choice {
        case .automatic: resolved = deviceLanguage
        case .specific(let picked): resolved = picked
        }
        guard resolved != language else { return }
        language = resolved
        Self.current = resolved
        applyLayoutDirection()
    }

    private func refreshDeviceLanguage() {
        let device = AppLanguage.device
        guard device != deviceLanguage else { return }
        deviceLanguage = device
        resolve()
    }

    /// Mirrors the whole app for a right-to-left language. The window scene's trait
    /// is the one place that is said: UIKit reads it (the navigation and tab bars,
    /// the back swipe, the exercise lists' collection views, everything presented
    /// over the tab view) and SwiftUI takes its `\.layoutDirection` from it, so the
    /// app never sets that environment value for the language (only the drawings
    /// that run left to right in every language pin it). Views that already exist don't
    /// all follow a live change, which is why ContentView rebuilds the tab view when
    /// the direction flips. Stated for the left-to-right languages too, or the
    /// device's language would decide for them.
    func applyLayoutDirection() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            applyLayoutDirection(to: scene)
        }
    }

    private func applyLayoutDirection(to scene: UIWindowScene) {
        scene.traitOverrides.layoutDirection =
            language.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    /// Read by `L(_:)` off the main actor without touching the published property.
    fileprivate static var current: AppLanguage = .english

    private init() {
        // Unset means Automatic, and so does a code the app has no language for.
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
            .flatMap(AppLanguage.init(rawValue:))
        let device = AppLanguage.device
        let initial = stored ?? device
        choice = stored.map(LanguageChoice.specific) ?? .automatic
        deviceLanguage = device
        language = initial
        Self.current = initial
        Bundle.installLanguageOverride()
        // The device's language can't change under a running app (the change
        // quits it), but its locale can, and this is how the system says so: worth
        // asking again, in case a change of language ever arrives this way.
        _ = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { LanguageManager.shared.refreshDeviceLanguage() }
        }
        // A scene is turned the right way round as it connects, before any of its
        // views exist, so nothing is built one way and then flipped. The app
        // delegate creates this manager at launch so the observer is in place.
        _ = NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification, object: nil, queue: .main
        ) { note in
            guard let scene = note.object as? UIWindowScene else { return }
            MainActor.assumeIsolated { LanguageManager.shared.applyLayoutDirection(to: scene) }
        }
    }
}

/// Looks up `key` in the selected language. Use this wherever a plain `String` is
/// needed — alert messages, `settingHelp(_:)`, values assigned to `@State` — since
/// those never pass through SwiftUI's own `LocalizedStringKey` resolution.
/// Literal `Text("…")`, `Label`, `Button`, `navigationTitle` and friends already
/// take a `LocalizedStringKey` and resolve against the environment locale instead.
func L(_ key: String) -> String {
    let language = LanguageManager.current
    guard let bundle = language.bundle else { return key }
    // `value: key` makes a missing translation fall back to the English source
    // text rather than showing the raw key.
    return bundle.localizedString(forKey: key, value: key, table: nil)
}

/// `L(_:)` with `String(format:)` arguments, for messages that interpolate.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: LanguageManager.current.locale, arguments: arguments)
}

private extension Bundle {
    /// Repoints `Bundle.main`'s string lookup at the selected language, so
    /// `NSLocalizedString` and anything inside UIKit that localizes through the
    /// main bundle follow the in-app choice instead of the device language.
    static func installLanguageOverride() {
        guard !hasInstalledLanguageOverride else { return }
        hasInstalledLanguageOverride = true
        object_setClass(Bundle.main, LanguageOverridingBundle.self)
    }

    private static var hasInstalledLanguageOverride = false
}

/// `Bundle.main` is reclassed to this so every lookup is routed through the
/// currently selected language's `.lproj`.
private final class LanguageOverridingBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard let bundle = LanguageManager.current.bundle else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return bundle.localizedString(forKey: key, value: value, table: tableName)
    }
}
