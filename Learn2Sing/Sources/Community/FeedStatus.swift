//
//  FeedStatus.swift
//  Learn2Sing
//
//  What a list of community exercises shows in place of the rows that haven't
//  arrived: a spinner while they are on their way, and a reload button when they
//  aren't coming on their own.
//

import SwiftUI

/// The reload button a list offers when the fetch behind its rows didn't come
/// back — no connection, or a server that answered with an error. Tapping it
/// asks again.
///
/// Deliberately just the symbol: it stands where the spinner stood, so what it
/// says is "that isn't loading — press here", and a word beside it would say the
/// same thing twice in every language. What it is for is spelled out to
/// VoiceOver and under a press-and-hold, where there is room for a sentence.
///
/// The tap is the caller's, not this view's: on the Home tab the whole row is
/// the button (the list reports the tap like any other), while the Community
/// tab's empty state wraps this in a `Button` of its own.
struct FeedRetryIcon: View {
    /// What a press-and-hold explains — the reason this is here rather than
    /// rows, which the symbol alone can't say. Each caller passes its own, so
    /// the wording is a literal at the call site (see Tools/Localization).
    let help: String

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.title2)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel(L("Try Again"))
            .explain(help)
    }
}
