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
