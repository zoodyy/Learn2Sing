//
//  LanguageSettingsView.swift
//  Learn2Sing
//
//  The "Language" hub reached from Settings: which language the app is displayed
//  in. "Automatic", the first row and the default, follows the device's language;
//  every other row fixes one. The choice is device-local — see Localization.swift —
//  so a reinstall comes back up on Automatic rather than restoring the previous
//  selection.
//

import SwiftUI

struct LanguageSettingsView: View {
    @EnvironmentObject private var languages: LanguageManager

    var body: some View {
        Form {
            Section {
                automaticRow
                ForEach(AppLanguage.allCases) { language in
                    row(title: language.nativeName, englishTitle: language.englishName,
                        isSelected: languages.choice == .specific(language)) {
                        languages.choice = .specific(language)
                    }
                    .settingAnchor(.appLanguage(language))
                }
            } header: {
                Text("App Language").settingSection(.languageAppLanguage)
            } footer: {
                Text("Applies to the app's own screens and the exercises it came with. Your own exercise names and notes are left as you wrote them. This setting is kept on this device only, so reinstalling the app returns it to “Automatic”.")
            }
        }
        .navigationTitle(L("Language"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsSearchable(.language)
    }

    /// Automatic, named with the language it stands for: the device's, or English
    /// where the app doesn't have that one. Checked on its own, never alongside the
    /// row of the language it currently comes out as.
    private var automaticRow: some View {
        let device = languages.deviceLanguage
        return row(title: Self.automaticTitle(for: device),
                   englishTitle: Self.automaticEnglishTitle(for: device),
                   isSelected: languages.choice == .automatic) {
            languages.choice = .automatic
        }
        .setting(.appLanguageAutomatic)
    }

    /// One row of the list: its name in its own words, with the English name
    /// underneath so the list stays navigable for someone who picked a script they
    /// can't read by mistake.
    private func row(title: String, englishTitle: String, isSelected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    // Hidden where it would just repeat the line above it:
                    // English, and Automatic while the app is in English and
                    // Automatic stands for English too.
                    if englishTitle != title {
                        Text(englishTitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .foregroundStyle(.primary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension LanguageSettingsView {
    /// The Settings row that leads here. In any language but English it carries
    /// the English word as well, "Sprache (Language)", so someone who picked a
    /// language they can't read by mistake can still find the way back.
    static var rowTitle: String {
        let title = L("Language")
        return LanguageManager.shared.language == .english ? title : "\(title) (Language)"
    }

    /// Automatic's row in the app's language, "Automatisch (Deutsch)". The
    /// language it stands for goes by its own name, as in the rows under it, so
    /// it reads the same whichever language the app is in.
    static func automaticTitle(for language: AppLanguage) -> String {
        L("Automatic (%@)", language.nativeNameInline)
    }

    /// The same row's English line, "Automatic (German)". English in every
    /// language on purpose, like `AppLanguage.englishName`.
    static func automaticEnglishTitle(for language: AppLanguage) -> String {
        "Automatic (\(language.englishNameInline))"
    }
}
