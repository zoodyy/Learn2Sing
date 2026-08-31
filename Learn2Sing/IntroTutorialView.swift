//
//  IntroTutorialView.swift
//  Learn2Sing
//
//  The short introduction shown the first time the app is opened, and again
//  whenever it is asked for from Settings ▸ Tutorial.
//

import SwiftUI
import Combine

/// Whether the introduction is on screen, and the flag that decides whether it
/// opens itself at launch. A singleton because two places ask for it: the root
/// view on the first launch, and the Settings row that replays it.
@MainActor
final class IntroTutorial: ObservableObject {
    static let shared = IntroTutorial()

    /// Set once the tutorial has been left, however it is left — every slide is
    /// optional, so reaching the ✕ counts as much as reaching the end.
    ///
    /// Kept in UserDefaults and deliberately out of `UserSettings`: it records what
    /// has happened on *this* install rather than something the singer chose, so a
    /// reinstall starts the app over from the beginning, introduction included.
    static let seenKey = "didShowIntroTutorial"

    @Published var isPresented = false

    private init() {}

    /// Opens the introduction on the first launch after an install, and never again
    /// unless the user asks for it.
    ///
    /// It goes up straight away rather than waiting on ProfileSync's restore: for a
    /// new singer — who this is for — there is no profile to fetch, and the first
    /// thing the tutorial writes is a vocal range that takes some seconds of singing
    /// to measure, by which time a restore on a returning device has long landed.
    func presentIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.seenKey) else { return }
        isPresented = true
    }

    /// Settings ▸ Tutorial: plays it again, whenever it is asked for.
    func present() { isPresented = true }

    /// Closes it, and remembers it has been shown.
    func finish() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        isPresented = false
    }
}

