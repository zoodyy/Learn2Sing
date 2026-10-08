//
//  InstrumentsView.swift
//  Learn2Sing
//

import SwiftUI

/// The "Instruments" screen inside the Audio settings: the sounds the app can
/// play the notes with. Tapping a name picks it; the speaker beside it plays a
/// short sample.
struct InstrumentsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @ObservedObject private var preview = InstrumentPreviewPlayer.shared
    @AppStorage(Instrument.storageKey) private var instrumentRaw = Instrument.piano.rawValue

    var body: some View {
        Form {
            Section {
                ForEach(Instrument.allCases) { instrument in
                    // Two buttons in the row — pick the instrument, or hear it — so
                    // both are borderless: the row-wide button style would take the
                    // whole row for itself and never let the speaker be tapped.
                    HStack(spacing: 0) {
                        Button {
                            instrumentRaw = instrument.rawValue
                        } label: {
                            HStack {
                                Text(instrument.title)
                                Spacer()
                                if instrumentRaw == instrument.rawValue {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.primary)

                        InstrumentSampleButton(isPlaying: preview.isPlaying(instrument)) {
                            preview.play(instrument)
                        }
                    }
                    .setting(.instrument(instrument))
                }
            }
        }
        .navigationTitle(L("Instruments"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsSearchable(.instruments)
        // Leaving the screen cuts a sample short and hands the audio session back,
        // so nothing is left playing behind it.
        .onDisappear { preview.stop() }
    }
}
