//
//  MicrophonePermission.swift
//  Learn2Sing
//
//  Asking for the microphone from the button that opens a screen which listens,
//  rather than from inside that screen.
//

import AVFoundation

/// The system asks for the microphone once per install. The introduction's range
/// test is where that usually happens; skip it, and the first exercise used to ask.
///
/// It asked from the playback screen, which starts its audio the moment it appears:
/// the session set up for recording, the route moved to the earphones, and after a
/// second without the microphone, the run itself, all underneath the system's alert.
/// Allowing it then brought the microphone up beneath an engine already playing,
/// while the app coming back to the front set the whole session up a second time.
/// That is where a fresh install with AirPods connected crashed.
///
/// So every way into a screen that listens asks first, here: the question goes up
/// over the screen whose button was tapped, and that screen opens once it has been
/// answered, whichever way. Every exercise plays without the microphone too; the
/// playback screen says what is missing then (see `MicrophoneNotice`).
enum MicrophonePermission {
    /// Whether the system has yet to ask. Once it has, the answer stands until the
    /// singer changes it in Settings, and asking again only reports it.
    static var needsAsking: Bool {
        AVAudioApplication.shared.recordPermission == .undetermined
    }

    /// Set while the question is up, so a second tap that slips in before the
    /// system's alert covers the button doesn't open the screen twice.
    private static var isAsking = false

    /// Runs `proceed` once the microphone has been asked for: straight away when it
    /// was asked long ago, otherwise on the main actor once the singer has answered,
    /// allowed or not. A call made while the question is already up is dropped:
    /// the call that put it up is the one that carries on.
    static func askIfNeeded(then proceed: @escaping @MainActor () -> Void) {
        guard needsAsking else {
            proceed()
            return
        }
        guard !isAsking else { return }
        isAsking = true
        Task { @MainActor in
            // Awaited rather than handed a completion block: the system calls that
            // back on a queue of its own, and a closure written here belongs to the
            // main actor.
            _ = await AVAudioApplication.requestRecordPermission()
            isAsking = false
            proceed()
        }
    }
}
