// rater rate <BundledExercises.json>
//     One JSON object per exercise, in bundle order: its id, name, the app's
//     difficulty estimate (ExerciseDifficulty.rating) and the score that
//     estimate is posted as (ExerciseDifficulty.expectedScore).
//
// rater halfwidths <text>...
//     A JSON object of each text's half-width in beats, as the MIDI editor
//     centres a label by (midiTextHalfWidth).

import Foundation

let arguments = CommandLine.arguments.dropFirst()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func printJSON(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

switch arguments.first {
case "rate":
    guard let path = arguments.dropFirst().first else { fail("usage: rater rate <bundle.json>") }
    guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
    let bundle: ExerciseBundle
    do {
        bundle = try JSONDecoder().decode(ExerciseBundle.self, from: data)
    } catch {
        fail("can't decode \(path): \(error)")
    }
    for exercise in bundle.exercises {
        let pattern = bundle.midi[exercise.id.uuidString] ?? []
        let rating = ExerciseDifficulty.rating(for: exercise, pattern: pattern)
        var row: [String: Any] = [
            "id": exercise.id.uuidString,
            "name": exercise.name,
            "category": exercise.category,
        ]
        if let rating {
            row["rating"] = rating
            row["score"] = ExerciseDifficulty.expectedScore(forRating: rating)
        }
        printJSON(row)
    }
case "halfwidths":
    var widths: [String: Double] = [:]
    for text in arguments.dropFirst() { widths[text] = midiTextHalfWidth(text) }
    printJSON(widths)
default:
    fail("usage: rater rate <bundle.json> | rater halfwidths <text>...")
}
