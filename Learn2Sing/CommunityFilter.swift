import Foundation

/// A filter the Community tab's list can be narrowed by, picked from the filter
/// menu in the toolbar. The cases are whether this user has liked the public
/// exercise, so they're mutually exclusive: the menu turns one off when the
/// other is picked, and picking neither (the default) shows every exercise.
/// CommunitySync owns the liked set the filter is based on.
enum CommunityFilter: String, CaseIterable, Identifiable {
    case liked
    case notLiked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .liked: "Liked"
        case .notLiked: "Not Liked"
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

extension Set<CommunityFilter> {
    /// Whether the exercise satisfies the picks in this set; an empty set doesn't
    /// restrict anything.
    func matches(_ exercise: Exercise, likedIDs: Set<UUID>) -> Bool {
        isEmpty || contains { $0.matches(exercise, likedIDs: likedIDs) }
    }
}
