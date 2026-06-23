//
//  SettingsView.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 23.06.26.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(Instrument.storageKey) private var instrumentRaw = Instrument.piano.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Picker("Instrument", selection: $instrumentRaw) {
                        ForEach(Instrument.allCases) { instrument in
                            Text(instrument.rawValue).tag(instrument.rawValue)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
