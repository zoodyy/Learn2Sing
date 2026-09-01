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

/// Five slides, none of them compulsory: measure the singer's vocal range, set how
/// long a day they mean to practise, pick light or dark, say where exercises come
/// from, and point at the press-and-hold help. Each one either sets its setting for
/// real — the range test is the very screen Settings ▸ Voice opens — or moves on
/// leaving it alone.
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

    /// Which way the tutorial was last moved, so a slide travels with the finger
    /// instead of always the one way the buttons send it.
    @State private var isMovingBack = false

    /// Drives the "you can watch it again" note the ✕ puts up.
    @State private var isLeaving = false

    /// How long a day the singer has dialled in, in minutes. Held here and written
    /// to the setting only when they move on with "Continue", so skipping the slide
    /// leaves the setting exactly as it was.
    @State private var minutes = RecommendedExercises.minutes

    private static let slideCount = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                switch slide {
                case 0: rangeSlide.transition(pageTransition)
                case 1: minutesSlide.transition(pageTransition)
                case 2: themeSlide.transition(pageTransition)
                case 3: exercisesSlide.transition(pageTransition)
                default: holdSlide.transition(pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Without a shape of its own a slide is only touchable where it has
            // drawn something, which would leave the swipe dead in the space
            // around the words.
            .contentShape(Rectangle())
            .simultaneousGesture(pageSwipe)
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

    /// Slides travel the way the tutorial is moving: forwards they come in from the
    /// trailing edge and leave towards the leading one, backwards the other way
    /// about, so a swipe back looks like the swipe that led there, undone.
    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: isMovingBack ? .leading : .trailing).combined(with: .opacity),
            removal: .move(edge: isMovingBack ? .trailing : .leading).combined(with: .opacity))
    }

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
                    keepMinutes()
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
        // Nothing to keep or skip on the two slides that only tell the singer
        // something, so they carry the one button that moves on.
        case 3:
            Button(action: advance) { primaryLabel(Text("Continue")) }
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

    /// How far a sideways drag has to travel before it turns the page.
    private static let swipeDistance: CGFloat = 50

    /// Swiping the slide turns the page, back as well as forwards — the buttons
    /// only ever go one way. Simultaneous so a slide too tall for the screen still
    /// scrolls, and only a clearly sideways drag counts, so scrolling one down
    /// can't turn the page under the finger.
    private var pageSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { drag in
                let sideways = drag.translation.width
                guard abs(sideways) >= Self.swipeDistance,
                      abs(drag.translation.height) < abs(sideways) else { return }
                if sideways < 0 { swipeForward() } else { goBack() }
            }
    }

    /// A swipe forwards stands in for the slide's filled button rather than its
    /// "Skip": the number the singer has dialled in is the one in front of them, so
    /// it is kept, exactly as "Continue" keeps it. The last slide holds — the
    /// tutorial is left by "Done" or the ✕, not by swiping off the end of it.
    private func swipeForward() {
        guard slide < Self.slideCount - 1 else { return }
        if slide == 1 { keepMinutes() }
        advance()
    }

    private func advance() { move(to: slide + 1) }

    private func goBack() { move(to: slide - 1) }

    /// Moves to the slide either side of this one, if there is one, and sends both
    /// slides the way the move goes.
    private func move(to next: Int) {
        guard (0..<Self.slideCount).contains(next) else { return }
        let back = next < slide
        guard back != isMovingBack else {
            slide = next
            return
        }
        // A view keeps the transition it was last drawn with, so the slide on screen
        // has to be redrawn with the new direction before the change that takes it
        // off: setting both at once leaves it the way the move before this one went,
        // and the two slides cross over each other on their way past.
        isMovingBack = back
        DispatchQueue.main.async { slide = next }
    }

    /// Writes the practice-time slide's setting, which is done only when that
    /// slide is left forwards deliberately — skipping it leaves the setting alone.
    private func keepMinutes() {
        UserDefaults.standard.set(minutes, forKey: RecommendedExercises.minutesKey)
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

    // MARK: - Practice a day

    /// The practice time as it is written on this slide, in the app's own
    /// language — which a presentation doesn't inherit, so it is handed over by
    /// hand here as everywhere else in this file.
    private var minutesText: String {
        RecommendedExercises.formatted(minutes: minutes, locale: appLanguage.language.locale)
    }

    private var minutesSlide: some View {
        slideBody {
            slideHeader(icon: "calendar",
                        title: Text("Practice a day"),
                        subtitle: Text("How long do you want to sing?"))

            HStack(spacing: 24) {
                minutesStep("minus", enabled: minutes > RecommendedExercises.minutesRange.lowerBound) {
                    minutes -= RecommendedExercises.minutesStep
                }
                Text(minutesText)
                    .font(.system(size: 62, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    // "1 hr 30 min" is a good deal wider than "10 min", so the
                    // time takes everything the buttons leave and shrinks inside
                    // it: the ± stay put from one press to the next instead of
                    // shuffling sideways with the width of what is between them.
                    .minimumScaleFactor(0.4)
                    .frame(maxWidth: .infinity)
                minutesStep("plus", enabled: minutes < RecommendedExercises.minutesRange.upperBound) {
                    minutes += RecommendedExercises.minutesStep
                }
            }
            // One adjustable element rather than two unlabelled buttons, which is
            // what VoiceOver makes of a pair of bare symbols.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Practice a day")
            .accessibilityValue(Text(minutesText))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    if minutes < RecommendedExercises.minutesRange.upperBound {
                        minutes += RecommendedExercises.minutesStep
                    }
                case .decrement:
                    if minutes > RecommendedExercises.minutesRange.lowerBound {
                        minutes -= RecommendedExercises.minutesStep
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    private func minutesStep(_ symbol: String, enabled: Bool,
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

    // MARK: - Press and hold

    /// The last slide, and the shortest: everything the app doesn't have room to
    /// explain explains itself under a hold — the `settingHelp(_:)` popovers — so
    /// the rest of it needn't be described here.
    private var holdSlide: some View {
        slideBody {
            slideHeader(icon: "hand.tap",
                        title: Text("Stuck?"),
                        subtitle: Text("Press and hold anything to see what it does."))
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
