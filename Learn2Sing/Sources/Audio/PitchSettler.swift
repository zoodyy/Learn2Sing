import Foundation

/// How the singer's pitch line trades delay against steadiness: the "Pitch detection"
/// setting on Settings ▸ Voice. Every choice runs the same `PitchAnalyzer`; the slower
/// ones hold its answer back a little and let a `PitchSettler` look at what came next
/// before it is shown.
///
/// The look-aheads were chosen by replaying the exported debug recordings and three
/// public singing datasets through all of them (Tools/PitchBench/compare). Past 80 ms,
/// waiting longer stopped paying: the wrong notes at consonants kept falling a little,
/// but the wrong notes elsewhere had stopped falling at 60 ms, and the line began to
/// flatten vibrato.
nonisolated enum PitchDetection: String, CaseIterable, Identifiable {
    /// The analyzer's answer as soon as it has one, about 15 ms behind the voice. Shows
    /// everything the voice does, including the slide a consonant puts at the start and
    /// end of a syllable and the odd wrong reading on a plosive.
    case fastest
    /// 20 ms of look-ahead: enough to drop one-off wrong readings and very short
    /// sounds, and the part of a slide that is visibly still moving when a syllable
    /// starts or stops, while staying close to the fastest line's timing.
    case balanced
    /// 80 ms of look-ahead: enough to see where a syllable settles before its start is
    /// drawn, so the line sits on the note the singer is holding from the first moment
    /// and consonants barely show in it.
    case mostAccurate = "accurate"

    var id: String { rawValue }

    /// UserDefaults key holding the choice's raw value.
    static let storageKey = "pitchDetection"

    /// What the app did before this was a choice, so an install that never touches it
    /// sees the line it always saw.
    static let defaultValue = PitchDetection.fastest

    /// The setting as it currently stands, for the places that read it once rather
    /// than binding to it.
    static var current: PitchDetection {
        UserDefaults.standard.string(forKey: storageKey).flatMap(PitchDetection.init) ?? defaultValue
    }

    /// How far behind the voice this choice holds the line on top of the fastest one.
    var lookAheadSeconds: Double {
        switch self {
        case .fastest:      0
        case .balanced:     0.02
        case .mostAccurate: 0.08
        }
    }

    /// The same in milliseconds, which is what the microphone delay is kept in.
    var extraDelayMs: Double { lookAheadSeconds * 1000 }
}

