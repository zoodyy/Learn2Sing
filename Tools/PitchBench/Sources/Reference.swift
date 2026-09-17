import Foundation
import Accelerate

/// Offline, non-causal reference pitch track: centred YIN for the precise period, a
/// SWIPE'-style harmonic comb on a centred spectrum for the octave, Viterbi over time.
struct RefFrame {
    var pitch: Double?          // MIDI, after Viterbi
    var aperiodicity: Float     // CMNDF at the chosen lag (1 = noise)
    var rms: Float
    var combStrength: Float     // normalised comb score of the chosen f0
}

final class ReferenceTracker {
    let sr: Double
    let step: Int
    let W = 1920
    let minF = 60.0, maxF = 1000.0
    let maxLag: Int, minLag: Int
    let fftLen = 2400
    let fftN = 16384
    let log2n: vDSP_Length = 14

    init(sampleRate: Double, step: Int = 96) {
        sr = sampleRate
        self.step = step
        maxLag = Int(sampleRate / minF)
        minLag = Int(sampleRate / maxF)
    }

    struct Cand { var midi: Double; var cost: Double; var aper: Float; var comb: Float }

    func highpass(_ x: [Float]) -> [Float] {
        // 2nd-order Butterworth HP at 50 Hz, run forwards and backwards (zero phase).
        let f0 = 50.0, q = 1 / sqrt(2.0)
        let w0 = 2 * Double.pi * f0 / sr
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let b0 = (1 + cos(w0)) / 2 / a0, b1 = -(1 + cos(w0)) / a0, b2 = b0
        let a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
        func run(_ v: [Float]) -> [Float] {
            var y = [Float](repeating: 0, count: v.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<v.count {
                let xi = Double(v[i])
                let yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = xi; y2 = y1; y1 = yi
                y[i] = Float(yi)
            }
            return y
        }
        return Array(run(Array(run(x).reversed())).reversed())
    }

    var loose = false
    func analyze(_ raw: [Float]) -> [RefFrame] {
        let x = highpass(raw)
        let n = x.count
        let frames = n / step
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(x[i]) * Double(x[i]) }
        let globalRms = sqrt(prefix[n] / Double(n))

        var cands = [[Cand]](repeating: [], count: frames)
        var rmsArr = [Float](repeating: 0, count: frames)
        let chunks = 16
        let per = (frames + chunks - 1) / chunks
        cands.withUnsafeMutableBufferPointer { candBuf in
        rmsArr.withUnsafeMutableBufferPointer { rmsBuf in
        x.withUnsafeBufferPointer { xb in
        prefix.withUnsafeBufferPointer { pb in
            DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
                defer { vDSP_destroy_fftsetup(setup) }
                var d = [Double](repeating: 0, count: maxLag + 2)
                var dn = [Double](repeating: 1, count: maxLag + 2)
                var re = [Float](repeating: 0, count: fftN / 2)
                var im = [Float](repeating: 0, count: fftN / 2)
                var mag = [Float](repeating: 0, count: fftN / 2)
                var frame = [Float](repeating: 0, count: fftN)
                var hann = [Float](repeating: 0, count: fftLen)
                vDSP_hann_window(&hann, vDSP_Length(fftLen), Int32(vDSP_HANN_NORM))
                let binHz = sr / Double(fftN)
                for k in (ci * per)..<min(frames, (ci + 1) * per) {
                    let c = k * step + step / 2
                    // RMS over the centred integration window
                    let a = max(0, c - W / 2), b = min(n, c + W / 2)
                    let rms = b > a ? sqrt((pb[b] - pb[a]) / Double(b - a)) : 0
                    rmsBuf[k] = Float(rms)
                    guard c - (W + maxLag) / 2 - 1 >= 0, c + (W + maxLag) / 2 + 2 < n,
                          c - fftLen / 2 >= 0, c + fftLen / 2 < n else { continue }
                    guard rms > globalRms * 0.05, rms > 0.0015 else { continue }
                    // YIN difference, centred per lag
                    var run = 0.0
                    d[0] = 0; dn[0] = 1
                    for tau in 1...maxLag {
                        let s = c - (W + tau) / 2
                        var dot: Float = 0
                        vDSP_dotpr(xb.baseAddress! + s, 1, xb.baseAddress! + s + tau, 1, &dot, vDSP_Length(W))
                        let e1 = pb[s + W] - pb[s], e2 = pb[s + tau + W] - pb[s + tau]
                        let dv = max(0, e1 + e2 - 2 * Double(dot))
                        d[tau] = dv
                        run += dv
                        dn[tau] = run > 0 ? dv * Double(tau) / run : 1
                    }
                    // Spectrum (sqrt magnitude)
                    for i in 0..<fftN { frame[i] = 0 }
                    for i in 0..<fftLen { frame[i] = xb[c - fftLen / 2 + i] * hann[i] }
                    re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftN / 2) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftN / 2))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(fftN / 2))
                    }}
                    for i in 0..<(fftN / 2) { mag[i] = sqrt(mag[i]) }
                    func amp(_ f: Double) -> Double {
                        let p = f / binHz
                        let i = Int(p)
                        guard i >= 0, i + 1 < fftN / 2 else { return 0 }
                        let fr = p - Double(i)
                        return Double(mag[i]) * (1 - fr) + Double(mag[i + 1]) * fr
                    }
                    func peak(_ f: Double) -> Double {
                        let lo = Int(f * 0.975 / binHz), hi = Int(f * 1.025 / binHz) + 1
                        guard lo >= 0, hi < fftN / 2 else { return 0 }
                        var m: Float = 0
                        for i in lo...hi where mag[i] > m { m = mag[i] }
                        return Double(m)
                    }
                    let primes: [Double] = [1, 2, 3, 5, 7, 11, 13]
                    func comb(_ f0: Double) -> Double {
                        var s = 0.0, wsum = 0.0
                        for p in primes {
                            let f = p * f0
                            if f > 3500 { break }
                            let w = 1 / sqrt(p)
                            s += w * (peak(f) - 0.5 * (amp((p - 0.5) * f0) + amp((p + 0.5) * f0)))
                            wsum += w
                        }
                        return wsum > 0 ? s / wsum : 0
                    }
                    // Local level for normalising the comb
                    var level = 0.0
                    do {
                        let lo = Int(60 / binHz), hi = Int(3500 / binHz)
                        var sum: Float = 0
                        mag.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + lo, 1, &sum, vDSP_Length(hi - lo)) }
                        level = Double(sum) / Double(hi - lo)
                    }
                    guard level > 0 else { continue }

                    // Comb over a log grid, local maxima as octave hypotheses
                    var grid: [(Double, Double)] = []
                    var m = midi(minF)
                    while m <= midi(maxF) {
                        grid.append((m, comb(hz(m))))
                        m += 1.0 / 8
                    }
                    var combBest = 0.0
                    for g in grid where g.1 > combBest { combBest = g.1 }
                    guard combBest > 0 else { continue }
                    var hyps: [(Double, Double)] = []
                    for i in 1..<(grid.count - 1) where grid[i].1 > grid[i - 1].1 && grid[i].1 >= grid[i + 1].1 && grid[i].1 > combBest * 0.3 {
                        hyps.append(grid[i])
                    }
                    hyps.sort { $0.1 > $1.1 }
                    var list: [Cand] = []
                    for h in hyps.prefix(5) {
                        // Refine with the YIN minimum nearest to the hypothesis (±0.7 st)
                        let tc = sr / hz(h.0)
                        let lo = max(minLag, Int(tc / pow(2, 0.7 / 12))), hi = min(maxLag - 1, Int(tc * pow(2, 0.7 / 12)) + 1)
                        guard lo < hi else { continue }
                        var bt = lo
                        for t in lo...hi where dn[t] < dn[bt] { bt = t }
                        var tau = Double(bt)
                        if bt > 1, bt < maxLag {
                            let y0 = d[bt - 1], y1 = d[bt], y2 = d[bt + 1]
                            let den = y0 - 2 * y1 + y2
                            if den > 0 { tau += max(-0.5, min(0.5, 0.5 * (y0 - y2) / den)) }
                        }
                        let aper = Float(dn[bt])
                        let mm = (bt > lo && bt < hi) ? midi(sr / tau) : h.0
                        let combN = h.1 / combBest
                        let cost = loose ? Double(aper) * 1.0 + (1 - combN) * 1.5 : Double(aper) * 2 + (1 - combN) * 1.5
                        list.append(Cand(midi: mm, cost: cost, aper: aper, comb: Float(h.1 / level)))
                    }
                    candBuf[k] = list
                }
            }
        }}}}

        // Viterbi: state 0 = unvoiced, others = candidates
        var out = [RefFrame](repeating: RefFrame(pitch: nil, aperiodicity: 1, rms: 0, combStrength: 0), count: frames)
        var prevCost: [Double] = [0]
        var prevStates: [Cand?] = [nil]
        var back: [[Int]] = []
        back.reserveCapacity(frames)
        let dtScale = Double(step) / sr / 0.002
        for k in 0..<frames {
            let cs = cands[k]
            var states: [Cand?] = [nil]
            states.append(contentsOf: cs.map { Optional($0) })
            // Unvoiced emission cost: cheap if quiet or aperiodic
            let bestAper = cs.map { Double($0.aper) }.min() ?? 1
            let uvCost = cs.isEmpty ? 0 : (loose ? max(0, 0.9 - bestAper * 1.2) * 1.2 + 0.3 : max(0, 0.9 - bestAper * 2) * 1.2 + 0.3)
            var cost = [Double](repeating: .infinity, count: states.count)
            var bp = [Int](repeating: 0, count: states.count)
            for (j, s) in states.enumerated() {
                let emit = s.map { $0.cost } ?? uvCost
                for (i, p) in prevStates.enumerated() {
                    var trans = 0.0
                    switch (p, s) {
                    case (nil, nil): trans = 0
                    case (nil, _), (_, nil): trans = 1.2
                    case let (a?, b?):
                        let jump = abs(a.midi - b.midi) / dtScale
                        trans = jump * 0.25 + max(0, jump - 1.0) * 1.5
                    }
                    let c = prevCost[i] + trans + emit
                    if c < cost[j] { cost[j] = c; bp[j] = i }
                }
            }
            let mn = cost.min() ?? 0
            prevCost = cost.map { $0 - mn }
            prevStates = states
            back.append(bp)
            _ = rmsArr
        }
        var j = prevCost.indices.min { prevCost[$0] < prevCost[$1] } ?? 0
        for k in stride(from: frames - 1, through: 0, by: -1) {
            let cs = cands[k]
            if j > 0 {
                let c = cs[j - 1]
                out[k] = RefFrame(pitch: c.midi, aperiodicity: c.aper, rms: rmsArr[k], combStrength: c.comb)
            } else {
                out[k] = RefFrame(pitch: nil, aperiodicity: cs.map { $0.aper }.min() ?? 1, rms: rmsArr[k], combStrength: 0)
            }
            j = back[k][j]
        }
        return out
    }
}
