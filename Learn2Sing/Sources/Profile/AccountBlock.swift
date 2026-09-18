//
//  AccountBlock.swift
//  Learn2Sing
//

import Foundation
import Combine
import SwiftUI
import UIKit

/// Whether the server has blocked this user, and until when.
///
/// The server says so in answer to a write: a persist call refused with
/// `error.persist.storage.user.blocked#<days>`, the days being how long the
/// block has left to run. There is no endpoint to ask about it directly, so a
/// refused write is the only way to find out, which is why publishing an
/// exercise re-posts the public profile first (see
/// `CommunitySync.checkPublishing()`).
///
/// A block takes the user's profile off the device: the username, the
/// description, the join date's visibility and the picture. The profile screen
/// shows how long the block has left instead of the fields, and no exercise can
/// be made public until it ends. What was cleared stays cleared, so the ending
/// of a block republishes nothing on its own.
///
/// The end date lives in the profile file, so it rides along in the private
/// backup and a reinstall still knows (see `ProfileSync`). It passes on its own
/// at that date, and sooner if the server takes a public profile post from this
/// user again, which means it has lifted the block.
@MainActor
final class AccountBlock: ObservableObject {
    static let shared = AccountBlock()

    /// What the server's refusal starts with; the number after the `#` is the
    /// days the block has left.
    nonisolated static let errorToken = "error.persist.storage.user.blocked#"

    /// When the block ends, or nil when this user isn't blocked. Published so the
    /// profile screen swaps between its fields and the notice as it changes.
    @Published private(set) var blockedUntil: Date?

    /// Wakes up when the block ends, so the screens showing it change over by
    /// themselves rather than on their next redraw.
    private var expiry: Task<Void, Never>?
    /// A block learned while no scene could show the alert about it, which waits
    /// for the app to come to the front.
    private var announcementPending = false

