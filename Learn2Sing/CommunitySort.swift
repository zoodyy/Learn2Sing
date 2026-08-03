import Foundation

/// The order the Community tab's list is shown in, picked from the sort menu in
/// the toolbar and remembered across launches. CommunitySync applies it (it owns
/// the like counts, download counts and share dates the orders are based on),
/// except for the two the server alone can work out — see `isServerOrdered`.
enum CommunitySort: String, CaseIterable, Identifiable {
    case hot
    case newest
    case oldest
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
        case .oldest: L("Oldest First")
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
        case .oldest: "clock.arrow.circlepath"
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
        case .newest, .oldest: ["CREATED_AT", "DATE_CREATED_AT"]
        case .recentlyUpdated: ["UPDATED_AT", "DATE_UPDATED_AT"]
        case .mostLiked: ["LIKED"]
        case .mostPlayed: ["PLAYED"]
        case .mostDownloaded: ["DOWNLOADED"]
        case .alphabetical: ["NAME"]
        }
    }

    var serverSortDirection: String {
        switch self {
        case .oldest, .alphabetical: "ASC"
        case .hot, .newest, .recentlyUpdated, .mostLiked, .mostPlayed, .mostDownloaded: "DESC"
        }
    }

    /// Whether the server derives this order from the user-event tables. Those
    /// sorts return *only* exercises with at least one event of that type, so a
    /// fetch using one has to be topped up with the rest of the list (see
    /// CommunitySync.refresh). `hot` is event-based too but outer-joined — it
    /// hands back the whole list — so it isn't one of these.
    var isServerEventSorted: Bool {
        switch self {
        case .mostLiked, .mostPlayed, .mostDownloaded: true
        case .hot, .newest, .oldest, .recentlyUpdated, .alphabetical: false
        }
    }

    /// Whether only the server can put this order together, so the app shows the
    /// fetched list in the order it arrived rather than re-deriving one.
    ///
    /// `hot` is the server's own ranking of recency against engagement, and
    /// `recentlyUpdated` goes by the record's server-side write time — neither
    /// number is in what the fetch hands back. Picking one of these refetches
    /// (see CommunityView), which is what keeps the held list in the order the
    /// menu is asking for.
    var isServerOrdered: Bool {
        switch self {
        case .hot, .recentlyUpdated: true
        case .newest, .oldest, .mostLiked, .mostPlayed, .mostDownloaded, .alphabetical: false
        }
    }
}
