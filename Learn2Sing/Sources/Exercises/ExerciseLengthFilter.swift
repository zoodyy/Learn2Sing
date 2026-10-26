import SwiftUI
import UIKit

/// Lengths as the Exercises tab writes them: the time an exercise's intro
/// screen shows under its title (see `ExerciseStore.shownLength(of:)`), which
/// is what the tab's "Longest" order and its length filter go by.
enum ExerciseLength {
    /// `seconds` the way the intro screen writes it, "1 min 15 sec": with its
    /// seconds, since one exercise is short enough that "1 min" would hide most
    /// of a minute.
    static func text(_ seconds: Int, locale: Locale) -> String {
        Duration.seconds(seconds).formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds],
                                      width: .condensedAbbreviated)
                .locale(locale))
    }

    /// A range of lengths, both ends written as above: what the filter menu
    /// shows under "Length" while the filter narrows the list.
    static func text(_ range: ClosedRange<Int>, locale: Locale) -> String {
        "\(text(range.lowerBound, locale: locale)) – \(text(range.upperBound, locale: locale))"
    }
}

/// The sheet the Exercises tab's filter menu opens from "Length": the shortest
/// and the longest an exercise may be and stay listed, each on a wheel of
/// minutes beside a wheel of seconds. To the second, and still no more than two
/// flicks from any length, which a stepper counting seconds one tap at a time
/// couldn't be.
///
/// Changes reach the list underneath as each wheel comes to rest, so there is
/// nothing to confirm. A range that keeps every exercise in, the one the wheels
/// start out on, is no filter at all: the filter is off until a wheel cuts
/// something out of it, and off again once both are turned back that far.
struct ExerciseLengthSheet: View {
    /// The tab's length filter, nil while it lets every length through.
    @Binding var range: ClosedRange<Int>?
    /// The shortest and the longest exercise in the library, which the wheels
    /// start out on while the filter is off.
    let span: ClosedRange<Int>
    /// How many exercises the list shows right now, with this range, the other
    /// filters and the search all applied.
    let matchCount: Int

    /// A presentation takes neither the language nor the appearance from the
    /// screen it is presented over (see IntroTutorialView), so both are read
    /// here and handed on.
    @ObservedObject private var appLanguage = LanguageManager.shared
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    @Environment(\.dismiss) private var dismiss

    /// What the wheels are turned to. Kept apart from `range`, which goes back
    /// to nil once they cover every exercise: read from there, a wheel turned
    /// past the shortest exercise would spring back to it.
    @State private var shortest: Int
    @State private var longest: Int

    init(range: Binding<ClosedRange<Int>?>, span: ClosedRange<Int>, matchCount: Int) {
        _range = range
        self.span = span
        self.matchCount = matchCount
        let start = range.wrappedValue ?? span
        _shortest = State(initialValue: start.lowerBound)
        _longest = State(initialValue: start.upperBound)
    }

    /// The most minutes the minutes wheels go up to: as far as the longest
    /// exercise reaches, or the range set before it was deleted.
    private var maxMinutes: Int {
        max(1, max(span.upperBound, longest) / 60)
    }

