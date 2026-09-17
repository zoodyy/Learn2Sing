import Foundation

/// A pitch track sampled at arbitrary times (seconds of file time).
struct TimedTrack {
    var times: [Double]
    var values: [Double?]
}

struct Metrics {
    var latencyMs = 0.0          // best alignment lag
    var stepLatencyMs = 0.0      // median delay of the midpoint crossing on note changes
    var stepLatencyP90 = 0.0
    var steps = 0
    var medianCents = 0.0        // on steady reference
    var p95Cents = 0.0
    var outlierFrac = 0.0        // voiced output points > 1 st from any reference value nearby
    var outlierEvents = 0
    var grossFrac = 0.0          // > 3 st
    var spuriousFrac = 0.0       // voiced output where reference is unvoiced all around, and off from nearby reference
    var spuriousEvents = 0
    var recall = 0.0             // steady voiced reference covered by output
    var voicedPoints = 0
    var cpuPerSec = 0.0
    var onsetMs = 0.0
    var onsetP90 = 0.0
    var onsets = 0
}

final class Evaluator {
    let ref: [RefFrame]
    let sr: Double
    let step: Int
    let refMidi: [Double]   // NaN when unvoiced
    let stable: [Bool]      // voiced and steady within +-30 ms
    let looseMidi: [Double]
    init(ref: [RefFrame], loose: [RefFrame]?, sampleRate: Double, step: Int) {
        self.ref = ref; sr = sampleRate; self.step = step
        refMidi = ref.map { $0.pitch ?? .nan }
        looseMidi = loose.map { $0.map { $0.pitch ?? .nan } } ?? refMidi
        let w = Int(0.03 * sampleRate) / step
        var st = [Bool](repeating: false, count: ref.count)
        for k in 0..<ref.count {
            let p = refMidi[k]
            guard !p.isNaN, k - w >= 0, k + w < ref.count else { continue }
            var ok = true
            for j in (k - w)...(k + w) {
                let q = refMidi[j]
                if q.isNaN || abs(q - p) > 0.3 { ok = false; break }
            }
            st[k] = ok
        }
        stable = st
    }

    func frame(_ t: Double) -> Int { Int((t * sr - Double(step) / 2) / Double(step)) }
    func refAt(_ t: Double) -> Double {
        let k = frame(t)
        guard k >= 0, k < ref.count else { return .nan }
        return refMidi[k]
    }

    /// Minimum distance from `v` to any voiced reference value in [t-w, t+w]; nil if none voiced.
    /// The loose reference counts as voiced too.
    func nearest(_ v: Double, _ t: Double, _ w: Double) -> Double? {
        let a = max(0, frame(t - w)), b = min(ref.count - 1, frame(t + w))
        guard a <= b else { return nil }
        var best: Double? = nil
        for k in a...b {
            for q in [refMidi[k], k < looseMidi.count ? looseMidi[k] : .nan] {
                if q.isNaN { continue }
                let d = abs(q - v)
                if best == nil || d < best! { best = d }
            }
        }
        return best
    }

