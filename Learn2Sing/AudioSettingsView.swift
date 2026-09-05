//
//  AudioSettingsView.swift
//  Learn2Sing
//

import SwiftUI
import UIKit

/// The "Audio" hub reached from Settings: the playback instrument, the input and
/// output devices, and the microphone-delay compensation used for scoring.
struct AudioSettingsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @AppStorage(AudioRouteManager.speakerKey) private var speaker = AudioRouteManager.automatic
    @AppStorage(AudioRouteManager.micKey) private var microphone = AudioRouteManager.builtInMic
    @AppStorage(microphoneDelayKey) private var micDelayMs = 0.0
    @FocusState private var micDelayFocused: Bool
    @ObservedObject private var routes = AudioRouteManager.shared

    /// Push the instruments screen / delay-test intro onto the shared Settings
    /// navigation stack.
    let openInstruments: () -> Void
    let openDelayTest: () -> Void

    var body: some View {
        Form {
            Section {
                Button(action: openInstruments) {
                    HStack {
                        Label("Instruments", systemImage: "pianokeys")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                .setting(.instruments)
            }

            Section {
                Picker("Speaker", selection: $speaker) {
                    ForEach(options(routes.outputOptions, including: speaker), id: \.self) {
                        Text(AudioRouteManager.displayName(for: $0)).tag($0)
                    }
                }
                .setting(.speaker)
                Picker("Microphone", selection: $microphone) {
                    ForEach(options(routes.inputOptions, including: microphone), id: \.self) {
                        Text(AudioRouteManager.displayName(for: $0)).tag($0)
                    }
                }
                .setting(.microphone)
            } header: {
                Text("Devices")
            }

            Section {
                HStack {
                    Text("Microphone delay")
                    Spacer()
                    TextField("0", value: $micDelayMs, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .focused($micDelayFocused)
                        .frame(width: 70)
                    Text("ms").foregroundStyle(.secondary)
                }
                .setting(.microphoneDelay)

                Button(action: openDelayTest) {
                    Label("Test for delay", systemImage: "metronome")
                }
                .setting(.delayTest)
            } header: {
                Text("Scoring")
            }
        }
        .navigationTitle(L("Audio"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsSearchable(.audio)
        // The decimal pad has no return key: the shared keyboard bar's "Done" is
        // what closes it — in the same place and with the same look it has on
        // every other keyboard — and a scroll dismisses it too. A delay is never
        // negative, so this one gets no sign toggle.
        .scrollDismissesKeyboard(.interactively)
        .keyboardBar { micDelayFocused = false }
        // Probe for devices the playback configuration hides (a Bluetooth microphone
        // is only visible while the Hands-Free Profile is allowed), so everything
        // that's connected can be picked here.
        .onAppear { routes.refreshOptions(probingDevices: true) }
    }

    /// The device list to show in a picker, guaranteeing the current selection is
    /// present even when that device is no longer connected (so it doesn't vanish).
    private func options(_ list: [String], including selection: String) -> [String] {
        list.contains(selection) ? list : list + [selection]
    }
}
