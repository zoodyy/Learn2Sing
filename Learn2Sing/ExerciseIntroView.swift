import SwiftUI

/// Shown right after an exercise is tapped, before playback begins. Presents the
/// exercise's description so the singer knows what to do, with a button to start.
/// When opened from the Community tab a like button sits above the Download
/// button, on the trailing edge, and Download copies the exercise into the user's
/// own library (the Exercises tab).
struct ExerciseIntroView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    let exercise: Exercise
    /// Whether to ask the server how hard this exercise is and draw the stars.
    /// False for the audio delay test's stand-in, which is a measurement rather
    /// than an exercise anyone practises and so is never rated.
    var showsDifficulty = true
    /// Public id of the community exercise the like button acts on; nil (every
    /// tab but Community) hides the button.
    var likeID: UUID? = nil
    /// Whoever uploaded this exercise, shown under the title as the "Created by"
    /// line. Empty (every tab but Community, where an exercise in the library is
    /// the user's own) leaves the line out.
    var uploaderName: String = ""
    /// Opens that uploader's profile — the same screen a tap on their name in
    /// the Community list leads to. nil leaves the line out as well: a name that
    /// led nowhere would read as a broken link rather than as attribution.
    var onSelectUploader: (() -> Void)? = nil
    var onDownload: (() -> Void)? = nil
    /// Opens this exercise's settings from the toolbar. nil (Community, where the
    /// exercise isn't in the user's library yet) hides the button.
    var onSettings: (() -> Void)? = nil
    /// Leaves this exercise unplayed and opens the next one in the queue, as a
    /// skip button beside Start. Only a routine or the recommendation queue sets
    /// it, and only while there is a next exercise — everywhere else (and on the
    /// last of a queue) the Start button has the row to itself.
    var onSkip: (() -> Void)? = nil
    let onStart: () -> Void

    /// Source of the like count and of whether this user already liked it; both
    /// change as soon as the heart is tapped. Observed on CommunitySync's counts
    /// object rather than on CommunitySync itself, so a tap redraws this screen
    /// and not the Community list behind it.
    @ObservedObject private var counts = CommunitySync.shared.counts
    private var community: CommunitySync { .shared }

    /// The id the server counts this exercise under. An exercise opened from the
    /// Community tab arrives holding its public id already (that is what the feed
    /// lists it by, and `likeID`); every other tab holds the private id it is
    /// stored under, whose public form has to be derived — the same one its plays
    /// are posted with, so the difficulty asked for here is the one they add up
    /// to. See PublicIdentifier for why the private id can't travel itself.
    private var publicExerciseID: UUID {
        likeID ?? PublicIdentifier.exercise(exercise.id)
    }

    /// Flips after a download so the button confirms instead of copying again.
    @State private var isDownloaded = false

    /// What the server's users tend to score on this exercise, 0-100, which the
    /// stars draw inverted as how hard it is (see `difficultyRow`).
    ///
    /// Read from the cache CommunitySync keeps, so an exercise opened before
    /// draws its stars on this frame instead of after the round trip; the task
    /// below asks the server anyway and the stars follow whatever it says. nil —
    /// no stars at all — only for an exercise this device has never had an
    /// answer for: one with no rating yet, or one whose first fetch hasn't
    /// landed.
    private var difficulty: Double? {
        showsDifficulty ? counts.difficulties[publicExerciseID] : nil
    }

    /// Toggled by the "See Score" toolbar button to show/hide the score-history
    /// chart under the description.
    @State private var showScore = false

    /// Put up by a tap on the difficulty row: the rating the stars draw, as the
    /// number they were drawn from. A tap rather than the hold the row's
    /// explanation answers to, so the two questions a row of stars raises —
    /// what is this, and what does it say exactly — get an answer each.
    @State private var showDifficultyNumber = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Height the chart is given, measured off the result screen's portrait
    /// layout so the two plots come out the same size. (Measured with the
    /// temporary debug-export button gone — while it is there it squeezes the
    /// result screen's chart, and this one is the taller of the two.)
    /// Landscape gets a shorter one: the result screen puts the chart beside the
    /// score rather than under it, and here the card has to share a short screen
    /// with the description and the Start button.
    private var chartHeight: CGFloat {
        verticalSizeClass == .compact ? 200 : 380
    }

    private var trimmedDetails: String {
        exercise.localizedDetails.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(exercise.localizedName)
                        .font(.largeTitle.weight(.bold))

                    if !uploaderName.isEmpty, let onSelectUploader {
                        uploaderRow(onSelectUploader)
                    }

                    if let difficulty {
                        difficultyRow(difficulty)
                    }

                    if trimmedDetails.isEmpty {
                        Text("No description.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .explain(L("What to do in this exercise. Whoever made it writes this in the exercise's settings."))
                    } else {
                        Text(trimmedDetails)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .explain(L("What to do in this exercise. Whoever made it writes this in the exercise's settings."))
                    }

                    if showScore {
                        scoreChartCard
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }

            if let likeID {
                HStack(spacing: 8) {
                    downloadCount(for: likeID)
                    Spacer()
                    likeButton(for: likeID)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            if let onDownload {
                Button {
                    onDownload()
                    withAnimation { isDownloaded = true }
                } label: {
                    Label(isDownloaded ? L("Added to Exercises") : L("Download"),
                          systemImage: isDownloaded ? "checkmark" : "arrow.down.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.tint)
                }
                .disabled(isDownloaded)
                .explain(L("Copies this exercise into your own library, where you can change it and keep your scores for it."))
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            HStack(spacing: 12) {
                Button(action: onStart) {
                    Text("Start")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .explain(L("Begins the exercise. Sing along with the notes as they scroll past, and you get a score at the end."))
                if let onSkip {
                    skipButton(onSkip)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle(exercise.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        // This screen is the only place the community counts are shown, and the
        // server summarises one exercise per call, so the tally is fetched here
        // — on the exercise that was tapped — instead of for the whole list on
        // every Community refresh.
        .task {
            if let likeID { await community.refreshSummary(for: likeID) }
        }
        // The difficulty is the server's average of everyone's scores for this
        // exercise, so it is fetched per exercise like the counts above — and for
        // every tab, since the stars are drawn on all of them.
        .task(id: publicExerciseID) {
            guard showsDifficulty else { return }
            await community.refreshDifficulty(for: publicExerciseID)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { showScore.toggle() }
                } label: {
                    Label("See Score", systemImage: "chart.line.uptrend.xyaxis")
                }
                .explain(L("Shows how you have scored on this exercise so far, as a chart under the description."))
            }
            // Same screen the list's "Settings" swipe action opens, and the same
            // symbol, so the two read as one action.
            if let onSettings {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSettings) {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .explain(L("Opens this exercise's settings: its name, tempo, repetitions and notes."))
                }
            }
        }
    }

    /// Leave this exercise unplayed and go on to the next one in the queue.
    /// Beside the Start button rather than in the toolbar, since it is the other
    /// answer to the question that screen asks — play this, or don't. Built from
    /// the same `.padding()` the Start button uses so the two are the same height
    /// at every text size, and drawn in the app's quieter button style (the
    /// Download and Review buttons') so Start stays the obvious one. A symbol
    /// rather than a word: the skip-track glyph is read everywhere and needs no
    /// share of a row the Start button should keep.
    private func skipButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "forward.end.fill")
                .font(.headline)
                .padding()
                // Square at the default text size, where the glyph is narrower
                // than the Start button's line is tall.
                .frame(minWidth: 54)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.tint)
        }
        .accessibilityLabel(L("Skip Exercise"))
        .explain(L("Leaves this exercise unsung and moves on to the next one in the queue."))
    }

    /// Who made this community exercise, under the title, as the way to the rest
    /// of what they have published: the same profile screen a tap on their name
    /// in the Community list opens. The name is tinted to say it leads somewhere
    /// while the label stays with the difficulty row's grey.
    ///
    /// A tap gesture rather than a `Button`, so the row keeps the plain look of
    /// a byline and the hold that puts up its explanation isn't also a press of
    /// a control — the pairing the difficulty row below uses, and for the same
    /// reason: `explain` rebuilds the row when it recognises a hold, cancelling
    /// the touch in flight so the release doesn't land here as a tap.
    private func uploaderRow(_ open: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text("Created by:")
            Text(uploaderName)
                .foregroundStyle(.tint)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        // The line answers the tap, not the width it is laid out in: a tap out
        // there is aimed at nothing.
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .explain(L("Who made this exercise. Tap to open their profile and see their other public exercises."))
    }

    /// The exercise's difficulty as five stars, on the trailing edge so it sits
    /// opposite the title instead of reading as a second line of it.
    ///
    /// The stars count how *hard* the exercise is, while the server's number
    /// counts how well it goes — the higher it is, the easier the exercise — so
    /// the fill runs the other way: an exercise everyone scores 80 on is one
    /// star, and one nobody manages a note of is five.
    private func difficultyRow(_ difficulty: Double) -> some View {
        let hardness = 1 - difficulty / 100
        return HStack(spacing: 6) {
            Text("Difficulty:")
            DifficultyStars(fraction: hardness)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        // The label and the stars answer the tap, and not the empty width the
        // frame below stretches them across — a bubble pointing at nothing is
        // the wrong answer to a tap out there.
        .contentShape(Rectangle())
        .onTapGesture { showDifficultyNumber = true }
        // Attached before the widening frame so the bubble's arrow finds the
        // stars rather than the middle of the screen. A hold gets the row's
        // explanation instead: `explain` rebuilds the row when it recognises
        // one, which cancels the touch in flight so the release doesn't also
        // land here as a tap.
        .popover(isPresented: $showDifficultyNumber) {
            DifficultyNumberBubble(
                rating: Int((min(max(hardness, 0), 1) * 100).rounded()),
                tint: DifficultyStars.tint(for: hardness, colorScheme: colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Difficulty:")
        .accessibilityValue(Text(hardness, format: .percent.precision(.fractionLength(0))))
        .explain(L("How hard this exercise turns out to be, worked out from everyone's scores on it. Five stars is the hardest."))
    }

    /// Heart plus the exercise's like count. Tapping toggles this user's like:
    /// CommunitySync updates the count on the server and remembers the like in
    /// the profile, so it survives a reinstall.
    private func likeButton(for likeID: UUID) -> some View {
        let isLiked = counts.likedExerciseIDs.contains(likeID)
        let count = counts.likeCounts[likeID] ?? 0
        return Button {
            withAnimation(.snappy) { community.toggleLike(for: likeID) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .symbolEffect(.bounce, value: isLiked)
                Text(count.formatted())
                    .contentTransition(.numericText())
                    .monospacedDigit()
            }
            .font(.headline)
            .foregroundStyle(isLiked ? Color.red : Color.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.fill.tertiary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLiked ? L("Unlike") : L("Like"))
        .accessibilityValue(L("%d likes", count))
        .explain(L("Tap the heart to like this exercise. The number is how many users have."))
    }

    /// How often this exercise has been downloaded — the same number the
    /// Community tab can sort by. Display only, so it sits plain on the leading
    /// edge with no capsule behind it: a background would read as a button.
    /// The count goes up when the Download button below is used.
    private func downloadCount(for likeID: UUID) -> some View {
        let count = counts.downloadCounts[likeID] ?? 0
        return HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle")
            Text(count.formatted())
                .contentTransition(.numericText())
                .monospacedDigit()
        }
        .font(.headline)
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloads")
        .accessibilityValue(count.formatted())
        .explain(L("How many times this exercise has been downloaded."))
    }

    /// The same score-history chart shown on the result screen, on the same
    /// surface so the two read alike. Inside a ScrollView the chart would settle
    /// at its minimum height, so the plot is given the height it has on the
    /// result screen instead of being left to shrink.
    private var scoreChartCard: some View {
        ScoreHistoryChart(entries: ScoreHistory.entries(for: exercise.id),
                          tint: .accentColor)
            .frame(height: chartHeight)
            .padding()
            .frame(maxWidth: .infinity)
            .background(ScoreHistoryChart.surface(colorScheme),
                        in: RoundedRectangle(cornerRadius: 14))
    }
}

/// What a tap on the difficulty row puts up: the number the stars were drawn
/// from, out of 100. It counts the way the stars do rather than the way the
/// server does — the server says how well this exercise's singers score, and
/// the rating is that taken from 100, so an exercise everyone scores 40 on is
/// 60/100 hard. Nothing but the number: the row's press-and-hold explanation
/// is where the sentence about it lives.
private struct DifficultyNumberBubble: View {
    /// How hard the exercise is, 0-100.
    let rating: Int
    /// The colour the stars came out, worked out by the row rather than here: a
    /// presentation doesn't reliably inherit the app's chosen appearance, and a
    /// number in one appearance beside stars in the other reads as a different
    /// rating rather than the same one spelled out.
    let tint: Color

    var body: some View {
        // Not a localised string: digits and a slash, written the same way in
        // every language the app speaks.
        Text(verbatim: "\(rating)/100")
            .font(.title2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            // Sized to the number and kept a bubble on iPhone, the way the
            // press-and-hold help is.
            .presentationSizing(.fitted)
            .presentationCompactAdaptation(.popover)
    }
}

/// Five stars filled left to right, `fraction` of the way along (0-1). The star
/// the fill lands in is filled across its own width rather than snapped to a
/// whole or a half, so a fraction of 0.21 shows one full star and a sliver of
/// the second: the same colour used for the unfilled stars underneath, painted
/// on top in `tint` through a mask that stops partway.
///
/// Drawn at the ambient font size, so where they are used decides how big they
/// come out. Two things are rated this way — how hard an exercise is here, and
/// how hard an exercise the singer can handle on the Home tab's recommendation
/// card — and they are the same scale, so they are the same stars.
struct DifficultyStars: View {
    let fraction: Double

    @Environment(\.colorScheme) private var colorScheme

    private static let count = 5

    /// Green for an easy exercise through yellow at half way to red for a hard
    /// one — every star the same colour, the one the whole rating is worth. The
    /// ramp is the score screen's, run backwards (there a high number is good,
    /// here a full row of stars is the hard one), and takes the same deeper
    /// brightness in light mode, where the bright end washes out.
    static func tint(for fraction: Double, colorScheme: ColorScheme) -> Color {
        let hue = (1 - min(max(fraction, 0), 1)) * 0.33
        return colorScheme == .dark
            ? Color(hue: hue, saturation: 0.85, brightness: 0.95)
            : Color(hue: hue, saturation: 0.95, brightness: 0.68)
    }

    private var tint: Color { Self.tint(for: fraction, colorScheme: colorScheme) }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.count, id: \.self) { index in
                // How much of *this* star is filled: 1 for every star the fill
                // is past, 0 for every star it hasn't reached.
                let fill = fraction * Double(Self.count) - Double(index)
                star(fill: min(max(fill, 0), 1))
            }
        }
    }

    private func star(fill: Double) -> some View {
        Image(systemName: "star.fill")
            .foregroundStyle(Color.gray.opacity(0.3))
            .overlay(alignment: .leading) {
                Image(systemName: "star.fill")
                    .foregroundStyle(tint)
                    // The overlay is laid out at the grey star's size, so the
                    // reader below measures that one star and nothing else.
                    .mask(alignment: .leading) {
                        GeometryReader { geo in
                            Color.black.frame(width: geo.size.width * fill)
                        }
                    }
            }
    }
}
