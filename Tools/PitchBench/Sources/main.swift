import Foundation
import AVFoundation

/// Where `prepare` unpacks the recordings (and their reference tracks) and every
/// other command reads them from.
let recRoot = ProcessInfo.processInfo.environment["PITCHBENCH_WORK"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".work").path
let args = Array(CommandLine.arguments.dropFirst())

let usage = """
pitchbench prepare <folder with exported .zip recordings>...
pitchbench checkref                        reference track vs the sung target notes
pitchbench eval <old|new> <bufferFrames> [fps] [recording dirs...]
pitchbench synth <old|new> <bufferFrames> [config]     (RATE=44100 etc.)
pitchbench dump <old|new> <bufferFrames> <latencyMs> <recording|synth:config>
pitchbench classify <old|new> <bufferFrames> <latencyMs>
pitchbench validate <bufferFrames> [recording dirs...]  old detector vs what the app drew
pitchbench export <detector> <bufferFrames> [recording dirs...]   raw output per recording
pitchbench runlist <detector> <bufferFrames> <list>   "<in.wav>\\t<out.bin>" lines, any WAV
pitchbench reflist <list>                             reference tracks for any WAV
pitchbench frames <bufferFrames> <list>               every analysis of `exp`
detectors: old, new (= fastest), balanced, accurate, exp (tuning from the environment)
"""

func allDirs() -> [String] {
    let names = try! FileManager.default.contentsOfDirectory(atPath: recRoot).filter { $0.hasPrefix("Learn2Sing-") }.sorted()
    return names.map { recRoot + "/" + $0 }
}

func refPath(_ dir: String) -> String { dir + "/ref.bin" }

func saveRef(_ frames: [RefFrame], to path: String) {
    var flat: [Float] = []
    for f in frames { flat += [Float(f.pitch ?? .nan), f.aperiodicity, f.rms, f.combStrength] }
    let data = flat.withUnsafeBufferPointer { Data(buffer: $0) }
    try! data.write(to: URL(fileURLWithPath: path))
}

func loadRef(_ path: String) -> [RefFrame] {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let flat = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    var out: [RefFrame] = []
    for i in stride(from: 0, to: flat.count, by: 4) {
        out.append(RefFrame(pitch: flat[i].isNaN ? nil : Double(flat[i]), aperiodicity: flat[i + 1], rms: flat[i + 2], combStrength: flat[i + 3]))
    }
    return out
}

let refStep = 96

