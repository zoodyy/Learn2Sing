import Foundation

/// A filter the Exercises tab's list can be narrowed by, picked from the filter
/// menu in the toolbar. The cases form two independent groups — where an exercise
/// came from, and whether it's shared — that combine like this: within a group
/// the picks are OR'd, across groups they're AND'd, and a group with nothing
/// picked doesn't restrict anything. So "Bundled + Public" means every bundled
/// *and* every public exercise, while "Own + Public" means only the user's own
/// public ones.
enum ExerciseFilter: String, CaseIterable, Identifiable {
    case bundled     // shipped with the app
    case community   // downloaded from the Community tab
    case own         // created by the user: neither of the above
    case `public`
    case `private`

    var id: String { rawValue }

    /// Where an exercise came from. Every exercise matches exactly one of these.
    static let sourceCases: [ExerciseFilter] = [.bundled, .community, .own]
    /// Whether an exercise is shared on the Community tab.
    static let visibilityCases: [ExerciseFilter] = [.public, .private]

    var label: String {
        switch self {
        case .bundled: "Bundled Exercises"
        case .community: "Community Exercises"
        case .own: "Own Exercises"
        case .public: "Public Exercises"
        case .private: "Private Exercises"
        }
    }

    var systemImage: String {
        switch self {
        case .bundled: "shippingbox"
        case .community: "person.3"
        case .own: "person"
        case .public: "globe"
        case .private: "lock"
        }
    }

    /// `isBundled` comes from the store, which owns the bundled-id list.
    func matches(_ exercise: Exercise, isBundled: Bool) -> Bool {
        switch self {
        case .bundled: isBundled
        case .community: !isBundled && exercise.downloadedFrom != nil
        case .own: !isBundled && exercise.downloadedFrom == nil
        case .public: exercise.visibility == .public
        case .private: exercise.visibility == .private
        }
    }
}

extension Set<ExerciseFilter> {
    /// Whether the exercise satisfies every group that has a pick in this set.
    func matches(_ exercise: Exercise, isBundled: Bool) -> Bool {
        for group in [ExerciseFilter.sourceCases, ExerciseFilter.visibilityCases] {
            let picked = group.filter { contains($0) }
            guard picked.isEmpty
                    || picked.contains(where: { $0.matches(exercise, isBundled: isBundled) })
            else { return false }
        }
        return true
    }
}
