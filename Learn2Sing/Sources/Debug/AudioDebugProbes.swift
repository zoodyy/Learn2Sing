//
//  AudioDebugProbes.swift
//  Learn2Sing
//
//  TEMPORARY AUDIO DEBUG LOG: see AudioDebugLog.swift for what it is and how to
//  remove it.
//
//  What the audio threads hand the log. The synthesiser's render block runs on the
//  real-time audio thread, where nothing may lock, wait or allocate, so it writes a
//  fixed-size record per buffer into a preallocated ring that the log's queue
//  empties once a second. The microphone's buffers arrive on the detector's own
//  analysis thread, which may lock, so they go into a plain list behind a mutex.
//

import AVFoundation
import Foundation
import Synchronization

// MARK: - The synthesiser's render thread

/// One player's buffers, one record each.
nonisolated final class AudioDebugRenderProbe: @unchecked Sendable {
    /// Everything about one rendered buffer. Plain values only, so the render thread
    /// can write it without allocating.
    struct Row {
        /// When the buffer's first sample is due at the output (host clock).
        var host: UInt64 = 0
        /// When the render block was called (host clock).
        var now: UInt64 = 0
        var sampleTime: Double = 0
        /// AudioTimeStampFlags: 1 sample time valid, 2 host time valid.
        var flags: UInt32 = 0
        var frames: UInt32 = 0
        /// How long the render took, in host ticks.
        var duration: UInt64 = 0
        /// Loudest sample written, and the sum of the squares (RMS = sqrt(sum/frames)).
        /// A NaN or an infinity anywhere makes the sum non-finite.
        var peak: Float = 0
        var sumSquares: Float = 0
        /// Loudest sum before the soft clip, and how many sums were not finite.
        var preClip: Float = 0
        var nonFinite: UInt32 = 0
        /// Sounding voices, how many of them are string-modelled, and up to eight of
        /// their pitches, one per byte (0xFF for none).
        var voices: UInt8 = 0
        var strings: UInt8 = 0
        var pitches: UInt64 = .max
        var playhead: Int = 0
        var eventIndex: Int32 = 0
        var eventCount: Int32 = 0
        /// Samples the schedule was skipped forward by in this buffer (the catch-up
        /// after a stall).
        var catchUp: Int32 = 0
        /// The host time of sample 0 the drawing is anchored to; 0 while unanchored.
        var anchor: UInt64 = 0
    }

    let name: String
    let sampleRate: Double

    /// About 40 s of buffers; the log empties it every second or two.
    private static let capacity = 4096
    private let rows: UnsafeMutablePointer<Row>
    private let written = Atomic<Int>(0)
    private let taken = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    /// The buffer being rendered. The render thread's alone.
    private var current = Row()

    init(name: String, sampleRate: Double) {
        self.name = name
        self.sampleRate = sampleRate
        rows = .allocate(capacity: Self.capacity)
        rows.initialize(repeating: Row(), count: Self.capacity)
    }

    deinit {
        rows.deinitialize(count: Self.capacity)
        rows.deallocate()
    }

    // MARK: Render thread

    /// Before the player renders a buffer.
    func begin(_ time: AudioTimeStamp, frames: UInt32) {
        current = Row()
        current.now = mach_absolute_time()
        current.host = time.mHostTime
        current.sampleTime = time.mSampleTime
        current.flags = time.mFlags.rawValue
        current.frames = frames
    }

    /// From inside the render, with the player's lock held: where the schedule is.
    func state(playhead: Int, eventIndex: Int, eventCount: Int, voices: Int, strings: Int,
               pitches: UInt64, catchUp: Int, anchor: UInt64, preClip: Double, nonFinite: Int) {
        current.playhead = playhead
        current.eventIndex = Int32(clamping: eventIndex)
        current.eventCount = Int32(clamping: eventCount)
        current.voices = UInt8(clamping: voices)
        current.strings = UInt8(clamping: strings)
        current.pitches = pitches
        current.catchUp = Int32(clamping: catchUp)
        current.anchor = anchor
        current.preClip = Float(preClip)
        current.nonFinite = UInt32(clamping: nonFinite)
    }

    /// After the player has rendered the buffer: measures what it wrote and files
    /// the record.
    func end(_ buffers: UnsafeMutablePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        if list.count > 0, let data = list[0].mData?.assumingMemoryBound(to: Float.self) {
            let count = min(Int(current.frames), Int(list[0].mDataByteSize) / MemoryLayout<Float>.size)
            var peak: Float = 0
            var sum: Float = 0
            var i = 0
            while i < count {
                let sample = data[i]
                let magnitude = abs(sample)
                if magnitude > peak { peak = magnitude }
                sum += sample * sample
                i += 1
            }
            current.peak = peak
            current.sumSquares = sum
        }
        current.duration = mach_absolute_time() &- current.now
        let w = written.load(ordering: .relaxed)
        let t = taken.load(ordering: .acquiring)
        guard w - t < Self.capacity else {
            _ = dropped.add(1, ordering: .relaxed)
            return
        }
        rows[w & (Self.capacity - 1)] = current
        written.store(w + 1, ordering: .releasing)
    }

    // MARK: The log's queue

    /// Hands every record filed since the last call to `body`, oldest first, and
    /// returns how many had to be thrown away because the ring was full.
    func drain(_ body: (Row) -> Void) -> Int {
        let t = taken.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        var i = t
        while i < w {
            body(rows[i & (Self.capacity - 1)])
            i += 1
        }
        taken.store(w, ordering: .releasing)
        return dropped.exchange(0, ordering: .relaxed)
    }
}

