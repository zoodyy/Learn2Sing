//
//  Localization.swift
//  Learn2Sing
//
//  The app's language is chosen in Settings › Language rather than following the
//  device, so it lives entirely in UserDefaults: it is deliberately absent from
//  `UserProfile`, which is what ProfileSync mirrors to the server. UserDefaults is
//  wiped when the app is deleted, so a reinstall always comes back up in English.
//

import Foundation
import SwiftUI
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
        }
    }

    /// Drives SwiftUI's own resolution of `LocalizedStringKey` as well as number
    /// and date formatting, and is what makes a language change repaint the
    /// screens that are already on screen.
    var locale: Locale { Locale(identifier: rawValue) }

    /// The `.lproj` the strings are read from. English is resolved explicitly
    /// rather than left to the main bundle's own lookup, which would follow the
    /// device's preferred languages — the app is English until the user picks
    /// otherwise, whatever the device is set to.
    var bundle: Bundle? {
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj")
        else { return nil }
        return Bundle(path: path)
    }
}

/// Holds the selected language and republishes it so the view tree repaints.
/// A singleton because `L(_:)` — used from plain-`String` call sites that have no
/// access to the environment — has to be able to read it synchronously.
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    /// Local only, and never added to `UserProfile`: deleting the app resets the
    /// choice to English, which is the intended behaviour.
    static let storageKey = "appLanguage"

    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
            Self.current = language
        }
    }

    /// Read by `L(_:)` off the main actor without touching the published property.
    fileprivate static var current: AppLanguage = .english

    private init() {
        // No fallback to the device language: unset means English, always.
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        let initial = stored.flatMap(AppLanguage.init(rawValue:)) ?? .english
        language = initial
        Self.current = initial
        Bundle.installLanguageOverride()
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
