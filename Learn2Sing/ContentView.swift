//
//  ContentView.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 23.06.26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            ExercisesView()
                .tabItem {
                    Label("Exercises", systemImage: "music.mic")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}


#Preview {
    ContentView()
}
