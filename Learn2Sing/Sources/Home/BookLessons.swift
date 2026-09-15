//
//  BookLessons.swift
//  Learn2Sing
//
//  The Home tab's book lessons: short reads about singing that ship in
//  BookLessons.json, and which of them the singer has marked as finished.
//

import Combine
import Foundation

/// A page a book lesson was adapted from, credited at the bottom of the lesson.
///
/// Only sources whose terms allow their text to be reused commercially: the U.S.
/// National Institute on Deafness and Other Communication Disorders, whose pages
/// are in the public domain, and Wikipedia and Wikibooks, whose text is shared
/// under CC BY-SA 4.0. That license asks for three things, and the credit gives
/// all of them: a link to the page, a link to the license, and the adaptation
/// shared under the same license.
struct BookLessonSource: Decodable, Hashable {
    enum Kind: String, Decodable {
        case nidcd, wikipedia, wikibooks

        /// Whether the page's text is shared under CC BY-SA, so a lesson adapted
        /// from it has to say it is shared under that license too.
        var isShareAlike: Bool { self != .nidcd }
    }

    let kind: Kind
    /// The page's own title, in English in every language: it names the page
    /// the link opens, which is the English one.
    let title: String
    let url: URL
}

/// One lesson. Its text is stored in English and translated on the way to the
/// screen, the way the bundled exercises are (see BundledLocalization), so the
/// progress stored for it is an id that means the same in every language.
struct BookLesson: Decodable, Identifiable, Hashable {
    let id: String
    /// The id of the topic it belongs to.
    let topic: String
    let title: String
    /// The text, one entry per paragraph. Each paragraph is its own key in the
    /// string catalog, which keeps a translation short enough to check.
    let paragraphs: [String]
    let sources: [BookLessonSource]
}

/// What a group of lessons is about, as named on the lessons screen's tabs.
struct BookLessonTopic: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
}

/// Every lesson the app ships, read once from BookLessons.json.
struct BookLessonLibrary: Decodable {
    /// In the order the lessons screen's tabs show them.
    let topics: [BookLessonTopic]
    let lessons: [BookLesson]
    /// Every lesson's id, in the order it makes sense to read them: how the voice
    /// works, how to stand and how to breathe first, then the topics taking turns
    /// so the list never runs on about one subject for long. The recommendation
    /// walks down it.
    let recommendedOrder: [String]

    static let shared = load()

    /// An empty library if the file is missing or doesn't decode, which leaves
    /// the Home tab's "Book Lessons" category empty rather than broken.
    private static func load() -> BookLessonLibrary {
        guard let url = Bundle.main.url(forResource: "BookLessons", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(BookLessonLibrary.self, from: data)
        else {
            return BookLessonLibrary(topics: [], lessons: [], recommendedOrder: [])
        }
        return library
    }

    /// Every lesson in reading order. One the order doesn't list still counts,
    /// on the end, so it is recommended and finished like the rest.
    var ordered: [BookLesson] {
        let listed = recommendedOrder.compactMap(lesson)
        return listed + lessons.filter { !recommendedOrder.contains($0.id) }
    }

    func lesson(_ id: String) -> BookLesson? {
        lessons.first { $0.id == id }
    }

    func topic(_ id: String) -> BookLessonTopic? {
        topics.first { $0.id == id }
    }

    /// A topic's lessons, in reading order.
    func lessons(in topic: String) -> [BookLesson] {
        ordered.filter { $0.topic == topic }
    }
}

/// Which book lessons the singer has marked as finished, and so which one the
/// Home tab recommends next: the first in reading order that isn't.
///
/// Keeps count of one round through the lessons at a time. Finishing the last
/// unfinished lesson starts the next round with every lesson unfinished again,
/// which is the only way the recommendation comes back round to a lesson already
/// read. Stored in UserDefaults and carried in the synced profile, so a
/// reinstall picks the round up where it was left.
final class BookLessonProgress: ObservableObject {
    static let shared = BookLessonProgress()

    private static let finishedKey = "finishedBookLessons"

    /// The lessons finished this round, by id, in the order they were finished.
    @Published private(set) var finished: [String]

    private var library: BookLessonLibrary { .shared }

    private init() {
        finished = UserDefaults.standard.stringArray(forKey: Self.finishedKey) ?? []
    }

    func isFinished(_ id: String) -> Bool {
        finished.contains(id)
    }

    /// How many of the app's lessons are finished this round. An id left behind
    /// by a lesson an update has since removed isn't counted.
    var finishedCount: Int {
        library.lessons.filter { finished.contains($0.id) }.count
    }

    /// The lessons still to read this round, in reading order: the recommended
    /// one first, then the ones its skip button moves on to. Should every lesson
    /// there is be finished anyway (an update took away the one still left), the
    /// round is as good as over, and it is all of them.
    var unfinished: [BookLesson] {
        let left = library.ordered.filter { !finished.contains($0.id) }
        return left.isEmpty ? library.ordered : left
    }

    /// The lesson to read next. nil only when the app has no lessons at all.
    var recommended: BookLesson? {
        unfinished.first
    }

    /// The lesson screen's "Mark as Finished" button.
    func markFinished(_ id: String) {
        guard library.lesson(id) != nil, !finished.contains(id) else { return }
        finished.append(id)
        startNextRoundIfComplete()
        save()
    }

    /// Reset ▸ Home ▸ Clear Finished Lessons, and Delete Everything: every lesson
    /// unfinished again, and the recommendation back at the first.
    func clear() {
        guard !finished.isEmpty else { return }
        finished = []
        save()
    }

    /// Adds the lessons a restored profile had finished to this device's round.
    /// Merged rather than replaced, like the Home tab's other lists, so a lesson
    /// finished here before the restore arrived stays finished.
    func merge(_ restored: [String]) {
        let missing = restored.filter { library.lesson($0) != nil && !finished.contains($0) }
        guard !missing.isEmpty else { return }
        finished.append(contentsOf: missing)
        startNextRoundIfComplete()
        save()
    }

    private func startNextRoundIfComplete() {
        guard !library.lessons.isEmpty,
              library.lessons.allSatisfy({ finished.contains($0.id) })
        else { return }
        finished = []
    }

    private func save() {
        UserDefaults.standard.set(finished, forKey: Self.finishedKey)
        ProfileSync.shared.scheduleUpload()
    }
}
