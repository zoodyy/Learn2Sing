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
    var onDownload: (() -> Void)? = nil
    /// Opens this exercise's settings from the toolbar. nil (Community, where the
    /// exercise isn't in the user's library yet) hides the button.
    var onSettings: (() -> Void)? = nil
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

                    if let difficulty {
                        difficultyRow(difficulty)
                    }

                    if trimmedDetails.isEmpty {
                        Text("No description.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(trimmedDetails)
                            .font(.body)
                            .foregroundStyle(.secondary)
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
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Button(action: onStart) {
                Text("Start")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
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
            }
            // Same screen the list's "Settings" swipe action opens, and the same
            // symbol, so the two read as one action.
            if let onSettings {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSettings) {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                }
            }
        }
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
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Difficulty:")
        .accessibilityValue(Text(hardness, format: .percent.precision(.fractionLength(0))))
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
    private var tint: Color {
        let hue = (1 - min(max(fraction, 0), 1)) * 0.33
        return colorScheme == .dark
            ? Color(hue: hue, saturation: 0.85, brightness: 0.95)
            : Color(hue: hue, saturation: 0.95, brightness: 0.68)
    }

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
