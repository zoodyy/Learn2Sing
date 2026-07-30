import SwiftUI

/// Shown right after an exercise is tapped, before playback begins. Presents the
/// exercise's description so the singer knows what to do, with a button to start.
/// When opened from the Community tab a like button sits under the title and a
/// Download button appears above Start, copying the exercise into the user's own
/// library (the Exercises tab).
struct ExerciseIntroView: View {
    let exercise: Exercise
    /// Public id of the community exercise the like button acts on; nil (every
    /// tab but Community) hides the button.
    var likeID: UUID? = nil
    var onDownload: (() -> Void)? = nil
    let onStart: () -> Void

    /// Source of the like count and of whether this user already liked it; both
    /// change as soon as the heart is tapped.
    @ObservedObject private var community = CommunitySync.shared

    /// Flips after a download so the button confirms instead of copying again.
    @State private var isDownloaded = false

    /// Toggled by the "See Score" toolbar button to show/hide the score-history
    /// chart under the description.
    @State private var showScore = false

    private var trimmedDetails: String {
        exercise.details.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(exercise.name)
                        .font(.largeTitle.weight(.bold))

                    if let likeID {
                        likeButton(for: likeID)
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

            if let onDownload {
                Button {
                    onDownload()
                    withAnimation { isDownloaded = true }
                } label: {
                    Label(isDownloaded ? "Added to Exercises" : "Download",
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
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { showScore.toggle() }
                } label: {
                    Label("See Score", systemImage: "chart.line.uptrend.xyaxis")
                }
            }
        }
    }

    /// Heart plus the exercise's like count. Tapping toggles this user's like:
    /// CommunitySync updates the count on the server and remembers the like in
    /// the profile, so it survives a reinstall.
    private func likeButton(for likeID: UUID) -> some View {
        let isLiked = community.likedExerciseIDs.contains(likeID)
        let count = community.likeCounts[likeID] ?? 0
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
        .accessibilityLabel(isLiked ? "Unlike" : "Like")
        .accessibilityValue("\(count) likes")
    }

    /// The same score-history chart shown on the result screen, kept on a black
    /// card with a dark colour scheme because the chart draws its axes in white.
    private var scoreChartCard: some View {
        ScoreHistoryChart(entries: ScoreHistory.entries(for: exercise.id),
                          tint: .accentColor)
            .environment(\.colorScheme, .dark)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
    }
}
