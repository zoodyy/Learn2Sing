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
    /// How hard the exercise is, on a 0-100 scale, drawn as five stars. nil
    /// leaves the stars off, for exercises that aren't rated — the audio delay
    /// test's stand-in among them.
    ///
    /// Placeholder: the server doesn't send a difficulty yet. When it does,
    /// hand the exercise's own value in here and the rest follows from it.
    var difficulty: Double? = 62
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

    /// Flips after a download so the button confirms instead of copying again.
    @State private var isDownloaded = false

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
    private func difficultyRow(_ difficulty: Double) -> some View {
        HStack(spacing: 6) {
            Text("Difficulty:")
            DifficultyStars(fraction: difficulty / 100)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Difficulty:")
        .accessibilityValue(Text(difficulty / 100, format: .percent.precision(.fractionLength(0))))
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
/// whole or a half, so a difficulty of 21 shows one full star and a sliver of
/// the second: the same colour used for the unfilled stars underneath, painted
/// on top in the accent colour through a mask that stops partway.
private struct DifficultyStars: View {
    let fraction: Double

    private static let count = 5

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
                    .foregroundStyle(Color.accentColor)
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