switch args.first {
case "prepare":
    // prepare <folder of exported .zip recordings>...: unzip into the work folder and
    // compute both reference tracks for each.
    try? FileManager.default.createDirectory(atPath: recRoot, withIntermediateDirectories: true)
    var dirs: [String] = []
    for folder in args.dropFirst() {
        let zips = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        for zip in zips.sorted() where zip.hasPrefix("Learn2Sing-") && zip.hasSuffix(".zip") {
            let stem = String(zip.dropLast(4))
            let out = recRoot + "/" + stem
            if !FileManager.default.fileExists(atPath: out + "/ref_loose.bin") {
                let tmp = recRoot + "/.unzip"
                try? FileManager.default.removeItem(atPath: tmp)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                p.arguments = ["-q", "-o", folder + "/" + zip, "-d", tmp]
                try! p.run(); p.waitUntilExit()
                // The export holds one folder named like the zip.
                try? FileManager.default.removeItem(atPath: out)
                try! FileManager.default.moveItem(atPath: tmp + "/" + stem, toPath: out)
                try? FileManager.default.removeItem(atPath: tmp)
                dirs.append(out)
            }
        }
    }
    for d in dirs {
        let rec = loadRecording(d)
        let t0 = Date()
        let frames = ReferenceTracker(sampleRate: rec.sampleRate, step: refStep).analyze(rec.samples)
        saveRef(frames, to: refPath(d))
        let lt = ReferenceTracker(sampleRate: rec.sampleRate, step: refStep)
        lt.loose = true
        let loose = lt.analyze(rec.samples)
        saveRef(loose, to: d + "/ref_loose.bin")
        let voiced = frames.filter { $0.pitch != nil }.count
        print(rec.name, "frames", frames.count, "voiced", voiced, String(format: "%.1fs", Date().timeIntervalSince(t0)))
    }

case "checkref":
    // Compare the reference against the target notes the singer sang.
    let dirs = args.count > 1 ? Array(args.dropFirst()) : allDirs()
    var hist = [Int: Int]()
    for d in dirs {
        let rec = loadRecording(d)
        let ref = loadRef(refPath(d))
        var local = [Int: Int]()
        for note in rec.notes {
            let t0 = rec.time(ofBeat: note.beat) + 0.12
            let t1 = rec.time(ofBeat: note.beat + note.length)
            guard t1 > t0 else { continue }
            for k in Int(t0 * rec.sampleRate) / refStep..<min(ref.count, Int(t1 * rec.sampleRate) / refStep) {
                guard let p = ref[k].pitch else { continue }
                let diff = Int((p - Double(note.pitch)).rounded())
                local[diff, default: 0] += 1
                hist[diff, default: 0] += 1
            }
        }
        let tot = local.values.reduce(0, +)
        let near = (-1...1).reduce(0) { $0 + local[$1, default: 0] }
        let oct = local.filter { abs($0.key) >= 10 }.values.reduce(0, +)
        print(rec.name, "voiced-in-notes", tot, String(format: "within1 %.1f%%  far(>=10) %d", 100 * Double(near) / Double(max(1, tot)), oct))
    }
    for k in hist.keys.sorted() { print(k, hist[k]!) }

case "eval":
    // eval <detector> <hop> [fps] [files...]
    let detName = args[1]
    let hop = Int(args[2])!
    let fps = args.count > 3 ? Double(args[3])! : 60
    let dirs = args.count > 4 ? Array(args.dropFirst(4)) : allDirs()
    var rawAll: [Metrics] = [], drawnAll: [Metrics] = []
    let lock = NSLock()
    var lines = [String](repeating: "", count: dirs.count)
    DispatchQueue.concurrentPerform(iterations: dirs.count) { di in
        let rec = loadRecording(dirs[di])
        let ev = Evaluator(ref: loadRef(refPath(dirs[di])), loose: loadRef(dirs[di] + "/ref_loose.bin"), sampleRate: rec.sampleRate, step: refStep)
        let det = makeDetector(detName, sampleRate: rec.sampleRate)
        let (pts, secs) = runDetector(det, samples: rec.samples, hop: hop)
        var raw = ev.evaluate(heldTrack(pts, sampleRate: rec.sampleRate))
        raw.cpuPerSec = secs / (Double(rec.samples.count) / rec.sampleRate)
        let drawn = ev.evaluate(drawnTrack(pts, sampleRate: rec.sampleRate, fps: fps, smoother: makeSmoother(detName)))
        lock.lock()
        rawAll.append(raw); drawnAll.append(drawn)
        lines[di] = String(rec.name.dropFirst(11)).padding(toLength: 34, withPad: " ", startingAt: 0) + " HLD " + fmt(raw) + "\n" + String(repeating: " ", count: 34) + " DRW " + fmt(drawn)
        lock.unlock()
    }
    if ProcessInfo.processInfo.environment["QUIET"] == nil { for l in lines { print(l) } }
    print("MEAN HLD", fmt(mean(rawAll)))
    print("MEAN DRW", fmt(mean(drawnAll)))

case "dump":
    // dump <detector> <hop> <latencyMs> <file>: print outlier/spurious events with context
    let det = makeDetector(args[1], sampleRate: 48000)
    let hop = Int(args[2])!
    let L = Double(args[3])! / 1000
    let rec: Recording
    let ev: Evaluator
    if args[4].hasPrefix("synth:") {
        let cfg = synthConfigs.first { $0.name == String(args[4].dropFirst(6)) }!
        let (x, truth) = synthesize(cfg, sampleRate: 48000, seconds: 40, step: refStep)
        rec = Recording(name: cfg.name, samples: x, sampleRate: 48000, bpm: 120, segBeat: 0, notes: [], drawn: [], micDelayMs: 0, recordedAt: "")
        ev = Evaluator(ref: truth, loose: nil, sampleRate: 48000, step: refStep)
    } else {
        let d = args[4].hasPrefix("/") ? args[4] : recRoot + "/" + args[4]
        rec = loadRecording(d)
        ev = Evaluator(ref: loadRef(refPath(d)), loose: loadRef(d + "/ref_loose.bin"), sampleRate: rec.sampleRate, step: refStep)
    }
    var dbg: [String] = []
    var pts: [TrackPoint] = []
    rec.samples.withUnsafeBufferPointer { buf in
        var i = 0
        while i + hop <= buf.count {
            _ = det.process(buf.baseAddress! + i, hop)
            i += hop
            pts.append(TrackPoint(endSample: i, pitch: det.current))
            dbg.append("")
        }
    }
    var lastPrinted = -1
    for (i, p) in pts.enumerated() {
        guard let v = p.pitch else { continue }
        let t = Double(p.endSample) / rec.sampleRate - L
        let near = ev.nearest(v, t, 0.03)
        let bad: String
        if let n = near { if n > 1 { bad = "OUT" } else { continue } } else {
            let n2 = ev.nearest(v, t, 0.15)
            if n2 == nil || n2! > 1 { bad = "SPUR" } else { continue }
        }
        guard i > lastPrinted else { continue }
        print("---", bad, String(format: "t=%.3f", t))
        for j in max(0, i - 6)...min(pts.count - 1, i + 6) {
            let tj = Double(pts[j].endSample) / rec.sampleRate - L
            let r = ev.refAt(tj)
            let k = ev.frame(tj)
            let rf = (k >= 0 && k < ev.ref.count) ? ev.ref[k] : RefFrame(pitch: nil, aperiodicity: 1, rms: 0, combStrength: 0)
            print(String(format: "%@ %.3f  rt %6.2f  ref %6.2f  aper %.2f rms %.4f  %@", j == i ? ">" : " ", tj, pts[j].pitch ?? .nan, r, rf.aperiodicity, rf.rms, dbg[j]))
            lastPrinted = j
        }
    }

case "classify":
    // classify <detector> <hop> <latencyMs>: categorize outlier events over all files
    let hop = Int(args[2])!
    let L = Double(args[3])! / 1000
    var cats = [String: Int]()
    let lock = NSLock()
    let dirs = allDirs()
    DispatchQueue.concurrentPerform(iterations: dirs.count) { di in
        let d = dirs[di]
        let det = makeDetector(args[1], sampleRate: 48000)
        let rec = loadRecording(d)
        let ev = Evaluator(ref: loadRef(refPath(d)), loose: loadRef(d + "/ref_loose.bin"), sampleRate: rec.sampleRate, step: refStep)
        let (pts, _) = runDetector(det, samples: rec.samples, hop: hop)
        var i = 0
        var local = [String: Int]()
        while i < pts.count {
            guard let v = pts[i].pitch else { i += 1; continue }
            let t = Double(pts[i].endSample) / rec.sampleRate - L
            let near = ev.nearest(v, t, 0.03)
            var kind = ""
            if let n = near { if n > 1 { kind = "OUT" } } else {
                let n2 = ev.nearest(v, t, 0.15)
                if n2 == nil || n2! > 1 { kind = "SPUR" }
            }
            if kind.isEmpty { i += 1; continue }
            // event extent
            var j = i
            var devs: [Double] = []
            while j < pts.count, let vj = pts[j].pitch {
                let tj = Double(pts[j].endSample) / rec.sampleRate - L
                let r = ev.nearest(vj, tj, 0.03) ?? ev.nearest(vj, tj, 0.15) ?? 99
                if r <= 1 { break }
                let rr = ev.refAt(tj)
                if !rr.isNaN { devs.append(vj - rr) }
                j += 1
            }
            let len = max(1, j - i)
            // onset: output unvoiced within previous 3 points
            var onset = false
            for q in max(0, i - 3)..<i where pts[q].pitch == nil { onset = true }
            let dev = devs.isEmpty ? 99 : devs.sorted()[devs.count / 2]
            let dk: String
            if dev == 99 { dk = "noref" } else if abs(abs(dev) - 12) < 1 { dk = dev > 0 ? "oct+" : "oct-" } else if abs(abs(dev) - 19) < 1 { dk = dev > 0 ? "12th+" : "12th-" } else if abs(dev) < 3 { dk = "small" } else { dk = "other" }
            let key = "\(kind) \(onset ? "onset" : "mid  ") \(dk) len\(min(len, 5))"
            local[key, default: 0] += 1
            i = j + 1
        }
        lock.lock(); for (k, v) in local { cats[k, default: 0] += v }; lock.unlock()
    }
    for k in cats.keys.sorted() { print(k, cats[k]!) }

case "synth":
    // synth <detector> <hop> [configName]
    let detName = args[1]
    let hop = Int(args[2])!
    let only = args.count > 3 ? args[3] : nil
    let cfgs = synthConfigs.filter { only == nil || $0.name == only }
    var all: [Metrics] = []
    var lines = [String](repeating: "", count: cfgs.count)
    let lock = NSLock()
    let rate = Double(ProcessInfo.processInfo.environment["RATE"] ?? "48000")!
    let rstep = Int(rate * 0.002)
    DispatchQueue.concurrentPerform(iterations: cfgs.count) { ci in
        let cfg = cfgs[ci]
        let (x, truth) = synthesize(cfg, sampleRate: rate, seconds: 40, step: rstep)
        let ev = Evaluator(ref: truth, loose: nil, sampleRate: rate, step: rstep)
        let det = makeDetector(detName, sampleRate: rate)
        let (pts, secs) = runDetector(det, samples: x, hop: hop)
        var m = ev.evaluate(heldTrack(pts, sampleRate: rate))
        m.cpuPerSec = secs / 40
        lock.lock()
        all.append(m)
        lines[ci] = cfg.name.padding(toLength: 16, withPad: " ", startingAt: 0) + fmt(m)
        lock.unlock()
    }
    if ProcessInfo.processInfo.environment["QUIET"] == nil { for l in lines { print(l) } }
    print("SYNTH MEAN", fmt(mean(all)))

case "export":
    // export <detector> <bufferFrames> [recording dirs...]: write each run's raw output to
    // <dir>/track_<detector>.bin as float32 pairs (seconds at the end of the buffer, MIDI or NaN).
    let detName = args[1]
    let hop = Int(args[2])!
    let dirs = args.count > 3 ? Array(args.dropFirst(3)).map { $0.hasPrefix("/") ? $0 : recRoot + "/" + $0 } : allDirs()
    DispatchQueue.concurrentPerform(iterations: dirs.count) { di in
        let rec = loadRecording(dirs[di])
        let det = makeDetector(detName, sampleRate: rec.sampleRate)
        let (pts, _) = runDetector(det, samples: rec.samples, hop: hop)
        var flat: [Float] = []
        for p in pts { flat += [Float(Double(p.endSample) / rec.sampleRate), Float(p.pitch ?? .nan)] }
        let data = flat.withUnsafeBufferPointer { Data(buffer: $0) }
        try! data.write(to: URL(fileURLWithPath: dirs[di] + "/track_\(detName).bin"))
    }

case "runlist":
    // runlist <detector> <bufferFrames> <list>: every line of <list> is "<in.wav>\t<out.bin>";
    // runs the detector over channel 0 of each WAV at its own rate and writes the raw output
    // as `export` does. For audio that isn't an exported recording (public datasets).
    let detName = args[1]
    let hop = Int(args[2])!
    let jobs = try! String(contentsOfFile: args[3], encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
    DispatchQueue.concurrentPerform(iterations: jobs.count) { ji in
        let (samples, rate) = loadWav(jobs[ji][0])
        let det = makeDetector(detName, sampleRate: rate)
        let (pts, _) = runDetector(det, samples: samples, hop: hop)
        var flat: [Float] = []
        for p in pts { flat += [Float(Double(p.endSample) / rate), Float(p.pitch ?? .nan)] }
        let data = flat.withUnsafeBufferPointer { Data(buffer: $0) }
        try! data.write(to: URL(fileURLWithPath: jobs[ji][1]))
    }

case "frames":
    // frames <bufferFrames> <list>: "<in.wav>\t<out.bin>"; every analysis of the experimental
    // analyzer as float32 rows [end s, level, midi, clarity, longClarity, shown, window s].
    let hop = Int(args[1])!
    let jobs = try! String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
    DispatchQueue.concurrentPerform(iterations: jobs.count) { ji in
        let (samples, rate) = loadWav(jobs[ji][0])
        let an = ExpAnalyzer(sampleRate: rate)
        an.recordFrames = true
        samples.withUnsafeBufferPointer { buf in
            var i = 0
            while i + hop <= buf.count { an.process(buf.baseAddress! + i, count: hop); i += hop }
        }
        var flat: [Float] = []
        flat.reserveCapacity(an.frames.count * 7)
        for f in an.frames {
            flat += [Float(Double(f.end) / rate), f.level, Float(f.midi), f.clarity, f.longClarity, Float(f.shown), Float(Double(f.window) / rate)]
        }
        let data = flat.withUnsafeBufferPointer { Data(buffer: $0) }
        try! data.write(to: URL(fileURLWithPath: jobs[ji][1]))
    }

case "reflist":
    // reflist <list>: "<in.wav>\t<out.bin>" per line; the reference track (as `prepare`
    // computes it, 96-frame steps) of any WAV.
    let jobs = try! String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
    for job in jobs where !FileManager.default.fileExists(atPath: job[1]) {
        let (samples, rate) = loadWav(job[0])
        saveRef(ReferenceTracker(sampleRate: rate, step: refStep).analyze(samples), to: job[1])
    }

case "validate":
    // Compare the simulated drawn track of the old detector with what the app drew.
    let hop = Int(args[1])!
    let dirs = args.count > 2 ? Array(args.dropFirst(2)) : allDirs()
    for d in dirs {
        let rec = loadRecording(d)
        let det = OldDetector(sampleRate: rec.sampleRate)
        let (pts, _) = runDetector(det, samples: rec.samples, hop: hop)
        let sim = drawnTrack(pts, sampleRate: rec.sampleRate, fps: 60, smoother: OldSmoother())
        // recorded
        let rt = rec.drawn.map { rec.time(ofBeat: $0.beat) }
        var best = (0.0, Double.infinity, 0.0, 0)
        for li in -60...60 {
            let L = Double(li) * 0.001
            var errs: [Double] = []
            var j = 0
            var both = 0, onlyOne = 0
            for (i, t) in rt.enumerated() {
                let ts = t - L
                while j + 1 < sim.times.count && sim.times[j + 1] <= ts { j += 1 }
                guard j < sim.times.count else { break }
                let a = rec.drawn[i].pitch, b = sim.values[j]
                if let a, let b { errs.append(abs(a - b)); both += 1 } else if (a == nil) != (b == nil) { onlyOne += 1 }
            }
            let e = errs.reduce(0, +) / Double(max(1, errs.count))
            if e < best.1 { best = (L, e, percentile(errs, 0.5), onlyOne) }
        }
        print(rec.name, String(format: "lag %+.0fms  meanAbs %.3f  median %.3f  voicingMismatch %d / %d", best.0 * 1000, best.1, best.2, best.3, rt.count))
    }

default:
    print(usage)
}

func mean(_ ms: [Metrics]) -> Metrics {
    var o = Metrics()
    let n = Double(ms.count)
    for m in ms {
        o.latencyMs += m.latencyMs / n; o.stepLatencyMs += m.stepLatencyMs / n; o.stepLatencyP90 += m.stepLatencyP90 / n
        o.steps += m.steps; o.medianCents += m.medianCents / n; o.p95Cents += m.p95Cents / n
        o.outlierFrac += m.outlierFrac / n; o.outlierEvents += m.outlierEvents; o.grossFrac += m.grossFrac / n
        o.spuriousFrac += m.spuriousFrac / n; o.spuriousEvents += m.spuriousEvents; o.recall += m.recall / n
        o.voicedPoints += m.voicedPoints; o.onsetMs += m.onsetMs / n; o.onsetP90 += m.onsetP90 / n; o.onsets += m.onsets; o.cpuPerSec += m.cpuPerSec / n
    }
    return o
}

func makeDetector(_ name: String, sampleRate: Double) -> RealtimeDetector {
    switch name {
    case "old": return OldDetector(sampleRate: sampleRate)
    case "new", "fastest": return NewDetectorAdapter(sampleRate: sampleRate)
    case "balanced": return NewDetectorAdapter(sampleRate: sampleRate, detection: .balanced)
    case "accurate": return NewDetectorAdapter(sampleRate: sampleRate, detection: .mostAccurate)
    case let n where n.hasPrefix("exp"): return ExpDetectorAdapter(sampleRate: sampleRate)
    default: fatalError("unknown detector \(name)")
    }
}

func makeSmoother(_ name: String) -> AnySmoother {
    let e = ProcessInfo.processInfo.environment
    switch e["SMOOTH"] ?? (name == "old" ? "old" : "exp8") {
    case "none": return AnySmoother(NoSmoother())
    case let s where s.hasPrefix("factor"): return AnySmoother(FactorSmoother(factor: Double(s.dropFirst(6))!))
    case let s where s.hasPrefix("exp"): return AnySmoother(ExpSmoother(tc: Double(s.dropFirst(3))! / 1000))
    case let s where s.hasPrefix("euro"):
        let parts = s.dropFirst(4).split(separator: ",").map { Double($0)! }
        return AnySmoother(OneEuroSmoother(minCutoff: parts[0], beta: parts[1], dCutoff: parts[2]))
    default: return AnySmoother(OldSmoother())
    }
}

struct AnySmoother: DisplaySmoother {
    var box: DisplaySmoother
    init(_ s: DisplaySmoother) { box = s }
    mutating func step(target: Double?, dt: Double) -> Double? { box.step(target: target, dt: dt) }
}

/// The bench's experimental copy of the analyzer; its tuning comes from the environment.
final class ExpDetectorAdapter: RealtimeDetector {
    var name: String { "exp" }
    let analyzer: ExpAnalyzer
    init(sampleRate: Double) { analyzer = ExpAnalyzer(sampleRate: sampleRate) }
    func process(_ channel: UnsafePointer<Float>, _ n: Int) -> Bool {
        analyzer.process(channel, count: n)
        return true
    }
    var current: Double? { analyzer.pitch }
}

/// The app's PitchAnalyzer (compiled straight from the app's source) behind the bench's protocol.
final class NewDetectorAdapter: RealtimeDetector {
    var name: String { "new" }
    let analyzer: PitchAnalyzer
    init(sampleRate: Double, detection: PitchDetection = .fastest) {
        analyzer = PitchAnalyzer(sampleRate: sampleRate, detection: detection)
    }
    func process(_ channel: UnsafePointer<Float>, _ n: Int) -> Bool {
        analyzer.process(channel, count: n)
        return true
    }
    var current: Double? { analyzer.pitch }
}