    func evaluate(_ track: TimedTrack, fixedLatency: Double? = nil) -> Metrics {
        var m = Metrics()
        // 1. Alignment lag
        var bestL = 0.0, bestE = Double.infinity
        if let f = fixedLatency { bestL = f } else {
            for li in 0...200 {
                let L = Double(li) * 0.001
                var sum = 0.0, cnt = 0
                for (i, t) in track.times.enumerated() {
                    guard let v = track.values[i] else { continue }
                    let r = refAt(t - L)
                    if r.isNaN { continue }
                    sum += min(abs(v - r), 1); cnt += 1
                }
                let e = cnt > 0 ? sum / Double(cnt) : .infinity
                if e < bestE { bestE = e; bestL = L }
            }
        }
        m.latencyMs = bestL * 1000

        // 2. Accuracy on steady reference, outliers, spurious
        var errs: [Double] = []
        var outl = 0, gross = 0, spur = 0, voiced = 0
        var inOut = false, inSpur = false
        for (i, t) in track.times.enumerated() {
            guard let v = track.values[i] else { inOut = false; inSpur = false; continue }
            voiced += 1
            let tc = t - bestL
            let k = frame(tc)
            if k >= 0, k < ref.count, stable[k] { errs.append(abs(v - refMidi[k]) * 100) }
            if let d = nearest(v, tc, 0.03) {
                inSpur = false
                if d > 1 { outl += 1; if !inOut { m.outlierEvents += 1 }; inOut = true } else { inOut = false }
                if d > 3 { gross += 1 }
            } else {
                inOut = false
                // reference unvoiced all around: is the output far from any voiced reference nearby?
                let d = nearest(v, tc, 0.15)
                if d == nil || d! > 1 {
                    spur += 1
                    if !inSpur { m.spuriousEvents += 1 }
                    inSpur = true
                } else { inSpur = false }
            }
        }
        m.voicedPoints = voiced
        m.medianCents = percentile(errs, 0.5)
        m.p95Cents = percentile(errs, 0.95)
        m.outlierFrac = Double(outl) / Double(max(1, voiced))
        m.grossFrac = Double(gross) / Double(max(1, voiced))
        m.spuriousFrac = Double(spur) / Double(max(1, voiced))

        // 3. Recall: steady reference frames with output voiced at t + L
        var covered = 0, total = 0
        var ti = 0
        for k in 0..<ref.count where stable[k] {
            let t = (Double(k * step) + Double(step) / 2) / sr + bestL
            while ti + 1 < track.times.count && track.times[ti + 1] <= t { ti += 1 }
            guard ti < track.times.count, track.times[ti] <= t else { continue }
            total += 1
            if track.values[ti] != nil { covered += 1 }
        }
        m.recall = Double(covered) / Double(max(1, total))

        // 4. Step latency: glides between steady plateaus >= 1.5 st apart, voiced throughout
        var delays: [Double] = []
        var plateaus: [(s: Int, e: Int, v: Double)] = []
        var kk = 0
        while kk < ref.count {
            if stable[kk] {
                var e = kk
                while e + 1 < ref.count && stable[e + 1] && abs(refMidi[e + 1] - refMidi[kk]) < 0.5 { e += 1 }
                if e - kk >= 5 { plateaus.append((kk, e, refMidi[(kk + e) / 2])) }
                kk = e + 1
            } else { kk += 1 }
        }
        let maxGap = Int(0.2 * sr) / step
        for pi in 1..<max(1, plateaus.count) {
            let p1 = plateaus[pi - 1], p2 = plateaus[pi]
            guard p2.s - p1.e <= maxGap, abs(p2.v - p1.v) >= 1.5 else { continue }
            var ok = true
            for j in p1.e...p2.s where refMidi[j].isNaN { ok = false; break }
            guard ok else { continue }
            let mid = (p1.v + p2.v) / 2
            let up = p2.v > p1.v
            var kc = p1.e
            while kc < p2.s && (up ? refMidi[kc] < mid : refMidi[kc] > mid) { kc += 1 }
            let tRef = (Double(kc * step) + Double(step) / 2) / sr
            var tOut: Double? = nil
            // first output point after tRef - 0.03 on the far side of mid (and not further than 3 st past the target)
            var lo = 0, hi = track.times.count
            while lo < hi { let md = (lo + hi) / 2; if track.times[md] < tRef - 0.03 { lo = md + 1 } else { hi = md } }
            var i = lo
            while i < track.times.count && track.times[i] <= tRef + 0.3 {
                if let v = track.values[i], (up ? v >= mid : v <= mid), abs(v - p2.v) < 3 { tOut = track.times[i]; break }
                i += 1
            }
            if let tOut { delays.append((tOut - tRef) * 1000) }
        }
        // 5. Onset latency: reference voicing starts after >= 60 ms unvoiced, voiced for >= 80 ms
        var onsetDelays: [Double] = []
        let quiet = Int(0.06 * sr) / step, hold = Int(0.08 * sr) / step
        var k2 = quiet
        while k2 < ref.count - hold {
            guard !refMidi[k2].isNaN, refMidi[k2 - 1].isNaN else { k2 += 1; continue }
            var ok = true
            for j in (k2 - quiet)..<k2 where !refMidi[j].isNaN { ok = false; break }
            if ok { for j in k2..<(k2 + hold) where refMidi[j].isNaN { ok = false; break } }
            guard ok else { k2 += 1; continue }
            let tOn = (Double(k2 * step) + Double(step) / 2) / sr
            var lo = 0, hi = track.times.count
            while lo < hi { let md = (lo + hi) / 2; if track.times[md] < tOn - 0.03 { lo = md + 1 } else { hi = md } }
            var i = lo
            while i < track.times.count && track.times[i] <= tOn + 0.3 {
                if let v = track.values[i] {
                    let r = refAt(max(tOn, track.times[i] - 0.02))
                    if !r.isNaN && abs(v - r) <= 1 { onsetDelays.append((track.times[i] - tOn) * 1000); break }
                }
                i += 1
            }
            k2 += hold
        }
        m.onsets = onsetDelays.count
        m.onsetMs = percentile(onsetDelays, 0.5)
        m.onsetP90 = percentile(onsetDelays, 0.9)
        m.steps = delays.count
        m.stepLatencyMs = percentile(delays, 0.5)
        m.stepLatencyP90 = percentile(delays, 0.9)
        return m
    }
}

