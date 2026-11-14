//
//  InputLimits.swift
//  Learn2Sing
//

import SwiftUI

// What every field in the app may hold.
//
// None of these limits is meant to be met by anybody using the app the way it is
// meant to be used: each sits far past anything a name, a message or an exercise
// needs. They are there so that nothing typed, and nothing another user
// publishes, can grow large enough to bring the app down. A public exercise is
// opened on other people's phones, so an exercise's limits are held twice: where
// it is typed (the settings screen and the MIDI editor), and again wherever one
// is read back in (see `Exercise.withinLimits()` and the decoders that call it),
// since a document on the server needn't have been written by this app at all.

/// How much text each field takes, counted in Unicode scalars rather than in the
/// characters the screen shows: a character can be built from any number of
/// scalars (an accent stacked on an accent on a letter), so only a scalar count
/// bounds how much text there really is. For ordinary text the two are the same.
nonisolated enum TextLimit {
    /// An exercise's name, which titles its screens and its rows.
    static let exerciseName = 100
    /// An exercise's description, shown before it starts.
    static let exerciseDetails = 2000
    /// A category's name on the Exercises tab.
    static let categoryName = 50
    /// A label written over the notes in the MIDI editor: a syllable to sing,
    /// usually, and drawn as wide as its text.
    static let label = 40
    /// A routine's name and description, the same as an exercise's.
    static let routineName = exerciseName
    static let routineDetails = exerciseDetails
    /// A username, shown beside every exercise its owner shares.
    static let username = 40
    /// What a user writes about themselves on their profile.
    static let profileDescription = 1000
    /// A message sent from Settings ▸ Feedback.
    static let feedbackMessage = 5000
    /// The reply address on the feedback form: the longest an email address can
    /// be (RFC 5321).
    static let email = 254
    /// What a user adds to a report about an exercise or a profile.
    static let reportMessage = 2000
    /// A saved visual template's name.
    static let templateName = 50
    /// What a search field takes.
    static let search = 100
    /// How much of an exercise's description goes along in the community upload's
    /// address, for the server's search, in UTF-8 bytes. The whole of it is in the
    /// document itself; the copy in the address has to leave room for the rest of
    /// the request inside the 8 KB a server takes for its first line and headers,
    /// and a byte there can take three characters to write out.
    static let uploadedDescriptionBytes = 1500
}

nonisolated extension String {
    /// This string cut down to at most `limit` Unicode scalars (see `TextLimit`),
    /// ending on a whole character, so what is left reads as the start of what
    /// was typed. Unchanged when it is already short enough.
    func limited(to limit: Int) -> String {
        guard unicodeScalars.count > limit else { return self }
        var kept = 0
        var end = startIndex
        for index in indices {
            let next = self.index(after: index)
            let size = self[index..<next].unicodeScalars.count
            guard kept + size <= limit else { break }
            kept += size
            end = next
        }
        return String(self[..<end])
    }

    /// This string cut down to at most `limit` bytes of UTF-8, ending on a whole
    /// character.
    func limited(toUTF8Bytes limit: Int) -> String {
        guard utf8.count > limit else { return self }
        var kept = 0
        var end = startIndex
        for index in indices {
            let next = self.index(after: index)
            let size = self[index..<next].utf8.count
            guard kept + size <= limit else { break }
            kept += size
            end = next
        }
        return String(self[..<end])
    }
}

extension Binding where Value == String {
    /// This binding with whatever is written through it cut down to `limit`
    /// scalars (see `String.limited(to:)`), so the text field it drives stops
    /// taking characters once it is full, and a paste is cut off at the limit.
    ///
    /// The cut goes in two steps. A value that comes out the same as the one
    /// already held changes nothing, so SwiftUI has no reason to redraw the field,
    /// and the field — which shows what was typed, not what was kept — goes on
    /// showing the characters past the limit. So the text first goes one
    /// character over, which is a change, and is cut back on the next turn of the
    /// main queue, which is another: the field is redrawn with what was kept. One
    /// character over is as much as anything bound to the text ever sees, however
    /// much was pasted.
    func limited(to limit: Int) -> Binding<String> {
        Binding(get: { wrappedValue }, set: { newValue in
            let held = newValue.limited(to: limit)
            guard held != newValue else {
                wrappedValue = newValue
                return
            }
            wrappedValue = newValue.limited(to: limit + 1)
            DispatchQueue.main.async {
                // Whatever the field holds by then, which may already be newer.
                let current = wrappedValue
                let cut = current.limited(to: limit)
                if cut != current { wrappedValue = cut }
            }
        })
    }
}

nonisolated extension Comparable {
    /// This value held inside `range`.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

nonisolated extension Array {
    /// The first `limit` elements, or all of them when there aren't that many.
    func capped(at limit: Int) -> [Element] {
        count > limit ? Array(prefix(Swift.max(0, limit))) : self
    }
}
