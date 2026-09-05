//
//  DelayTestViews.swift
//  Learn2Sing
//
//  The two ways of measuring the microphone delay, reached from Settings ▸ Audio ▸
//  "Test for delay": the clap test, which times claps against a metronome and works
//  the value out itself, and the sung test, which plays one of the user's own
//  exercises and lets them line their recorded singing up with the notes by hand.
//

import SwiftUI

/// The screen "Test for delay" opens: which of the two tests to run. The tests
/// measure the same thing in opposite ways — one automatic and quick, one by eye
/// over a real exercise — so neither is presented as the default.
struct DelayTestChoiceView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    /// Push the chosen test onto the shared Settings navigation stack.
    let openClapTest: () -> Void
    let openSungTest: () -> Void

    var body: some View {
        Form {
            Section {
                SettingsHubRow(title: L("Clap Test"), systemImage: "metronome",
                               action: openClapTest)
                    .setting(.clapTest)

                SettingsHubRow(title: L("Sing an Exercise"), systemImage: "music.mic",
                               action: openSungTest)
                    .setting(.sungTest)
            } header: {
                Text("Choose a Test")
            }
        }
        .navigationTitle(L("Test for delay"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsSearchable(.delayChoice)
    }
}

/// The exercise the sung delay test is run with. The same categorized list as the
/// other pickers, but with no check circles: one tap starts the run rather than
/// adding the exercise to anything.
struct DelayTestExercisePickerView: View {
    let onSelect: (UUID) -> Void

    var body: some View {
        ExerciseMultiPickerList(onToggle: onSelect, title: L("Choose an Exercise"))
    }
}