    private init() {
        // A date already past is a block that has ended; it is simply not taken
        // up, and the next write to the profile file drops it.
        if let stored = UserProfile.load().blockedUntil {
            let until = Date(timeIntervalSince1970: stored)
            if until > Date() { schedule(until) }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard AccountBlock.shared.announcementPending else { return }
                AccountBlock.shared.announce()
            }
        }
    }

    var isBlocked: Bool {
        guard let blockedUntil else { return false }
        return blockedUntil > Date()
    }

    /// Whole days the block has left as of `now`, rounded up — the last few hours
    /// of a block are still a day of it — and 0 once it is over.
    func daysLeft(at now: Date = Date()) -> Int {
        guard let blockedUntil, blockedUntil > now else { return 0 }
        return max(1, Int((blockedUntil.timeIntervalSince(now) / Self.day).rounded(.up)))
    }

    /// What the user is told, everywhere they are told it: the alert when the
    /// block is learned, the profile screen, and the refusal to publish.
    func message(at now: Date = Date()) -> String {
        L("Your account is blocked, so your profile has been removed and you can't make exercises public. The block ends in %@.",
          Self.formatted(days: daysLeft(at: now)))
    }

    // MARK: - Learning of a block

    /// The days a refused write's body says the block has left, or nil when the
    /// body is no block refusal at all. The token comes bare or inside a JSON
    /// error object, so it is looked for anywhere in the body; one that carries
    /// no readable number is still a block, and counts as a day.
    ///
    /// Only for bodies that came back with a failing status: a document the
    /// server took is echoed back in its answer, and a description quoting the
    /// token would otherwise block its own author.
    nonisolated static func daysLeft(in data: Data) -> Double? {
        guard let body = String(data: data, encoding: .utf8),
              let marker = body.range(of: errorToken)
        else { return nil }
        let number = body[marker.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(number) ?? 1
    }

    /// Takes in a write the server refused because this user is blocked:
    /// remembers until when, and takes the profile off the device.
    ///
    /// Every refusal restates the days left, so this is also how a block the app
    /// already knew of is kept up to date. Only a block that is news to this
    /// device is announced, and only when `announce` is set — the refusal to
    /// publish says the same thing in an alert of its own.
    func record(daysLeft days: Double, announce: Bool) {
        let isNews = !isBlocked
        // A refusal is only sent while a block is running, so one claiming no
        // days left is in its last hours.
        let until = Date().addingTimeInterval(max(days, 1) * Self.day)
        block(until: until)
        if isNews && announce { self.announce() }
    }

    /// Picks up a block the private backup carried, on a reinstall. Not
    /// announced: the user was told when it was first learned.
    func restore(until stored: Double) {
        let until = Date(timeIntervalSince1970: stored)
        guard until > Date(), until != blockedUntil else { return }
        block(until: until)
    }

    /// The server took a public profile post from this user, so whatever block
    /// this device knew of is over. Also what the end date passing comes to.
    func lift() {
        guard blockedUntil != nil else { return }
        expiry?.cancel()
        expiry = nil
        blockedUntil = nil
        var profile = UserProfile.load()
        profile.blockedUntil = nil
        profile.save()
        ProfileSync.shared.scheduleUpload()
    }

    /// Writes the block back into a profile file that has just been deleted, for
    /// "Delete Everything": a block is the server's doing rather than the
    /// user's data, and wiping the device doesn't end it.
    func rewrite() {
        guard isBlocked, let blockedUntil else { return }
        var profile = UserProfile.load()
        profile.blockedUntil = blockedUntil.timeIntervalSince1970
        profile.save()
    }

    // MARK: - Private

    private static let day: TimeInterval = 86_400

    /// Stores the end date and clears the profile: in the file, which is what the
    /// profile screen and both syncs read, and the picture, which lives beside
    /// it. Clearing a profile that is already empty changes nothing, so the
    /// refusals that come in while a block is running only move the date.
    private func block(until: Date) {
        var profile = UserProfile.load()
        profile.username = ""
        profile.profileDescription = nil
        profile.joinDatePublic = nil
        profile.blockedUntil = until.timeIntervalSince1970
        profile.save()
        schedule(until)
        // Asks for a community upload too. That finds no username and posts no
        // profile; a shared exercise it re-posts may be refused again, which
        // lands back here with the picture already gone and only moves the date.
        if ProfilePictureStore.shared.document != nil {
            ProfilePictureStore.shared.removePicture()
        }
        ProfileSync.shared.scheduleUpload()
    }

    private func schedule(_ until: Date) {
        blockedUntil = until
        expiry?.cancel()
        expiry = Task { [weak self] in
            // The continuous clock keeps counting while the device sleeps, so a
            // block that ended overnight is over the moment the app next runs.
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.lift()
        }
    }

    /// "5 days", "1 day", in the app's language — plurals included, which a
    /// "%d days" key couldn't manage in Russian, Polish or Arabic.
    private static func formatted(days: Int) -> String {
        Duration.seconds(Double(days) * day).formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.days], width: .wide)
                .locale(LanguageManager.shared.language.locale))
    }

    /// Tells the user, over whatever is on screen. Put up from UIKit rather than
    /// as a SwiftUI alert on one screen, because the refusal can come in anywhere
    /// — a launch's upload, an exercise synced in the background — and a sheet
    /// already up (the photo picker, say) would stop a SwiftUI alert from the
    /// root from showing at all.
    private func announce() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.keyWindow?.rootViewController
        else {
            announcementPending = true
            return
        }
        announcementPending = false
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let alert = UIAlertController(title: L("Account Blocked"), message: message(),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("OK"), style: .cancel))
        // The app's own theme, which a presentation doesn't necessarily pick up
        // from the screen under it.
        switch AppTheme.current.colorScheme {
        case .dark: alert.overrideUserInterfaceStyle = .dark
        case .light: alert.overrideUserInterfaceStyle = .light
        default: break
        }
        top.present(alert, animated: true)
    }
}