/// Holds the analyzer's pitch back by a fixed number of analyses and, knowing what came
/// after each one, decides what to draw for it.
///
/// What it takes out is what the analyzer alone can't tell from singing, because it only
/// knows the past:
///
/// - A syllable that starts or stops on a consonant slides into and out of its note: the
///   voice starts a semitone or two off after a "t" or "k" and droops into the next
///   closure. The pitch really does that, but it is not the note being sung. Near either
///   end of a stretch of voice, a pitch still sliding (by a straight line fitted over the
///   analyses around it) is left out, and the rest there is drawn at the note itself.
/// - A sound too short to be a sung note (a click, a plosive's burst) is dropped whole.
/// - A reading much quieter than the voice around it is the tail of a note dying into a
///   consonant, or breath; it is left out.
/// - In the middle of a note, the line may wander `wander` semitones from the note the
///   voice is holding, which is enough for vibrato and a real glide to show and not
///   enough for a single wrong reading (a harmonic taken for the note) to.
///
/// "The note the voice is holding" is a weighted median of the analyses around this one,
/// as far each way as the look-ahead reaches, weighted towards the ones where the pitch
/// holds still and the voice is loud.
///
/// Every threshold was tuned against real recordings (see `PitchDetection`); none of it
/// allocates once set up, and it costs microseconds per analysis.
nonisolated final class PitchSettler {
    // MARK: Tuning, in analyses (5 ms each) and semitones

    /// A reading quieter than this share of the loudest the voice has been over the last
    /// `loudnessSpan` analyses and the look-ahead is not shown.
    private static let quietShare: Float = 0.2
    private static let loudnessSpan = 30
    /// Stretches of voice shorter than this are not shown at all (never more than the
    /// look-ahead can see whole).
    private static let shortestNote = 12
    /// How much steadier readings count for in the note estimate: a reading whose pitch
    /// moves this much per analysis counts e⁻¹ times as much as one that holds still.
    private static let steadySlope = 0.1
    /// How far the line may stray from the note estimate in the middle of a note, and
    /// how close to either end of a stretch of voice it is held to it exactly.
    private static let wander = 0.3
    private static let edgeSpan = 12
    /// Near the ends of a stretch of voice, a pitch moving faster than this per analysis
    /// is a slide, not the note; that far into a stretch at most (or the look-ahead, if
    /// longer), the slide is not shown.
    private static let slideSlope = 0.08
    private static let slideSpan = 12

    // MARK: State

    /// Analyses between hearing a reading and deciding what to draw for it.
    let lookAhead: Int
    private let shortest: Int
    private let slideReach: Int

    /// The last `capacity` readings, by the number of the analysis they came from.
    private static let capacity = 64
    private var pitches = [Double](repeating: .nan, count: capacity)
    private var levels = [Float](repeating: 0, count: capacity)
    private var runStarts = [Int](repeating: 0, count: capacity)
    private var count = 0

    /// The stretch of voice whose start has been drawn past its slide, if any.
    private var settledRun = -1

    // Scratch for one median.
    private var windowPitches: [Double]
    private var windowWeights: [Double]
    private var order: [Int]

    init(lookAhead: Int) {
        self.lookAhead = max(0, min(lookAhead, Self.capacity - Self.loudnessSpan - 4))
        shortest = min(Self.shortestNote, self.lookAhead + 1)
        slideReach = max(Self.slideSpan, self.lookAhead)
        let most = 2 * self.lookAhead + 1
        windowPitches = [Double](repeating: 0, count: most)
        windowWeights = [Double](repeating: 0, count: most)
        order = [Int](repeating: 0, count: most)
    }

    /// Take the reading of the next analysis (nil: nothing sung) and its level, and
    /// return what to draw for the analysis `lookAhead` before it.
    func push(_ pitch: Double?, level: Float) -> Double? {
        let i = count
        let slot = i & (Self.capacity - 1)
        pitches[slot] = pitch ?? .nan
        levels[slot] = level
        if pitch != nil {
            runStarts[slot] = i > 0 && !pitches[(i - 1) & (Self.capacity - 1)].isNaN ? runStarts[(i - 1) & (Self.capacity - 1)] : i
        }
        count += 1
        guard lookAhead > 0 else { return pitch }
        let j = i - lookAhead
        guard j >= 0 else { return nil }
        return settle(j, knownUpTo: i)
    }

    // MARK: Deciding

    private func p(_ k: Int) -> Double { pitches[k & (Self.capacity - 1)] }
    private func level(_ k: Int) -> Float { levels[k & (Self.capacity - 1)] }

    private func settle(_ j: Int, knownUpTo i: Int) -> Double? {
        let value = p(j)
        guard !value.isNaN else { return nil }
        let start = runStarts[j & (Self.capacity - 1)]
        let intoRun = j - start
        // Where the stretch ends, if that is known yet, and its last reading known so far.
        var end: Int? = nil
        for k in (j + 1)...i where p(k).isNaN { end = k; break }
        let last = (end ?? i + 1) - 1

        // Still sliding in at the start of the stretch? Decided for every reading in turn
        // until one isn't, whatever else hides them.
        var slidingIn = false
        if settledRun != start {
            if intoRun < slideReach && slope(from: max(start, j - 2), to: min(last, j + lookAhead)) > Self.slideSlope {
                slidingIn = true
            } else {
                settledRun = start
            }
        }

        if let end, end - start < shortest { return nil }
        if slidingIn { return nil }

        // Too quiet next to the voice around it.
        var loudest: Float = 0
        for k in max(start, j - Self.loudnessSpan)...last { loudest = max(loudest, level(k)) }
        guard level(j) >= Self.quietShare * loudest else { return nil }

        // Already sliding out at the end of the stretch (an end is only known once it is
        // within the look-ahead).
        if let end, j >= end - slideReach {
            var sliding = true
            for k in j..<end where slope(from: max(start, k - lookAhead), to: min(last, k + 1)) <= Self.slideSlope {
                sliding = false
                break
            }
            if sliding { return nil }
        }

        // The note the voice is holding, and how far the line may stray from it.
        let note = heldNote(from: max(start, j - lookAhead), to: last, runStart: start)
        let nearEdge = intoRun < Self.edgeSpan || (end.map { $0 - j <= Self.edgeSpan } ?? false)
        let reach = nearEdge ? 0 : Self.wander
        return note + min(reach, max(-reach, value - note))
    }

    /// The weighted median of the readings `first...last`, weighted by how still each
    /// one's pitch holds and how loud it is.
    private func heldNote(from first: Int, to last: Int, runStart: Int) -> Double {
        let n = last - first + 1
        for m in 0..<n {
            let k = first + m
            // Change per analysis, from the readings either side where both are known.
            let a = max(k - 1, runStart), b = min(k + 1, last)
            let change = b > a ? abs(p(b) - p(a)) / Double(b - a) : .infinity
            let steadiness = exp(-(change / Self.steadySlope) * (change / Self.steadySlope)) + 1e-3
            windowPitches[m] = p(k)
            windowWeights[m] = steadiness * (Double(level(k)) * Double(level(k)))
            order[m] = m
        }
        // Insertion sort by pitch, keeping equal pitches in order: never more than
        // 2 × lookAhead + 1 readings.
        if n > 1 {
            for m in 1..<n {
                let o = order[m]
                var q = m
                while q > 0 && windowPitches[order[q - 1]] > windowPitches[o] {
                    order[q] = order[q - 1]
                    q -= 1
                }
                order[q] = o
            }
        }
        var total = 0.0
        for m in 0..<n { total += windowWeights[order[m]] }
        var running = 0.0
        for m in 0..<n {
            running += windowWeights[order[m]]
            if running >= total / 2 { return windowPitches[order[m]] }
        }
        return windowPitches[order[n - 1]]
    }

    /// Semitones per analysis of the least-squares line through the readings
    /// `from...to`; infinite for fewer than three.
    private func slope(from first: Int, to last: Int) -> Double {
        let n = last - first + 1
        guard n >= 3 else { return .infinity }
        let meanX = Double(n - 1) / 2
        var meanY = 0.0
        for k in first...last { meanY += p(k) }
        meanY /= Double(n)
        var sxy = 0.0, sxx = 0.0
        for k in first...last {
            let x = Double(k - first) - meanX
            sxy += x * (p(k) - meanY)
            sxx += x * x
        }
        return abs(sxy / sxx)
    }
}