/// The app's SingerIndicator, verbatim.
final class SingerIndicator {
    private var shown: Double? = nil
    private let knee = 3.0
    private var lastShown: Double? = nil
    private let reappearSnap = 5.0
    func step(target: Double?, factor: Double) -> Double? {
        guard let target else { shown = nil; return nil }
        let from: Double
        if let current = shown {
            from = current
        } else if let last = lastShown, abs(target - last) > reappearSnap {
            from = last
        } else {
            from = target
        }
        let limit = factor * knee
        let next = from + min(limit, max(-limit, (target - from) * factor))
        shown = next
        lastShown = next
        return next
    }
}

protocol DisplaySmoother {
    mutating func step(target: Double?, dt: Double) -> Double?
}

struct OldSmoother: DisplaySmoother {
    let ind = SingerIndicator()
    mutating func step(target: Double?, dt: Double) -> Double? { ind.step(target: target, factor: 0.35) }
}

/// Raw rt output at its buffer-end times.
func rawTrack(_ pts: [TrackPoint], sampleRate: Double) -> TimedTrack {
    TimedTrack(times: pts.map { Double($0.endSample) / sampleRate }, values: pts.map { $0.pitch })
}

/// Sample-and-hold of the raw output on a fine grid (what a consumer polling it would see).
func heldTrack(_ pts: [TrackPoint], sampleRate: Double, grid: Double = 0.002, deliveryDelay: Double = 0.001) -> TimedTrack {
    var times: [Double] = [], values: [Double?] = []
    var t = grid / 2
    var i = -1
    let end = Double(pts.last?.endSample ?? 0) / sampleRate
    while t < end {
        while i + 1 < pts.count && Double(pts[i + 1].endSample) / sampleRate + deliveryDelay <= t { i += 1 }
        times.append(t)
        values.append(i >= 0 ? pts[i].pitch : nil)
        t += grid
    }
    return TimedTrack(times: times, values: values)
}

/// What the screen shows: sampled at `fps`, reading the latest output delivered `deliveryDelay` after its buffer end.
func drawnTrack<S: DisplaySmoother>(_ pts: [TrackPoint], sampleRate: Double, fps: Double, deliveryDelay: Double = 0.001, smoother: S) -> TimedTrack {
    var s = smoother
    var times: [Double] = [], values: [Double?] = []
    let dt = 1 / fps
    var t = 0.5 * dt
    var i = -1
    let end = Double(pts.last?.endSample ?? 0) / sampleRate
    while t < end {
        while i + 1 < pts.count && Double(pts[i + 1].endSample) / sampleRate + deliveryDelay <= t { i += 1 }
        let target = i >= 0 ? pts[i].pitch : nil
        times.append(t)
        values.append(s.step(target: target, dt: dt))
        t += dt
    }
    return TimedTrack(times: times, values: values)
}

func fmt(_ m: Metrics) -> String {
    String(format: "lat %5.1f  on %5.1f/%5.1f (n%4d)  step %5.1f/%5.1f (n%4d)  med %4.1fc p95 %5.1fc  outl %.3f%% (%3d ev) gross %.3f%%  spur %.3f%% (%3d ev)  recall %5.2f%%  cpu %.4f",
           m.latencyMs, m.onsetMs, m.onsetP90, m.onsets, m.stepLatencyMs, m.stepLatencyP90, m.steps, m.medianCents, m.p95Cents,
           m.outlierFrac * 100, m.outlierEvents, m.grossFrac * 100, m.spuriousFrac * 100, m.spuriousEvents, m.recall * 100, m.cpuPerSec)
}

struct NoSmoother: DisplaySmoother {
    mutating func step(target: Double?, dt: Double) -> Double? { target }
}

struct FactorSmoother: DisplaySmoother {
    let ind = SingerIndicator()
    let factor: Double
    mutating func step(target: Double?, dt: Double) -> Double? { ind.step(target: target, factor: factor) }
}

/// Exponential ease with a time constant, snapping when a note starts.
struct ExpSmoother: DisplaySmoother {
    let tc: Double
    var shown: Double? = nil
    mutating func step(target: Double?, dt: Double) -> Double? {
        guard let target else { shown = nil; return nil }
        guard let s = shown else { shown = target; return target }
        let a = 1 - exp(-dt / tc)
        shown = s + (target - s) * a
        return shown
    }
}

/// One Euro filter (Casiez et al.) on the pitch, snapping when a note starts.
struct OneEuroSmoother: DisplaySmoother {
    let minCutoff: Double   // Hz
    let beta: Double
    let dCutoff: Double
    var x: Double? = nil
    var dx = 0.0
    mutating func step(target: Double?, dt: Double) -> Double? {
        guard let target else { x = nil; dx = 0; return nil }
        guard let prev = x else { x = target; dx = 0; return target }
        func alpha(_ cutoff: Double) -> Double { let tau = 1 / (2 * .pi * cutoff); return 1 / (1 + tau / dt) }
        let d = (target - prev) / dt
        dx += alpha(dCutoff) * (d - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let v = prev + alpha(cutoff) * (target - prev)
        x = v
        return v
    }
}
