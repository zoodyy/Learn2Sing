//
//  AudioSettingsView.swift
//  Learn2Sing
//

import SwiftUI
import UIKit

/// The "Audio" hub reached from Settings: the playback instrument, the input and
/// output devices, and the microphone-delay compensation used for scoring.
struct AudioSettingsView: View {
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
            } footer: {
                Text("Choose the sound that plays the notes, or upload your own.")
            }

            Section {
                Picker("Speaker", selection: $speaker) {
                    ForEach(options(routes.outputOptions, including: speaker), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Picker("Microphone", selection: $microphone) {
                    ForEach(options(routes.inputOptions, including: microphone), id: \.self) {
                        Text($0).tag($0)
                    }
                }
            } header: {
                Text("Devices")
            } footer: {
                Text("“Automatic” uses connected earphones (e.g. AirPods) when available, otherwise the phone.")
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

                Button(action: openDelayTest) {
                    Label("Test for delay", systemImage: "metronome")
                }
            } header: {
                Text("Scoring")
            } footer: {
                Text("Compensates for the lag between singing and pitch detection. Only the score is affected — playback and visuals are unchanged. Run the test to measure it automatically.")
            }
        }
        .navigationTitle("Audio")
        .navigationBarTitleDisplayMode(.inline)
        // The decimal pad has no return key: show a Done bar pinned above the
        // keyboard while the delay field is edited, and let a scroll dismiss it.
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            if micDelayFocused {
                HStack {
                    Spacer()
                    Button("Done") { micDelayFocused = false }
                        .fontWeight(.semibold)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .onAppear { routes.refreshOptions() }
    }

    /// The device list to show in a picker, guaranteeing the current selection is
    /// present even when that device is no longer connected (so it doesn't vanish).
    private func options(_ list: [String], including selection: String) -> [String] {
        list.contains(selection) ? list : list + [selection]
    }
}
