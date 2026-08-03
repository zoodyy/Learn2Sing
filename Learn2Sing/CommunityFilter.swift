import Foundation

/// A filter the Community tab's list can be narrowed by, picked from the filter
/// menu in the toolbar. The cases are whether this user has liked the public
/// exercise, so they're mutually exclusive: the menu turns one off when the
/// other is picked, and picking neither (the default) shows every exercise.
/// CommunitySync owns the pick, hands it to the server on the next fetch, and
/// owns the liked set the same filter is applied from locally.
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

    /// `likedIDs` are the public exercise ids this user has liked, which is what
    /// the heart on the intro screen writes to.
    func matches(_ exercise: Exercise, likedIDs: Set<UUID>) -> Bool {
        switch self {
        case .liked: likedIDs.contains(exercise.id)
        case .notLiked: !likedIDs.contains(exercise.id)
        }
    }
}
