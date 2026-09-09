//
//  OrientationLock.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 05.07.26.
//

import SwiftUI
import UIKit

/// The user's orientation-lock choice. "Don't lock" leaves the app free to rotate
/// between all the orientations its Info.plist allows (portrait + both landscapes).
enum OrientationLock: String, CaseIterable, Identifiable {
    case none      = "Don't lock"
    case portrait  = "Portrait"
    case landscape = "Landscape"

    var id: String { rawValue }

    static let storageKey = "orientationLock"

    /// The interface-orientation mask this choice permits. iOS intersects this with
    /// the Info.plist orientations, so "Don't lock" just re-offers that full set.
    var mask: UIInterfaceOrientationMask {
        switch self {
        case .none:      return [.portrait, .landscapeLeft, .landscapeRight]
        case .portrait:  return .portrait
        case .landscape: return .landscape
        }
    }

    /// The currently stored choice (defaults to not locking).
    static var current: OrientationLock {
        OrientationLock(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .none
    }
}

/// SwiftUI has no built-in orientation-lock hook, so a UIKit app delegate answers
/// the system's orientation query from a mask we control. `@UIApplicationDelegateAdaptor`
/// in `Learn2SingApp` installs it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The mask `supportedInterfaceOrientationsFor` returns. Seeded from the stored
    /// choice on first access (which happens after launch, so UserDefaults is ready).
    static var orientationMask: UIInterfaceOrientationMask = OrientationLock.current.mask

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }
}

enum OrientationLockManager {
    /// Apply a lock: update the mask the app delegate reports and ask the active
    /// scene to rotate into it immediately, so the change takes effect without
    /// waiting for the next physical rotation.
    static func apply(_ lock: OrientationLock) {
        AppDelegate.orientationMask = lock.mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: lock.mask))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
