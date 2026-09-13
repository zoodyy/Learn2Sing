//
//  MicrophoneNotice.swift
//  Learn2Sing
//
//  What a screen that listens to the singer says when microphone access is off.
//

import SwiftUI

/// Every exercise plays without the microphone, so the notice only has to say what
/// is lost and then get out of the way: it comes up at most once per launch, and
/// never again after "Don't Show Again".
///
/// That choice stays on this device rather than riding along in the profile
/// (`UserSettings` lists what does), since whether the microphone is allowed is
/// decided per device too.
enum MicrophoneNotice {
    static let dismissedKey = "microphoneNoticeDismissed"
    /// Set when the notice comes up, so the next exercise of the same session plays
    /// without it. Not stored: the next launch warns again, until "Don't Show Again".
    static var wasShownThisLaunch = false
}

extension View {
    /// Puts the microphone notice up when `isDenied` turns true, unless it was
    /// already shown this launch or the user asked never to see it again.
    /// `onShow` and `onDismiss` let a running exercise hold still while it is read;
    /// "Open Settings" deliberately calls neither back, so the singer returns from
    /// Settings to the run still paused where they left it.
    func microphoneNotice(isDenied: Bool,
                          onShow: @escaping () -> Void = {},
                          onDismiss: @escaping () -> Void = {}) -> some View {
        modifier(MicrophoneNoticeModifier(isDenied: isDenied, onShow: onShow, onDismiss: onDismiss))
    }
}

private struct MicrophoneNoticeModifier: ViewModifier {
    let isDenied: Bool
    let onShow: () -> Void
    let onDismiss: () -> Void

    @AppStorage(MicrophoneNotice.dismissedKey) private var isDismissedForGood = false
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onChange(of: isDenied) { _, denied in
                guard denied, !isDismissedForGood, !MicrophoneNotice.wasShownThisLaunch else { return }
                MicrophoneNotice.wasShownThisLaunch = true
                isPresented = true
                onShow()
            }
            // An alert's actions and message are built in its own environment, which
            // misses the app's chosen language, so they go through `L`.
            .alert("Microphone Access Is Off", isPresented: $isPresented) {
                Button(L("Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button(L("Don’t Show Again")) {
                    isDismissedForGood = true
                    onDismiss()
                }
                Button(L("OK"), role: .cancel) { onDismiss() }
            } message: {
                Text(L("Every exercise still plays, but Learn2Sing can’t hear you sing. Without the microphone, no line follows your voice, runs aren’t scored, and the vocal range and microphone delay tests can’t measure anything. You can allow access in Settings at any time."))
            }
    }
}
