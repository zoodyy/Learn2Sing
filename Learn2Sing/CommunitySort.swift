import Foundation

/// The order the Community tab's list is shown in, picked from the sort menu in
/// the toolbar and remembered across launches. CommunitySync applies it (it owns
/// the like counts, download counts and share dates the orders are based on).
enum CommunitySort: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case mostLiked
    case mostDownloaded
    case alphabetical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest: L("Newest First")
        case .oldest: L("Oldest First")
        case .mostLiked: L("Most Liked")
        case .mostDownloaded: L("Most Downloaded")
        case .alphabetical: L("Alphabetical")
        }
    }

    var systemImage: String {
        switch self {
        case .newest: "clock"
        case .oldest: "clock.arrow.circlepath"
        case .mostLiked: "heart"
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
        case .newest, .oldest: ["CREATED_AT", "DATE_CREATED_AT"]
        case .mostLiked: ["LIKED"]
        case .mostDownloaded: ["DOWNLOADED"]
        case .alphabetical: ["NAME"]
        }
    }

    var serverSortDirection: String {
        switch self {
        case .oldest, .alphabetical: "ASC"
        case .newest, .mostLiked, .mostDownloaded: "DESC"
        }
    }

    /// Whether the server derives this order from the user-event tables. Those
    /// sorts return *only* exercises with at least one event of that type, so a
    /// fetch using one has to be topped up with the rest of the list (see
    /// CommunitySync.refresh).
    var isServerEventSorted: Bool {
        switch self {
        case .mostLiked, .mostDownloaded: true
        case .newest, .oldest, .alphabetical: false
        }
    }
}
