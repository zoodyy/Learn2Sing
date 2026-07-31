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
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        case .mostLiked: "Most Liked"
        case .mostDownloaded: "Most Downloaded"
        case .alphabetical: "Alphabetical"
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