// MARK: - The microphone's analysis thread

/// Every microphone buffer the pitch detector analyses: when it was captured, how
/// loud it was, and the pitch the analysis made of it.
nonisolated final class AudioDebugMicProbe: @unchecked Sendable {
    static let shared = AudioDebugMicProbe()

    struct Row {
        /// When the buffer's first sample was captured (host clock); 0 if unknown.
        var host: UInt64
        var sampleTime: Double
        var flags: UInt32
        var frames: Int
        var sampleRate: Double
        /// When the analysis thread got to it (host clock).
        var handled: UInt64
        var rms: Float
        var peak: Float
        /// The pitch drawn after this buffer, as a MIDI note; NaN for none.
        var pitch: Float
    }

    private let rows = Mutex<[Row]>([])
    /// The capture's sample rate, which the timestamp doesn't carry.
    private let rate = Atomic<Int>(48_000)

    /// A new capture is starting at `sampleRate`. Its first buffer carries on from
    /// nothing, so a marker tells the log not to read the jump as a dropout.
    func captureStarted(sampleRate: Double) {
        rate.store(Int(sampleRate), ordering: .relaxed)
        let marker = Row(host: 0, sampleTime: 0, flags: 0, frames: 0, sampleRate: sampleRate,
                         handled: mach_absolute_time(), rms: 0, peak: 0, pitch: .nan)
        rows.withLock { $0.append(marker) }
    }

    func add(_ time: AudioTimeStamp, samples: UnsafePointer<Float>, count: Int, pitch: Double?) {
        var peak: Float = 0
        var sum: Float = 0
        for i in 0..<count {
            let sample = samples[i]
            peak = max(peak, abs(sample))
            sum += sample * sample
        }
        let hostValid = time.mFlags.contains(.hostTimeValid)
        let row = Row(host: hostValid ? time.mHostTime : 0, sampleTime: time.mSampleTime,
                      flags: time.mFlags.rawValue, frames: count,
                      sampleRate: Double(rate.load(ordering: .relaxed)),
                      handled: mach_absolute_time(),
                      rms: count > 0 ? (sum / Float(count)).squareRoot() : 0, peak: peak,
                      pitch: pitch.map(Float.init) ?? .nan)
        rows.withLock { $0.append(row) }
    }

    func drain() -> [Row] {
        rows.withLock { rows in
            let taken = rows
            rows.removeAll(keepingCapacity: true)
            return taken
        }
    }
}

// MARK: - The drawing

/// One frame of a run being drawn. NaN stands for no pitch.
nonisolated struct AudioDebugFrameRow: Sendable {
    var now: UInt64
    var beat: Double
    var target: Double
    var shown: Double
}
