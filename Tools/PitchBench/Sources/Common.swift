import Foundation
import AVFoundation
import Accelerate

protocol RealtimeDetector: AnyObject {
    var name: String { get }
    /// Feed one tap buffer. Returns true when an analysis ran (so the output was refreshed).
    func process(_ channel: UnsafePointer<Float>, _ n: Int) -> Bool
    var current: Double? { get }
}

struct Note { let pitch: Int; let beat: Double; let length: Double }
struct DrawnSample { let beat: Double; let pitch: Double? }

struct Recording {
    let name: String
    let samples: [Float]
    let sampleRate: Double
    let bpm: Double
    let segBeat: Double          // beat of file frame 0
    let notes: [Note]
    let drawn: [DrawnSample]
    let micDelayMs: Double
    let recordedAt: String

    /// File time (s) of a beat.
    func time(ofBeat b: Double) -> Double { (b - segBeat) * 60 / bpm }
    func beat(ofTime t: Double) -> Double { segBeat + t * bpm / 60 }
}

func loadRecording(_ dir: String) -> Recording {
    let url = URL(fileURLWithPath: dir)
    let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("recording.json"))) as! [String: Any]
    let audio = json["audio"] as! [String: Any]
    let seg = (audio["segments"] as! [[String: Any]])[0]
    let ex = json["exercise"] as! [String: Any]
    let notes = (json["notes"] as! [[String: Any]]).map {
        Note(pitch: ($0["pitch"] as! NSNumber).intValue, beat: ($0["beat"] as! NSNumber).doubleValue,
             length: ($0["length"] as! NSNumber).doubleValue)
    }
    let drawn = (json["pitchSamples"] as! [[String: Any]]).map {
        DrawnSample(beat: ($0["beat"] as! NSNumber).doubleValue, pitch: ($0["pitch"] as? NSNumber)?.doubleValue)
    }
    let settings = json["settings"] as! [String: Any]
    let file = try! AVAudioFile(forReading: url.appendingPathComponent("microphone.wav"))
    let fmt = file.processingFormat
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length))!
    try! file.read(into: buf)
    let n = Int(buf.frameLength)
    let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: n))
    return Recording(name: url.lastPathComponent, samples: samples, sampleRate: fmt.sampleRate,
                     bpm: (ex["bpm"] as! NSNumber).doubleValue,
                     segBeat: (seg["beat"] as! NSNumber).doubleValue, notes: notes, drawn: drawn,
                     micDelayMs: (settings["microphoneDelayMs"] as? NSNumber)?.doubleValue ?? 0,
                     recordedAt: json["recordedAt"] as? String ?? "")
}

/// One realtime output: the detector's estimate right after the buffer ending at `endSample`.
struct TrackPoint { let endSample: Int; let pitch: Double? }

func runDetector(_ det: RealtimeDetector, samples: [Float], hop: Int) -> (points: [TrackPoint], seconds: Double) {
    var out: [TrackPoint] = []
    out.reserveCapacity(samples.count / hop + 1)
    let t0 = DispatchTime.now().uptimeNanoseconds
    samples.withUnsafeBufferPointer { buf in
        var i = 0
        while i + hop <= buf.count {
            _ = det.process(buf.baseAddress! + i, hop)
            i += hop
            out.append(TrackPoint(endSample: i, pitch: det.current))
        }
    }
    let t1 = DispatchTime.now().uptimeNanoseconds
    return (out, Double(t1 - t0) / 1e9)
}

func midi(_ f: Double) -> Double { 69 + 12 * log2(f / 440) }
func hz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

func percentile(_ v: [Double], _ p: Double) -> Double {
    guard !v.isEmpty else { return .nan }
    let s = v.sorted()
    let idx = min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))
    return s[idx]
}
