//
//  RecommendationQueue.swift
//  Learn2Sing
//
//  The batch the Home tab's "Recommended" category holds on to between visits.
//

import Foundation
import Combine
import UIKit

/// The batch of exercises "Recommended" is holding on to, so that coming back
/// to the Home tab finds the batch the singer left rather than a new one.
///
/// The draw itself (`ExerciseStore.recommendedExercises`) changes with every
/// run that finishes, since the play history it steers by has moved on. Left to
/// itself, the card would come back from each exercise sung out of it naming a
/// different batch. So once the card is opened — or, with the category shown as
/// a list, one of its rows — what it showed is kept here and shown instead of
/// the draw, in whatever order the queue screen was dragged or shuffled into
/// and without the exercises swiped out of it.
///
/// It is held for as long as a screen opened from "Recommended" is anywhere on
/// the Home tab's stack, and for `holdDuration` after the last of them comes
/// off, however the singer spent that time. Switching tabs closes nothing, and
/// neither does the app going to the background: only going back to the Home
/// list itself, or to a screen opened from anything else on it, does — and the
/// app being closed completely, which is picked up at the next launch.
///
/// Changing how long a day is or the scale limit lets go of it straight away
/// once it is closed, and so does taking one of its exercises off the
/// whitelist: those are the singer asking for a different batch. Kept on the
/// device only, like the play history it was drawn from.
@MainActor
final class RecommendationQueue: ObservableObject {
    static let shared = RecommendationQueue()

    /// How long a batch outlives its screens.
    static let holdDuration: TimeInterval = 20 * 60

    private static let storageKey = "heldRecommendation"

    /// The batch, in the order the queue screen last showed it. Empty when
    /// nothing is held. The queue screen edits it in place.
    @Published var order: [UUID] = [] {
        didSet { save() }
    }

    /// Whether a screen opened from "Recommended" is on the Home tab's stack.
    private var isOpen = false
    /// When the last of those screens came off it, which is when the hold
    /// starts running out. nil while one is open.
    private var closedAt: Date?
    /// When the app last stopped being in front while a screen was open, and
    /// nil while it is in front. The app gets no word of being closed from the
    /// app switcher, so this is the closest there is to when that happened: the
    /// next launch finds a screen still open and closes it as of then.
    private var leftForegroundAt: Date?
    /// The daily practice time and scale limit the batch was drawn under.
    private var minutes = 0
    private var limitScales = false

    /// Wakes up as the hold runs out, so the card changes over while it is on
    /// screen rather than on its next redraw.
    private var expiry: Task<Void, Never>?

    private struct Stored: Codable {
        var order: [UUID]
        var isOpen: Bool
        var closedAt: Date?
        var leftForegroundAt: Date?
        var minutes: Int
        var limitScales: Bool
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            order = stored.order
            isOpen = stored.isOpen
            closedAt = stored.closedAt
            leftForegroundAt = stored.leftForegroundAt
            minutes = stored.minutes
            limitScales = stored.limitScales
        }
        // A screen still open at launch is one the app was closed on, and no
        // launch starts on it again: closed as of the moment the app was last
        // seen, or now if it never left the front (a crash, or Xcode's stop).
        if isOpen || leftForegroundAt != nil {
            if isOpen {
                isOpen = false
                closedAt = leftForegroundAt ?? .now
            }
            leftForegroundAt = nil
            save()
        }
        scheduleExpiry()

        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { RecommendationQueue.shared.leftForeground() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { RecommendationQueue.shared.becameActive() }
        }
    }

    /// The batch still held, or nil when there is none to show any longer. Kept
    /// whatever happens while a screen is open; once they are closed, only
    /// until `holdDuration` is up, and only while it is still the batch these
    /// settings would draw: the same daily time and scale limit, and nothing in
    /// it taken off the whitelist since.
    func held(minutes: Int, limitScales: Bool, whitelist: Set<UUID>) -> [UUID]? {
        guard !order.isEmpty else { return nil }
        if isOpen { return order }
        guard let closedAt, Date.now < closedAt + Self.holdDuration,
              minutes == self.minutes, limitScales == self.limitScales,
              order.allSatisfy(whitelist.contains)
        else { return nil }
        return order
    }

    /// Hold on to `batch`, drawn under `minutes` and `limitScales`: what the
    /// category showed as it was opened, or the new batch the reload button
    /// asked for.
    func hold(_ batch: [UUID], minutes: Int, limitScales: Bool) {
        self.minutes = minutes
        self.limitScales = limitScales
        if order != batch {
            order = batch
        } else {
            save()
        }
    }

    /// Told by the Home tab whenever its stack changes: whether a screen opened
    /// from "Recommended" is on it. Closing the last one starts the clock.
    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        closedAt = open ? nil : .now
        save()
        scheduleExpiry()
    }

    /// Delete Everything: nothing is held, and the next draw is shown.
    func forget() {
        isOpen = false
        closedAt = nil
        order = []
        scheduleExpiry()
    }

    private func leftForeground() {
        guard isOpen, leftForegroundAt == nil else { return }
        leftForegroundAt = .now
        save()
    }

    private func becameActive() {
        if leftForegroundAt != nil {
            leftForegroundAt = nil
            save()
        }
        // A sleep that ran out while the app was suspended may not have woken
        // yet.
        expireIfDue()
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard !isOpen, let closedAt, !order.isEmpty else { return }
        let due = closedAt + Self.holdDuration
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.expireIfDue()
        }
    }

    private func expireIfDue() {
        guard !isOpen, let closedAt, !order.isEmpty,
              Date.now >= closedAt + Self.holdDuration
        else { return }
        self.closedAt = nil
        order = []
    }

    private func save() {
        let stored = Stored(order: order, isOpen: isOpen, closedAt: closedAt,
                            leftForegroundAt: leftForegroundAt,
                            minutes: minutes, limitScales: limitScales)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