/// Four slides, none of them compulsory: measure the singer's vocal range, set how
/// many exercises a day to suggest, pick light or dark, and say where exercises come
/// from. Each one either sets its setting for real — the range test is the very
/// screen Settings ▸ Voice opens — or moves on leaving it alone.
struct IntroTutorialView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    /// The playback screen has a standard look per appearance: the theme slide draws
    /// both of them, and switches to the one that is tapped.
    @EnvironmentObject private var templates: VisualTemplateStore

    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

    /// Which slide is on screen.
    @State private var slide = 0

    /// Drives the "you can watch it again" note the ✕ puts up.
    @State private var isLeaving = false

    /// How many exercises a day the singer has dialled in. Held here and written to
    /// the setting only when they move on with "Continue", so skipping the slide
    /// leaves the setting exactly as it was.
    @State private var amount = UserDefaults.standard
        .object(forKey: RecommendedExercises.amountKey) as? Int ?? RecommendedExercises.defaultAmount

    private static let slideCount = 4

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                switch slide {
                case 0: rangeSlide.transition(Self.pageTransition)
                case 1: amountSlide.transition(Self.pageTransition)
                case 2: themeSlide.transition(Self.pageTransition)
                default: exercisesSlide.transition(Self.pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .animation(.snappy(duration: 0.25), value: slide)
        // The language and the appearance the root view sets, asserted again here.
        // This is presented over that view rather than inside it, and a presentation
        // takes neither from the view it is presented from: without the locale every
        // `Text("…")` below would resolve in English however the app is set, and
        // without the colour scheme the theme slide couldn't show what it is picking.
        .environment(\.locale, appLanguage.language.locale)
        .preferredColorScheme((AppTheme(rawValue: themeRaw) ?? .system).colorScheme)
        // `L(_:)` inside the alert, per the localization notes: its buttons and its
        // message are built in the alert's own environment, which the locale set
        // above doesn't reach — only the title resolves against this view's.
        .alert("Tutorial", isPresented: $isLeaving) {
            Button(L("OK")) { IntroTutorial.shared.finish() }
        } message: {
            Text(L("You can watch it again in Settings."))
        }
    }

    /// Slides come in from the trailing edge and leave towards the leading one; the
    /// tutorial only ever moves forwards.
    private static let pageTransition = AnyTransition.asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity))

    // MARK: - Chrome

    /// The ✕ on the leading edge, with the progress dots centred across the row.
    private var header: some View {
        HStack {
            Button { isLeaving = true } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary, in: Circle())
            }
            .accessibilityLabel("Close")

            Spacer()
        }
        .overlay {
            HStack(spacing: 7) {
                ForEach(0..<Self.slideCount, id: \.self) { index in
                    Circle()
                        .fill(index == slide ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// "Skip" leaves the slide's setting alone; the filled button beside it keeps
    /// whatever was chosen on the slide. The range test carries its own buttons, so
    /// that slide is the one with nothing but "Skip".
    @ViewBuilder private var footer: some View {
        switch slide {
        case 0:
            Button(action: advance) {
                skipLabel(Text("Skip"))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
            }
        case 1:
            HStack(spacing: 12) {
                Button(action: advance) { skipLabel(Text("Skip")).padding() }
                Button {
                    UserDefaults.standard.set(amount, forKey: RecommendedExercises.amountKey)
                    advance()
                } label: {
                    primaryLabel(Text("Continue"))
                }
            }
        case 2:
            HStack(spacing: 12) {
                Button(action: advance) { skipLabel(Text("Skip")).padding() }
                Button(action: advance) { primaryLabel(Text("Continue")) }
            }
        default:
            Button { IntroTutorial.shared.finish() } label: { primaryLabel(Text("Done")) }
        }
    }

    private func primaryLabel(_ title: Text) -> some View {
        title
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(.tint, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
    }

    private func skipLabel(_ title: Text) -> some View {
        title
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    private func advance() {
        slide = min(slide + 1, Self.slideCount - 1)
    }

    /// A slide's content, centred in what the header and the footer leave it — and
    /// scrollable on the short screens, and at the text sizes, where it doesn't fit.
    private func slideBody<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // Built once here rather than inside the reader, whose closure escapes.
        let stack = VStack(spacing: 26) { content() }.padding()
        return GeometryReader { geo in
            ScrollView {
                stack.frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
    }

    /// The title and one-line explanation every slide but the range test opens with.
    private func slideHeader(icon: String, title: Text, subtitle: Text) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            title
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            subtitle
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Vocal range

    /// The vocal-range test itself, not a picture of it: the same screen Settings ▸
    /// Voice pushes, saving the measured notes as the singer's custom range. Saving
    /// (or giving up on) it moves the tutorial on.
    private var rangeSlide: some View {
        VocalRangeTestView(onFinish: advance)
    }

    // MARK: - Exercises a day

    private var amountSlide: some View {
        slideBody {
            slideHeader(icon: "calendar",
                        title: Text("Exercises a day"),
                        subtitle: Text("How many should we suggest?"))

            HStack(spacing: 24) {
                amountStep("minus", enabled: amount > RecommendedExercises.amountRange.lowerBound) {
                    amount -= 1
                }
                Text(verbatim: "\(amount)")
                    .font(.system(size: 76, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .frame(minWidth: 110)
                amountStep("plus", enabled: amount < RecommendedExercises.amountRange.upperBound) {
                    amount += 1
                }
            }
            // One adjustable element rather than two unlabelled buttons, which is
            // what VoiceOver makes of a pair of bare symbols.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Exercises a day")
            .accessibilityValue(Text(verbatim: "\(amount)"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    if amount < RecommendedExercises.amountRange.upperBound { amount += 1 }
                case .decrement:
                    if amount > RecommendedExercises.amountRange.lowerBound { amount -= 1 }
                @unknown default:
                    break
                }
            }
        }
    }

    private func amountStep(_ symbol: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.title2.weight(.bold))
                .frame(width: 54, height: 54)
                .background(.quaternary, in: Circle())
        }
        .disabled(!enabled)
    }

    // MARK: - Theme

    /// Both standard looks side by side, drawn as playback would draw them. Tapping
    /// one sets the theme — and, where nothing of the user's is lost by it, puts that
    /// appearance's playback look on too, so the tap gives them the picture they
    /// tapped rather than only half of it.
    private var themeSlide: some View {
        slideBody {
            slideHeader(icon: "circle.lefthalf.filled",
                        title: Text("Theme"),
                        subtitle: Text("Pick a look."))

            HStack(spacing: 14) {
                ForEach([AppTheme.light, .dark]) { theme in
                    if let template = templates.standard(for: theme.scheme) {
                        ThemeCard(theme: theme, template: template,
                                  isSelected: themeRaw == theme.rawValue) {
                            choose(theme)
                        }
                    }
                }
            }
        }
    }

    /// The theme change the Visuals screen makes, minus its question: where switching
    /// the playback look would cost the user something it is simply left alone, since
    /// an alert on top of the tutorial is more than this slide is worth.
    private func choose(_ theme: AppTheme) {
        let oldScheme = AppTheme.current.scheme
        themeRaw = theme.rawValue
        let newScheme = theme.scheme
        guard oldScheme != newScheme,
              templates.appearanceChange(from: oldScheme, to: newScheme) == .apply else { return }
        templates.applyStandard(for: newScheme)
    }

    // MARK: - Where exercises come from

    private var exercisesSlide: some View {
        slideBody {
            slideHeader(icon: "music.note.list",
                        title: Text("Exercises"),
                        subtitle: Text("Three ways to fill your library."))

            VStack(alignment: .leading, spacing: 18) {
                infoRow("shippingbox", Text("Sing the exercises the app comes with."))
                infoRow("person.3", Text("Download more from the Community tab."))
                infoRow("square.and.pencil", Text("Write your own, and publish them."))
            }
        }
    }

    private func infoRow(_ symbol: String, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            text
            Spacer(minLength: 0)
        }
    }
}

/// One of the two looks on the theme slide: a still of the playback screen in that
/// appearance, under the name of the theme that puts the app in it. The card itself
/// is drawn in that appearance too, so the pair shows what the whole app looks like
/// either way rather than only the playback canvas.
private struct ThemeCard: View {
    let theme: AppTheme
    let template: VisualTemplate
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                PlaybackLookPreview(template: template)
                    // Roughly a phone's shape, which is what playback fills. Inset
                    // and outlined so it reads as a screen inside the card even in
                    // the light look, whose background is the card's own colour.
                    .aspectRatio(0.62, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary)
                    }

                HStack(spacing: 5) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    }
                    Text(L(theme.rawValue))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(9)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                  lineWidth: isSelected ? 3 : 1)
            }
        }
        // The card previews the appearance it offers, whichever one the app is in
        // while the tutorial is being watched.
        .environment(\.colorScheme, theme.scheme)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A still of the playback screen in a given look, drawn through the renderer
/// playback itself uses so it is the real thing rather than an impression of it.
/// Nothing moves: it is a picture to choose from, so there is no clock behind it
/// and no repetition badge over it.
private struct PlaybackLookPreview: View {
    let template: VisualTemplate

    /// A short rise-and-fall motif, repeated so the scene runs off both edges of the
    /// card instead of ending inside it. Demo content, like the visuals screen's.
    private static let repeats = 4
    private static let span = 4.5
    private static let motif: [(pitch: Int, beat: Double)] =
        [(60, 0), (62, 0.75), (64, 1.5), (62, 2.25), (60, 3)]
    private static let notes: [MIDINote] = (0..<repeats).flatMap { k in
        motif.map { MIDINote(pitch: $0.pitch, beat: Double(k) * span + $0.beat, length: 0.6) }
    }
    /// One syllable per repetition, as the MIDI editor would place it.
    private static let texts: [MIDIText] = (0..<repeats).map {
        MIDIText(text: "La", pitch: 68,
                 beat: midiTextBeat(centring: "La", at: Double($0) * span + 0.3))
    }
    /// Midpoint of the motif, which is where "follow notes vertically" centres it.
    private static let centre = Double(60 + 64) / 2
    /// The beat under the playhead. Far enough in that the singer's line has a
    /// repetition behind it to trail across, and on a note so one is lit up.
    private static let beat = span + 2.25

    var body: some View {
        Canvas { ctx, size in
            let settings = template.settings
            let rowH = size.height / CGFloat(hiPitch - loPitch + 1) * CGFloat(settings.verticalZoom)
            let beatPx = playbackBeatWidth * CGFloat(settings.horizontalZoom)
            let layout = SceneLayout(
                size: size,
                pianoW: settings.showKeyboard ? playbackKeyboardWidth : 0,
                rowH: rowH, beatPx: beatPx, playheadX: size.width / 3,
                centerPitch: settings.followNotesVertically
                    ? Self.centre
                    : Double(hiPitch + loPitch) / 2)
            drawPlaybackScene(
                ctx: ctx, layout: layout, beat: Self.beat,
                notes: Self.notes, texts: Self.texts,
                trailPath: Self.trail(layout: layout, height: size.height, rowH: rowH),
                singerPitch: Self.singerPitch(at: Self.beat), settings: settings,
                repeatLayout: RepeatLayout(span: Self.span, count: Self.repeats))
        }
    }

    /// A gentle bob around the motif, so the singer indicator has somewhere to be.
    private static func singerPitch(at beat: Double) -> Double {
        centre + 1.6 * sin(beat * 1.9)
    }

    /// That curve sampled backwards from the playhead to the left edge of the note
    /// area, so the indicator drags its pitch history behind it as it does live.
    private static func trail(layout: SceneLayout, height: CGFloat, rowH: CGFloat) -> Path {
        let spanPx = max(0, layout.playheadX - layout.pianoW)
        let steps = max(2, Int(spanPx / 2))
        let beats = Double(spanPx / layout.beatPx)
        let dotR = min(rowH * 0.85, 11)
        var path = Path()
        for i in 0...steps {
            let sample = beat - beats * (1 - Double(i) / Double(steps))
            let y = min(max(layout.y(singerPitch(at: sample)), dotR), height - dotR)
            let point = CGPoint(x: layout.x(sample, beat: beat), y: y)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
