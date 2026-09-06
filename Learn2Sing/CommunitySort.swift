import Foundation

/// The order the Community tab's list is shown in, picked from the sort menu in
/// the toolbar and remembered across launches. The sorting is the server's: the
/// pick rides along on every fetch as `sortBy` / `sortDirection`, and the list
/// is shown in the order that came back (see CommunityFeed).
enum CommunitySort: String, CaseIterable, Identifiable {
    case hot
    case newest
    case recentlyUpdated
    case mostLiked
    case mostPlayed
    case mostDownloaded
    case alphabetical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hot: L("Hot")
        case .newest: L("Newest First")
        case .recentlyUpdated: L("Recently Updated")
        case .mostLiked: L("Most Liked")
        case .mostPlayed: L("Most Played")
        case .mostDownloaded: L("Most Downloaded")
        case .alphabetical: L("Alphabetical")
        }
    }

    var systemImage: String {
        switch self {
        case .hot: "flame"
        case .newest: "clock"
        case .recentlyUpdated: "arrow.triangle.2.circlepath"
        case .mostLiked: "heart"
        case .mostPlayed: "play.circle"
        case .mostDownloaded: "arrow.down.circle"
        case .alphabetical: "textformat.abc"
        }
    }
}

// MARK: - Server sorting

/// How each order maps onto the public fetch endpoint's `sortBy` /
/// `sortDirection` parameters, which the server needs on every call (it answers
/// 500 without them). This is the whole of the sorting: the app never reorders
/// what comes back, and everything it draws out of a fetched list — the search
/// sections, a filtered list, an uploader's profile — is a subset of one, which
/// is still in the order the server put it in.
extension CommunitySort {
    /// The endpoint's `sortBy` values to try, most likely first. More than one
    /// only for the date orders: the backend answers 400 for the documented
    /// `DATE_CREATED_AT` / `DATE_UPDATED_AT` and 200 for the shorter names, so
    /// the fetch starts with what works today and falls back to the documented
    /// spelling if a deploy ever renames them.
    var serverSortBy: [String] {
        switch self {
        case .hot: ["HOT"]
        case .newest: ["CREATED_AT", "DATE_CREATED_AT"]
        case .recentlyUpdated: ["UPDATED_AT", "DATE_UPDATED_AT"]
        case .mostLiked: ["LIKED"]
        case .mostPlayed: ["PLAYED"]
        case .mostDownloaded: ["DOWNLOADED"]
        case .alphabetical: ["NAME"]
        }
    }

    /// The direction to fetch in, with the sort menu's reverse switch applied —
    /// which is what turns "Newest First" into oldest first, or the alphabetical
    /// order into Z to A. A `reversed` that doesn't apply here (see
    /// `isReversible`) is ignored rather than obeyed.
    func serverSortDirection(reversed: Bool) -> String {
        let flipped = reversed && isReversible
        switch self {
        case .alphabetical: return flipped ? "DESC" : "ASC"
        case .hot, .newest, .recentlyUpdated, .mostLiked, .mostPlayed, .mostDownloaded:
            return flipped ? "ASC" : "DESC"
        }
    }

    /// Whether the sort menu offers its reverse switch for this order. Upside
    /// down, the server's own "Hot" ranking isn't a "coldest" list anyone asked
    /// for, so the switch is hidden — and a remembered one ignored — while it's
    /// the pick.
    var isReversible: Bool {
        switch self {
        case .hot: false
        case .newest, .recentlyUpdated, .mostLiked, .mostPlayed, .mostDownloaded, .alphabetical: true
        }
    }

    /// The order to fetch the rest of the list in, for the one order the server
    /// derives from the user-event tables — or nil for the orders that already
    /// come back whole.
    ///
    /// `hot` returns *only* exercises with an event on them from the last two
    /// weeks, which is how the ranking is meant to work but would drop
    /// everything untouched out of the tab, a just-published exercise included.
    /// So its query is followed by a second in this order, topped up with
    /// whatever the first left out as it is paged (see
    /// `CommunityFeed.makeFeed`). `hot` ranks recency against engagement, so its
    /// remainder is topped up in the order it would rank them in.
    ///
    /// The count orders once needed the same treatment, leaving out every
    /// exercise whose tally was zero. The server now ranks the whole community
    /// in them, zeroes at the far end, so they are fetched as they are.
    var topUpSort: CommunitySort? {
        switch self {
        case .hot: .recentlyUpdated
        case .newest, .recentlyUpdated, .mostLiked, .mostPlayed, .mostDownloaded, .alphabetical: nil
        }
    }
}