    var body: some View {
        NavigationStack {
            Form {
                // One section, so the count still fits under the wheels at
                // the sheet's half height, where the list above it can be
                // seen changing too.
                Section {
                    boundRow(L("At least"), seconds: atLeast,
                             help: L("Exercises shorter than this are hidden. An exercise's length is the time shown under its name when you open it."))
                    boundRow(L("At most"), seconds: atMost,
                             help: L("Exercises longer than this are hidden. Turning it below “At least” moves that down too."))
                    LabeledContent("Matching exercises") {
                        Text(matchCount.formatted())
                            .monospacedDigit()
                    }
                    .settingHelp(L("How many exercises the list shows with these lengths, your other filters and the search."))
                }
            }
            .navigationTitle(L("Length"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        reset()
                    } label: {
                        Text("Reset")
                            .toolbarHitArea()
                    }
                    .disabled(shortest == span.lowerBound && longest == span.upperBound)
                    .explain(L("Turns the wheels back to your shortest and your longest exercise, so no exercise is hidden for its length."))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .toolbarHitArea()
                    }
                    .fontWeight(.semibold)
                    .explain(L("Closes this. The list already shows only the exercises in the range you set."))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .environment(\.locale, appLanguage.language.locale)
        .preferredColorScheme((AppTheme(rawValue: themeRaw) ?? .system).colorScheme)
    }

    /// One end of the range: its name, and the wheels it is set on. The hold
    /// explains the name rather than the row, whose wheels' own touch is their
    /// turning: a finger resting on one before it moves would put the bubble up
    /// and stop the wheel.
    private func boundRow(_ title: String, seconds: Binding<Int>, help: String) -> some View {
        HStack {
            Text(verbatim: title)
                .explain(help)
            Spacer(minLength: 8)
            // Tall enough for a row either side of the one picked, which is
            // what shows it turns.
            LengthWheel(seconds: seconds, maxMinutes: maxMinutes,
                        locale: appLanguage.language.locale, title: title)
                .frame(width: 220, height: 110)
        }
    }

    /// "At least", as the wheels set it: "At most" is pushed along ahead of it
    /// rather than left behind, which would leave a range nothing fits in.
    private var atLeast: Binding<Int> {
        Binding(get: { shortest }, set: { seconds in
            shortest = seconds
            longest = max(longest, seconds)
            apply()
        })
    }

    /// "At most", the same way round.
    private var atMost: Binding<Int> {
        Binding(get: { longest }, set: { seconds in
            longest = seconds
            shortest = min(shortest, seconds)
            apply()
        })
    }

    /// Hand the wheels' range to the list, or no filter at all when it keeps
    /// every exercise in.
    private func apply() {
        range = shortest <= span.lowerBound && longest >= span.upperBound
            ? nil : shortest...longest
    }

    private func reset() {
        shortest = span.lowerBound
        longest = span.upperBound
        apply()
    }
}

/// A wheel of minutes beside a wheel of seconds, the way the Clock app's timer
/// sets a length. UIKit's rather than two SwiftUI wheels side by side, which
/// take each other's touches: one picker with a component for each keeps them
/// apart.
private struct LengthWheel: UIViewRepresentable {
    @Binding var seconds: Int
    /// The last row of the minutes wheel.
    let maxMinutes: Int
    let locale: Locale
    /// The end of the range this wheel sets, for VoiceOver.
    let title: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIPickerView {
        let picker = UIPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        // Sized by the frame SwiftUI gives it rather than by its own idea of a
        // picker's width.
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        context.coordinator.show(seconds, in: picker, animated: false)
        return picker
    }

    func updateUIView(_ picker: UIPickerView, context: Context) {
        let coordinator = context.coordinator
        let rowsChanged = coordinator.wheel.maxMinutes != maxMinutes
            || coordinator.wheel.locale != locale
        coordinator.wheel = self
        if rowsChanged { picker.reloadAllComponents() }
        // Turns this wheel when the other end of the range pushes it along;
        // one the user just turned is already there.
        coordinator.show(seconds, in: picker, animated: true)
    }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewAccessibilityDelegate {
        var wheel: LengthWheel

        init(_ wheel: LengthWheel) {
            self.wheel = wheel
        }

        func show(_ seconds: Int, in picker: UIPickerView, animated: Bool) {
            let minutes = min(seconds / 60, wheel.maxMinutes)
            if picker.selectedRow(inComponent: 0) != minutes {
                picker.selectRow(minutes, inComponent: 0, animated: animated)
            }
            if picker.selectedRow(inComponent: 1) != seconds % 60 {
                picker.selectRow(seconds % 60, inComponent: 1, animated: animated)
            }
        }

        func numberOfComponents(in pickerView: UIPickerView) -> Int { 2 }

        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
            component == 0 ? wheel.maxMinutes + 1 : 60
        }

        /// "2 min" and "15 sec", in the units the intro screen writes a length
        /// in. Zero is written out too, which a length leaves off.
        private func title(forRow row: Int, inComponent component: Int) -> String {
            Duration.seconds(component == 0 ? row * 60 : row).formatted(
                Duration.UnitsFormatStyle(allowedUnits: [component == 0 ? .minutes : .seconds],
                                          width: .condensedAbbreviated,
                                          zeroValueUnits: .show(length: 1))
                    .locale(wheel.locale))
        }

        /// A label that shrinks to its column rather than cutting the unit
        /// off, which a plain title does in the wider languages ("28 Sek.").
        func pickerView(_ pickerView: UIPickerView, viewForRow row: Int,
                        forComponent component: Int, reusing view: UIView?) -> UIView {
            let label = view as? UILabel ?? UILabel()
            label.font = .systemFont(ofSize: 22)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.text = title(forRow: row, inComponent: component)
            return label
        }

        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            wheel.seconds = pickerView.selectedRow(inComponent: 0) * 60
                + pickerView.selectedRow(inComponent: 1)
        }

        func pickerView(_ pickerView: UIPickerView, accessibilityLabelForComponent component: Int) -> String? {
            wheel.title
        }
    }
}
