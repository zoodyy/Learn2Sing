import Foundation

/// A filter the Community tab's list can be narrowed by, picked from the filter
/// menu in the toolbar. The cases are whether this user has liked the public
/// exercise, so they're mutually exclusive: the menu turns one off when the
/// other is picked, and picking neither (the default) shows every exercise.
/// CommunitySync owns the pick and hands it to the server, which is what applies
/// it: a filtered fetch returns the list as it should be shown.
enum CommunityFilter: String, CaseIterable, Identifiable {
    case liked
    case notLiked

    var id: String { rawValue }

    /// The public fetch endpoint's `filter` value for this pick. Sent alongside
    /// `userId`, which is what makes it mean *this* user's likes; the endpoint
    /// ignores a `filter` that arrives without one.
    var serverValue: String {
        switch self {
        case .liked: "LIKED"
        case .notLiked: "NOT_LIKED"
        }
    }

    var label: String {
        switch self {
        case .liked: L("Liked")
        case .notLiked: L("Not Liked")
        }
    }

    var systemImage: String {
        switch self {
        case .liked: "heart.fill"
        case .notLiked: "heart.slash"
        }
    }
}
