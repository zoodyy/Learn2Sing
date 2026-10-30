//
//  AudioDebugFlag.swift
//  Learn2Sing
//
//  TEMPORARY AUDIO DEBUG LOG: see AudioDebugLog.swift for what it is and how to
//  remove it.
//
//  The ladybug button in the exercise screen's bar, on the installs that log: the
//  developer marks a run whose sound went wrong the moment it happens, so the run
//  can be found in the log without remembering when it was. It also shares the
//  whole log, for when the Mac isn't to hand.
//
//  Every label here is `Text(verbatim:)` or a plain String, which the string
//  catalog's extractor deliberately ignores, so nothing needs translating. It has
//  no press-and-hold explanation: it is the developer's own tool and goes when the
//  log does.
//

import SwiftUI
import UIKit

/// What a flag says went wrong.
enum AudioDebugFlag: String, CaseIterable, Identifiable {
    case late
    case silent
    case glitch
    case other
    case fine

    var id: String { rawValue }

    var label: String {
        switch self {
        case .late: "Sound Is Late"
        case .silent: "Sound Stopped After the Start"
        case .glitch: "Crackling or Broken Sound"
        case .other: "Other Audio Problem"
        case .fine: "This Run Was Fine"
        }
    }

    var symbol: String {
        switch self {
        case .late: "clock.badge.exclamationmark"
        case .silent: "speaker.slash"
        case .glitch: "waveform.badge.exclamationmark"
        case .other: "exclamationmark.bubble"
        case .fine: "checkmark.circle"
        }
    }
}

extension View {
    /// Puts the ladybug button in the bar, on the installs that log.
    func audioDebugFlagButton() -> some View {
        toolbar {
            if AudioDebugLog.isEnabled {
                ToolbarItem(placement: .topBarTrailing) {
                    AudioDebugFlagMenu()
                }
            }
        }
    }
}

private struct AudioDebugFlagMenu: View {
    var body: some View {
        Menu {
            ForEach(AudioDebugFlag.allCases) { flag in
                Button {
                    AudioDebugLog.flag(flag)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    AudioDebugToast.show("Flagged: " + flag.label)
                } label: {
                    Label { Text(verbatim: flag.label) } icon: { Image(systemName: flag.symbol) }
                }
            }
            Divider()
            Button {
                AudioDebugShare.present()
            } label: {
                Label { Text(verbatim: "Share Audio Log") } icon: { Image(systemName: "square.and.arrow.up") }
            }
        } label: {
            Image(systemName: "ladybug")
                .toolbarSymbolHitArea()
        }
        .accessibilityLabel(Text(verbatim: "Audio Debug Log"))
    }
}

/// A short note at the top of the screen, drawn by UIKit so it shows over whatever
/// SwiftUI has up, sheets included.
private enum AudioDebugToast {
    static func show(_ text: String) {
        guard let window = AudioDebugShare.keyWindow() else { return }
        let label = UILabel()
        label.text = "  " + text + "  "
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.textAlignment = .center
        label.sizeToFit()
        label.frame.size.height += 16
        label.center = CGPoint(x: window.bounds.midX, y: window.safeAreaInsets.top + 60)
        window.addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 1.6, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}

/// Zips the log folder and offers it to the share sheet.
private enum AudioDebugShare {
    static func present() {
        AudioDebugToast.show("Packing the audio log")
        AudioDebugCore.shared.packageForSharing { url in
            guard let url, let window = keyWindow(), var top = window.rootViewController else {
                AudioDebugToast.show("Could not pack the audio log")
                return
            }
            while let presented = top.presentedViewController { top = presented }
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = window
                popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
            }
            top.present(controller, animated: true)
        }
    }

    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
    }
}
