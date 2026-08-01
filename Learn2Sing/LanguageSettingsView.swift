//
//  LanguageSettingsView.swift
//  Learn2Sing
//
//  The "Language" hub reached from Settings: which language the app is displayed
//  in. The choice is device-local — see Localization.swift — so a reinstall comes
//  back up in English rather than restoring the previous selection.
//

import SwiftUI

struct LanguageSettingsView: View {
    @EnvironmentObject private var languages: LanguageManager

    var body: some View {
        Form {
            Section {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        languages.language = language
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(language.nativeName)
                                // Hidden for English, where it would just repeat
                                // the line above it.
                                if language.englishName != language.nativeName {
                                    Text(language.englishName)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if languages.language == language {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(languages.language == language ? .isSelected : [])
                }
            } header: {
                Text("App Language")
            } footer: {
                Text("Applies to the app's own screens and the exercises it came with. Your own exercise names and notes are left as you wrote them. This setting is kept on this device only, so reinstalling the app returns it to English.")
            }
        }
        .navigationTitle(L("Language"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
