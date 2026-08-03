import Foundation

/// The order the Community tab's list is shown in, picked from the sort menu in
/// the toolbar and remembered across launches. CommunitySync applies the two it
/// can (it owns the share dates "Newest First" goes by), and leaves the rest in
/// the order the server returned them — see `isServerOrdered`.
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
/// 500 without them). The list still gets sorted locally afterwards as well:
/// search results, the like filters and the per-uploader profiles all show
/// subsets, which only the app can order.
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

    /// The order to fetch the rest of the list in, for the orders the server
    /// derives from the user-event tables — or nil for the ones that already come
    /// back whole.
    ///
    /// Those orders return *only* exercises with at least one event row, which is
    /// how they are meant to work but would drop everything untouched out of the
    /// tab, a just-published exercise included. So a fetch using one is followed
    /// by a second fetch in this order and topped up with whatever the first left
    /// out (see CommunitySync.refresh). `hot` ranks recency against engagement, so
    /// its remainder is topped up in the order it would rank them in; the count
    /// orders put theirs, all of them zero, at the tail newest first.
    var topUpSort: CommunitySort? {
        switch self {
        case .hot: .recentlyUpdated
        case .mostLiked, .mostPlayed, .mostDownloaded: .newest
        case .newest, .recentlyUpdated, .alphabetical: nil
        }
    }

    /// Whether only the server can put this order together, so the app shows the
    /// fetched list in the order it arrived rather than re-deriving one.
    ///
    /// `hot` is the server's own ranking of recency against engagement, and
    /// `recentlyUpdated` goes by the record's server-side write time — neither
    /// number is in what the fetch hands back. The three count orders are the
    /// server's too: the app knows a like/play/download total only for the
    /// exercises that have been opened on this device (the tally is fetched per
    /// exercise — see CommunitySync.refreshSummary), so it has nothing to rank
    /// the list on. Picking any of these refetches (see CommunityView), which is
    /// what keeps the held list in the order the menu is asking for — the reverse
    /// switch included, since the fetch is what carries it as `sortDirection`.
    var isServerOrdered: Bool {
        switch self {
        case .hot, .recentlyUpdated, .mostLiked, .mostPlayed, .mostDownloaded: true
        case .newest, .alphabetical: false
        }
    }
}
