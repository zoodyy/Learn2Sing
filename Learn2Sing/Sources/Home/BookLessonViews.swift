//
//  BookLessonViews.swift
//  Learn2Sing
//
//  The Home tab's "Book Lessons": its card, the screen the card opens, and the
//  screen a single lesson is read on. See BookLessons.swift for the lessons and
//  the progress through them.
//

import SwiftUI

/// The Home tab's "Book Lessons" category as a single card: a big book beside
/// the title of the lesson recommended next, with how many of the lessons are
/// finished under it. Tapping it opens BookLessonsView.
///
/// Drawn to the practice calendar's shape like the recommendation card, so the
/// tab's cards are all exactly the same size, and laid out like that card too:
/// the book where it has its play button, the title where it names a category,
/// and the progress where it draws its stars.
struct BookLessonsCard: View {
    /// The recommended lesson's title, in English: translated here, the way the
    /// recommendation card translates its category.
    let title: String
    let finished: Int
    let total: Int

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Image(systemName: "book.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(height: geo.size.height * 0.72)
                    .foregroundStyle(Color.accentColor)
                    // The card is read as one thing, and the book says nothing
                    // the "opens" trait doesn't already.
                    .accessibilityHidden(true)

                VStack(spacing: geo.size.height * 0.07) {
                    Text(L(title))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        // A long title shrinks rather than pushing the card
                        // taller, which would break it away from the calendar's
                        // size.
                        .minimumScaleFactor(0.5)

                    progress(cardHeight: geo.size.height)
                }
                .padding(.horizontal, geo.size.height * 0.18)
                .frame(maxWidth: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(PracticeCalendarView.cardAspectRatio, contentMode: .fit)
        .accessibilityElement(children: .combine)
    }

    /// How far through this round of lessons the singer is: a bar filling up,
    /// and the count beside it. Sized off the card like the recommendation
    /// card's stars, so it keeps its proportions however wide the list is.
    private func progress(cardHeight: CGFloat) -> some View {
        let fraction = total > 0 ? CGFloat(finished) / CGFloat(total) : 0
        return HStack(spacing: cardHeight * 0.06) {
            Capsule()
                .fill(Color.gray.opacity(0.3))
                .overlay(alignment: .leading) {
                    GeometryReader { bar in
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: bar.size.width * fraction)
                    }
                }
                .frame(width: cardHeight * 0.7, height: cardHeight * 0.06)

            // Digits and a slash, written the same way in every language.
            Text(verbatim: "\(finished)/\(total)")
                .font(.system(size: cardHeight * 0.11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Finished lessons:"))
        .accessibilityValue(Text(verbatim: "\(finished)/\(total)"))
    }
}

/// The screen the book lessons card opens: the lesson recommended next at the
/// top, then a tab for each topic, and the lessons of the picked topic listed
/// under them the way the recommendation queue lists its exercises.
///
/// The tabs start out on the recommended lesson's topic and follow the
/// recommendation from one topic to the next as lessons are finished, until a
/// tab is tapped: from then on the screen stays on the topic picked.
struct BookLessonsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @ObservedObject private var progress = BookLessonProgress.shared

    /// Opens a lesson: the lesson ids its skip button walks along, and where in
    /// them to start.
    let onOpen: (_ lessonIDs: [String], _ index: Int) -> Void

    /// The topic a tab tap picked. nil follows the recommended lesson's topic.
    @State private var pickedTopic: String? = nil

    private var library: BookLessonLibrary { .shared }

    private var selectedTopic: String? {
        pickedTopic ?? progress.recommended?.topic ?? library.topics.first?.id
    }

    var body: some View {
        List {
            if let recommended = progress.recommended {
                Section {
                    recommendedRow(recommended)
                } header: {
                    Text(ExerciseCategoryName.localized(HomeCategories.recommended))
                        .textCase(nil)
                }
            }
            // A row of its own rather than the lessons' section header: a header
            // keeps its insets whatever it is told and cuts the tabs off where
            // its text would end, while a row can reach the edges of the list.
            // Drawn on the list's background, so it reads as the lessons'
            // heading and not as a card.
            Section {
                topicTabs
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listSectionSpacing(4)
            if let selectedTopic {
                let lessons = library.lessons(in: selectedTopic)
                Section {
                    ForEach(Array(lessons.enumerated()), id: \.element.id) { index, lesson in
                        // The skip button walks on through the rest of the
                        // topic, the way a Home category's Next button does.
                        lessonRow(lesson) { onOpen(lessons.map(\.id), index) }
                    }
                }
            }
        }
        .navigationTitle(L("Book Lessons"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The lesson recommended next, drawn bigger than the rows below it: the
    /// topic it is from, its title, and the start of its text. Opens with the
    /// rest of this round's unfinished lessons queued behind it, which is where
    /// its skip button goes.
    private func recommendedRow(_ lesson: BookLesson) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let topic = library.topic(lesson.topic) {
                    Text(L(topic.name))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                Text(L(lesson.title))
                    .font(.title3.weight(.semibold))
                if let opening = lesson.paragraphs.first {
                    Text(L(opening))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        // The row only draws where it has content, so the space beside a short
        // title would otherwise not take the tap.
        .contentShape(Rectangle())
        .onTapGesture { onOpen(progress.unfinished.map(\.id), 0) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .settingHelp(L("The lesson to read next. Lessons are recommended in an order where each one builds on the ones before. Tap to read it."))
    }

    /// One lesson of the picked topic: its title, with a check mark once it has
    /// been marked as finished this round. A tap gesture rather than a Button,
    /// like the queue screen's rows, so the row keeps the plain look of a list.
    private func lessonRow(_ lesson: BookLesson, open: @escaping () -> Void) -> some View {
        HStack {
            Text(L(lesson.title))
                .frame(maxWidth: .infinity, alignment: .leading)
            if progress.isFinished(lesson.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel(L("Finished"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .settingHelp(L("Tap to read this lesson. A check mark means you have already marked it as finished."))
    }

    /// A tab per topic, scrolling sideways when they don't all fit: some
    /// languages name the topics at more length than one row of the screen has
    /// room for.
    ///
    /// Laid out in a row with no insets, so the tabs scroll out to the edges of
    /// the lessons below; the content margin puts the first tab back in line
    /// with the rows' text.
    private var topicTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(library.topics) { topic in
                        topicTab(topic)
                            .id(topic.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            // The tab picked on the way in may be one that starts off screen.
            .onAppear {
                if let selectedTopic { proxy.scrollTo(selectedTopic, anchor: .center) }
            }
            .onChange(of: selectedTopic) { _, topic in
                guard let topic else { return }
                withAnimation { proxy.scrollTo(topic, anchor: .center) }
            }
        }
    }

    /// One topic's tab. The picked one is filled in like the Start button, the
    /// others drawn in the quieter style the skip button beside it uses.
    private func topicTab(_ topic: BookLessonTopic) -> some View {
        let isSelected = topic.id == selectedTopic
        return Button {
            withAnimation(.snappy) { pickedTopic = topic.id }
        } label: {
            let name = Text(L(topic.name))
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            if isSelected {
                name
                    .foregroundStyle(.white)
                    .background(.tint, in: Capsule())
            } else {
                name
                    .foregroundStyle(.tint)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .explain(L("A topic the lessons are about. Tap it to list its lessons below."))
    }
}

/// One book lesson, laid out like an exercise's intro screen with the lesson in
/// place of the exercise: the title as its heading, the text where the
/// description goes, and along the bottom the Start button's twin, which marks
/// the lesson as finished, with the skip button beside it while there is a next
/// lesson to skip to. Under the text, the pages it was adapted from are
/// credited, with links to them and to the license.
struct BookLessonView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    let lesson: BookLesson
    /// Leaves this lesson unfinished and opens the next one. nil on the last
    /// lesson of the list it was opened from, which leaves the finish button the
    /// row to itself, the same as on the last exercise of a queue.
    var onSkip: (() -> Void)? = nil
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L(lesson.title))
                        .font(.largeTitle.weight(.bold))

                    ForEach(Array(lesson.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(L(paragraph))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .explain(L("The lesson itself. The pages its text was adapted from are credited at the bottom."))
                    }

                    credits
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }

            HStack(spacing: 12) {
                Button(action: onFinish) {
                    Text("Mark as Finished")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .explain(L("Marks this lesson as finished and goes back to the lessons. Once every lesson is finished, the recommendations start again from the first one."))
                if let onSkip {
                    QueueSkipButton(accessibilityLabel: L("Skip Lesson"),
                                    help: L("Leaves this lesson for later and opens the next one."),
                                    action: onSkip)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle(L(lesson.title))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Where the lesson was adapted from: a line per source with its title
    /// linked to the page, and, when any of them is shared under CC BY-SA, a
    /// line saying this lesson is shared under it too, linked to the license.
    private var credits: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            ForEach(lesson.sources, id: \.self) { source in
                Text(BookLessonCredit.line(for: source))
            }
            if lesson.sources.contains(where: \.kind.isShareAlike) {
                Text(BookLessonCredit.licenseLine)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
        .explain(L("Where this lesson comes from, and the license it is shared under. Tap a link to open it."))
    }
}

/// The lines crediting a book lesson's sources, with the page and the license
/// they name turned into links.
enum BookLessonCredit {
    /// A name, not a phrase: the same in every language.
    static let licenseName = "CC BY-SA 4.0"
    static let licenseURL = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")

    static func line(for source: BookLessonSource) -> AttributedString {
        let text = switch source.kind {
        case .wikipedia:
            L("Adapted from the Wikipedia article “%@”.", source.title)
        case .wikibooks:
            L("Adapted from the Wikibooks page “%@”.", source.title)
        case .nidcd:
            L("Adapted from “%@” by the U.S. National Institute on Deafness and Other Communication Disorders (NIDCD), in the public domain.", source.title)
        }
        return linking(source.title, in: text, to: source.url)
    }

    static var licenseLine: AttributedString {
        linking(licenseName, in: L("This lesson is shared under %@.", licenseName), to: licenseURL)
    }

    /// `text` with `phrase` turned into a link. Found in the finished sentence
    /// rather than placed by position, since every language puts it somewhere
    /// else.
    private static func linking(_ phrase: String, in text: String, to url: URL?) -> AttributedString {
        var result = AttributedString(text)
        if let url, let range = result.range(of: phrase) {
            result[range].link = url
        }
        return result
    }
}
