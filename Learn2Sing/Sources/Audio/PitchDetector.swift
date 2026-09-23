import AVFoundation
import Accelerate
import Combine
import Synchronization
import os

/// Listens to the microphone and estimates the fundamental frequency the user is
/// singing, exposed as a (possibly fractional) MIDI note number. The estimating is
/// `PitchAnalyzer`'s; this class gets the audio to it as soon as the phone has it.
///
/// That is the part that decides how late the singer's line is. An input tap, which
/// this used to listen through, hands its audio over in blocks of at least 100 ms
/// whatever size is asked for, so every estimate was up to a tenth of a second old
/// before the analysis even saw it, and the line only moved ten times a second.
/// A sink node gets each I/O buffer (10 ms on a phone) the moment the hardware
/// delivers it. It does that on the real-time audio thread, where nothing may wait
/// or allocate, so all the node does is copy the buffer into a lock-free queue and
/// wake a thread of its own that does the rest: clap detection, the debug recording
/// and the analysis all run there, off the audio thread, as they did under the tap.
final class PitchDetector: ObservableObject {
    /// Detected pitch as a fractional MIDI note number, or `nil` when silent / unsure.
    // Stored behind a lock rather than published: the view already redraws every
    // frame via TimelineView and reads it then, so publishing ~200×/sec would only
    // flood the main thread and stutter the UI.
    var currentPitch: Double? { listener.pitch }

    /// How far, in milliseconds, the singer's drawn line trails their voice on the
    /// fastest pitch detection: the analysis window's delay, the wait for the next I/O
    /// buffer and the on-screen ease, as measured by replaying recordings against a
    /// look-ahead pitch track. The clap test adds it to what it measures, because claps
    /// are timed from the sound itself while singing is scored from the line. A slower
    /// `detection` holds the line back by its look-ahead on top of this; that part is
    /// added wherever the delay is used rather than saved in it, so the setting means
    /// the same whichever detection it was measured with.
    var lineLatencyMs: Double { usingTap ? 60 : 15 }

    /// The pitch detection this capture runs with: the setting as it stood when the
    /// microphone was last started, so it can't change under a run.
    private(set) var detection = PitchDetection.current

    /// How much later than the fastest detection's this capture's line is drawn.
    var lookAheadMs: Double { detection.extraDelayMs }

    private let engine = AVAudioEngine()
    private var running = false
    /// Whether the microphone is meant to be listening, i.e. between `start()` and
    /// `stop()`. Separate from `running` (which tracks the capture that is actually
    /// set up) so the engine can be brought back after the system stops it.
    private var shouldRun = false
    private var configObserver: NSObjectProtocol?

    /// Set once the system has answered that the microphone may not be used, whether
    /// the singer just tapped "Don't Allow" or turned it off in Settings long ago.
    /// Published, unlike the pitch: it changes at most once per detector, and the
    /// screens that listen put up `microphoneNotice` when it does.
    @Published private(set) var isMicrophoneDenied = false

    /// DEBUG RECORDING — remove together with DebugRecording.swift.
    /// Set while a run is being recorded for debugging: every microphone buffer is
    /// handed to it as it arrives, so the raw input can be written to disk.
    var debugSink: DebugAudioSink? {
        get { listener.debugSink }
        set { listener.debugSink = newValue }
    }

    /// When enabled, sharp loud transients (claps) are timestamped so the delay
    /// test can compare when each clap was *heard* against the metronome tick that
    /// prompted it. Off for ordinary exercises so it never costs anything there.
    var detectClaps: Bool {
        get { listener.detectClaps }
        set { listener.detectClaps = newValue }
    }

    private let listener = MicrophoneListener()
    private var sinkNode: AVAudioSinkNode?
    /// Listening through an input tap instead of the sink node: the fallback for a
    /// route where the sink never receives anything.
    private var usingTap = false
    /// Counts starts, so a check scheduled for one start can tell it has been
    /// overtaken by the next.
    private var startCount = 0

    init() {
        // iOS stops the engine whenever the audio IO is reconfigured — a route
        // change, an interruption ending, the playback engine starting — and nothing
        // brings it back on its own. Without this the capture is gone for the rest of
        // the run while `running` still claims the microphone is live, so the singer's
        // pitch line simply stops moving.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.shouldRun, !self.engine.isRunning else { return }
            self.running = false   // the system stopped it; the capture it left behind is dead
            self.beginListening()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        // The analysis thread holds on to the listener; let it go.
        listener.stop()
    }

    /// Remove and return every clap onset (mach_absolute_time) seen since last call.
    func drainClaps() -> [UInt64] {
        listener.drainClaps()
    }

    func start() {
        shouldRun = true
        // Heal a capture the system stopped without telling us, so resuming after an
        // interruption isn't mistaken for "already listening" and skipped.
        if running && !engine.isRunning { running = false }
        guard !running else { return }
        detection = PitchDetection.current
        // The audio session / route is configured once by PlaybackView before this
        // is called, so we must not reconfigure it here — doing so would switch the
        // route out from under the already-running playback engine.
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    // Nothing to listen to, but whatever asked carries on without
                    // it; telling the singer is up to the screen (`microphoneNotice`).
                    self.isMicrophoneDenied = true
                    return
                }
                // A `stop()` that came in while the answer was on its way — a pause
                // tapped straight after resuming, the app going to the background —
                // found nothing to take down yet. Starting now would leave the
                // microphone listening behind a run that has stopped asking for it.
                guard self.shouldRun else { return }
                self.beginListening()
            }
        }
    }

    func stop() {
        shouldRun = false
        guard running else { return }
        if usingTap { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
        running = false
        listener.stop()
    }

    private func beginListening() {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        debugSink?.begin(format: format)   // DEBUG RECORDING — remove with DebugRecording.swift
        startCount += 1
        if engine.isRunning { engine.stop() }
        input.removeTap(onBus: 0)
        usingTap = false
        listener.start(sampleRate: format.sampleRate, detection: detection)

        let sink: AVAudioSinkNode
        if let existing = sinkNode {
            sink = existing
            engine.disconnectNodeInput(sink)
        } else {
            sink = listener.queue.makeSinkNode()
            engine.attach(sink)
            sinkNode = sink
        }
        engine.connect(input, to: sink, format: format)
        engine.prepare()
        do {
            try engine.start()
            running = true
            confirmAudioArrives(after: startCount)
        } catch {
            listenThroughTap(format: format)
        }
    }

    /// The sink node is the one way to get the microphone without the tap's 100 ms
    /// blocks, but a route it stays silent on would leave the singer with no line at
    /// all. So a start that has heard nothing after a moment switches to the tap: late,
    /// but working. The wait allows for a Bluetooth route, which can take a while to
    /// start delivering; an exercise's lead-in is longer than it.
    private func confirmAudioArrives(after start: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.running, !self.usingTap, self.startCount == start,
                  !self.listener.queue.hasReceivedAudio else { return }
            self.engine.stop()
            self.listenThroughTap(format: self.engine.inputNode.outputFormat(forBus: 0))
        }
    }

    private func listenThroughTap(format: AVAudioFormat) {
        if let sink = sinkNode { engine.disconnectNodeInput(sink) }
        running = false
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        listener.start(sampleRate: format.sampleRate, detection: detection)
        usingTap = true
        let input = engine.inputNode
        listener.queue.installTap(on: input, format: format)
        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)
            usingTap = false
            listener.stop()
        }
    }
}

// MARK: - From the audio thread to the analysis thread

/// A single-producer, single-consumer queue of microphone audio: the audio thread
/// appends each buffer as it arrives, the analysis thread takes them out in order.
/// Lock-free and preallocated, so the audio thread never waits and never allocates.
/// Each buffer keeps the time stamp it arrived with, which is what the clap test and
/// the debug recording line the audio up with the playback clock by.
nonisolated final class MicrophoneQueue: @unchecked Sendable {
    struct Chunk {
        var start = 0
        var count = 0
        var time = AudioTimeStamp()
    }

    /// The longest piece a buffer is stored in; a longer buffer (the tap's) is split.
    static let maxChunk = 4096
    private static let sampleCapacity = 1 << 16
    private static let chunkCapacity = 1 << 9

    private let samples: UnsafeMutablePointer<Float>
    private let chunks: UnsafeMutablePointer<Chunk>
    // Running totals, never wrapped: chunks and samples written by the audio thread,
    // taken by the analysis thread.
    private let chunksWritten = Atomic<Int>(0)
    private let chunksTaken = Atomic<Int>(0)
    private let samplesTaken = Atomic<Int>(0)
    private var samplesWritten = 0      // the audio thread's alone
    /// Bumped by every `reset`. A tap hands its blocks over on a queue of its own,
    /// so one can still arrive after the tap is removed; it carries the generation it
    /// was installed in and is ignored once that has passed, so the queue never has
    /// two writers.
    private let generation = Atomic<Int>(0)
    private let wakeUp = DispatchSemaphore(value: 0)
    /// Host-clock ticks per sample, for timing the later pieces of a split buffer.
    private var ticksPerSample = 0.0

    init() {
        samples = .allocate(capacity: Self.sampleCapacity)
        samples.initialize(repeating: 0, count: Self.sampleCapacity)
        chunks = .allocate(capacity: Self.chunkCapacity)
        chunks.initialize(repeating: Chunk(), count: Self.chunkCapacity)
    }

    deinit {
        samples.deinitialize(count: Self.sampleCapacity)
        samples.deallocate()
        chunks.deinitialize(count: Self.chunkCapacity)
        chunks.deallocate()
    }

    /// Whether anything has arrived since the last `reset`.
    var hasReceivedAudio: Bool { chunksWritten.load(ordering: .sequentiallyConsistent) > 0 }

    /// Empty the queue for a new capture. Only while neither side is running.
    func reset(sampleRate: Double) {
        generation.add(1, ordering: .sequentiallyConsistent)
        chunksWritten.store(0, ordering: .sequentiallyConsistent)
        chunksTaken.store(0, ordering: .sequentiallyConsistent)
        samplesTaken.store(0, ordering: .sequentiallyConsistent)
        samplesWritten = 0
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksPerSample = 1e9 / sampleRate * Double(timebase.denom) / Double(timebase.numer)
        while wakeUp.wait(timeout: .now()) == .success {}
    }

    /// Audio thread: append `count` frames, reading every `stride`th sample of `data`
    /// (the first channel of an interleaved buffer). A buffer that doesn't fit is
    /// dropped rather than waited for.
    func push(_ data: UnsafePointer<Float>, count: Int, stride: Int, time: AudioTimeStamp) {
        var offset = 0
        while offset < count {
            let n = min(count - offset, Self.maxChunk)
            let written = chunksWritten.load(ordering: .sequentiallyConsistent)
            let taken = chunksTaken.load(ordering: .sequentiallyConsistent)
            let free = Self.sampleCapacity - (samplesWritten - samplesTaken.load(ordering: .sequentiallyConsistent))
            guard written - taken < Self.chunkCapacity, n <= free else { break }

            let start = samplesWritten
            let mask = Self.sampleCapacity - 1
            if stride == 1 {
                let first = min(n, Self.sampleCapacity - (start & mask))
                (samples + (start & mask)).update(from: data + offset, count: first)
                if first < n { samples.update(from: data + offset + first, count: n - first) }
            } else {
                for i in 0..<n { samples[(start + i) & mask] = data[(offset + i) * stride] }
            }
            var stamp = time
            if offset > 0 {
                stamp.mSampleTime += Double(offset)
                stamp.mHostTime &+= UInt64(Double(offset) * ticksPerSample)
            }
            chunks[written & (Self.chunkCapacity - 1)] = Chunk(start: start, count: n, time: stamp)
            samplesWritten = start + n
            chunksWritten.store(written + 1, ordering: .sequentiallyConsistent)
            offset += n
        }
        wakeUp.signal()
    }

    /// Analysis thread: the oldest buffer, copied into `destination` (room for
    /// `maxChunk` samples), or nil when there is none.
    func pop(into destination: UnsafeMutablePointer<Float>) -> Chunk? {
        let written = chunksWritten.load(ordering: .sequentiallyConsistent)
        let taken = chunksTaken.load(ordering: .sequentiallyConsistent)
        guard taken < written else { return nil }
        let chunk = chunks[taken & (Self.chunkCapacity - 1)]
        let mask = Self.sampleCapacity - 1
        let first = min(chunk.count, Self.sampleCapacity - (chunk.start & mask))
        destination.update(from: samples + (chunk.start & mask), count: first)
        if first < chunk.count { (destination + first).update(from: samples, count: chunk.count - first) }
        samplesTaken.store(chunk.start + chunk.count, ordering: .sequentiallyConsistent)
        chunksTaken.store(taken + 1, ordering: .sequentiallyConsistent)
        return chunk
    }

    /// Analysis thread: sleep until the audio thread has pushed (or `wake` is called).
    func waitForAudio() {
        wakeUp.wait()
    }

    func wake() {
        wakeUp.signal()
    }

    /// The node that feeds this queue. Made here rather than by the detector so its
    /// block belongs to no actor: it runs on the real-time audio thread.
    func makeSinkNode() -> AVAudioSinkNode {
        AVAudioSinkNode { [self] timestamp, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            guard let first = buffers.first, let data = first.mData else { return noErr }
            let channels = max(1, Int(first.mNumberChannels))
            let frames = min(Int(frameCount), Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            self.push(data.assumingMemoryBound(to: Float.self), count: frames, stride: channels,
                      time: timestamp.pointee)
            return noErr
        }
    }

    /// The fallback: the same queue fed from an input tap, in the tap's large blocks.
    func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let installed = generation.load(ordering: .sequentiallyConsistent)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [self] buffer, time in
            guard self.generation.load(ordering: .sequentiallyConsistent) == installed,
                  let data = buffer.floatChannelData?[0] else { return }
            self.push(data, count: Int(buffer.frameLength), stride: 1, time: time.audioTimeStamp)
        }
    }
}

// MARK: - The analysis thread

/// Everything that happens to the microphone's audio once it is off the audio
/// thread, on a thread of its own: clap detection for the delay test, the debug
/// recording, and the pitch analysis. The pitch and the claps are handed back
/// behind locks; the rest belongs to that thread.
nonisolated final class MicrophoneListener: @unchecked Sendable {
    let queue = MicrophoneQueue()

    private let pitchValue = Mutex<Double?>(nil)
    private let clapTimes = Mutex<[UInt64]>([])
    private let clapsWanted = Atomic<Bool>(false)

    private var thread: Thread?
    private let stopRequested = Atomic<Bool>(false)
    private let finished = DispatchSemaphore(value: 0)
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: MicrophoneQueue.maxChunk)

    // Owned by the analysis thread while it runs; replaced by `start`.
    private var analyzer = PitchAnalyzer(sampleRate: 48_000)
    private var sampleRate = 48_000.0

    var pitch: Double? { pitchValue.withLock { $0 } }

    var detectClaps: Bool {
        get { clapsWanted.load(ordering: .sequentiallyConsistent) }
        set { clapsWanted.store(newValue, ordering: .sequentiallyConsistent) }
    }

    deinit {
        scratch.deallocate()
    }

    /// Start a fresh analysis thread for audio at `sampleRate`, ending any previous
    /// one first. Called while the audio is stopped.
    func start(sampleRate rate: Double, detection: PitchDetection) {
        stop()
        sampleRate = rate
        analyzer = PitchAnalyzer(sampleRate: rate, detection: detection)
        queue.reset(sampleRate: rate)
        resetClaps()
        stopRequested.store(false, ordering: .sequentiallyConsistent)
        let worker = Thread { [self] in self.run() }
        worker.name = "Learn2Sing microphone"
        worker.qualityOfService = .userInteractive
        thread = worker
        worker.start()
    }

    /// End the analysis thread (waiting the few milliseconds it may need to finish the
    /// buffer in hand) and clear the pitch.
    func stop() {
        if thread != nil {
            stopRequested.store(true, ordering: .sequentiallyConsistent)
            queue.wake()
            finished.wait()
            thread = nil
        }
        pitchValue.withLock { $0 = nil }
    }

    private func run() {
        while true {
            queue.waitForAudio()
            if stopRequested.load(ordering: .sequentiallyConsistent) { break }
            while let chunk = queue.pop(into: scratch) {
                handle(chunk)
            }
        }
        finished.signal()
    }

    private func handle(_ chunk: MicrophoneQueue.Chunk) {
        let count = chunk.count
        guard count > 0 else { return }
        forwardToDebugSink(chunk)   // DEBUG RECORDING — remove with DebugRecording.swift
        if detectClaps { findClaps(count: count, time: chunk.time) }
        analyzer.process(scratch, count: count)
        let value = analyzer.pitch
        pitchValue.withLock { $0 = value }
    }

    // MARK: Debug recording (DEBUG RECORDING — remove with DebugRecording.swift)

    /// DEBUG RECORDING — remove together with DebugRecording.swift.
    private let debugSinkLock = OSAllocatedUnfairLock<DebugAudioSink?>(uncheckedState: nil)
    /// DEBUG RECORDING — remove together with DebugRecording.swift.
    /// The recorder takes buffers, so each piece is copied into one; its format only
    /// has to carry the sample rate and the single channel the detector analyses.
    private var debugBuffer: AVAudioPCMBuffer?

    /// DEBUG RECORDING — remove together with DebugRecording.swift.
    var debugSink: DebugAudioSink? {
        get { debugSinkLock.withLockUnchecked { $0 } }
        set { debugSinkLock.withLockUnchecked { $0 = newValue } }
    }

    /// DEBUG RECORDING — remove together with DebugRecording.swift.
    private func forwardToDebugSink(_ chunk: MicrophoneQueue.Chunk) {
        guard let sink = debugSink else { return }
        if debugBuffer?.format.sampleRate != sampleRate {
            debugBuffer = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1).flatMap {
                AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: AVAudioFrameCount(MicrophoneQueue.maxChunk))
            }
        }
        guard let buffer = debugBuffer, let channel = buffer.floatChannelData?[0] else { return }
        channel.update(from: scratch, count: chunk.count)
        buffer.frameLength = AVAudioFrameCount(chunk.count)
        var stamp = chunk.time
        sink.append(buffer: buffer, time: AVAudioTime(audioTimeStamp: &stamp, sampleRate: sampleRate))
    }

    // MARK: Clap onset detection (used by the microphone-delay test)

    // A clap is a transient that's both well above the ambient level (so it works
    // regardless of how hot or quiet a given microphone runs) and above a small
    // absolute floor (so quiet background ticks don't register). Detections within
    // `clapMergeWindow` of each other are treated as one clap event, keeping the
    // loudest onset's time — so if the metronome bleeds into the mic just before the
    // user's louder clap, the clap's timing wins instead of the tick's.
    private let clapRatio: Float = 4.0         // times the noise floor to count as a clap
    private let clapAbsMin: Float = 0.02       // absolute floor, below which nothing counts
    private let clapMergeWindow = 0.25         // seconds; onsets closer than this merge
    /// The level is judged over blocks of this length, the size the input tap used to
    /// deliver, so the noise floor and the thresholds behave as they always have.
    private let clapBlockSeconds = 0.1

    private var lastClapHost: UInt64 = 0
    private var lastClapLevel: Float = 0       // loudness of the current clap event
    private var noiseFloor: Float = 0.01       // running estimate of the ambient level
    private var blockFilled = 0
    private var blockPeak: Float = 0
    private var blockPeakHost: UInt64 = 0

    func drainClaps() -> [UInt64] {
        clapTimes.withLock { claps in
            let drained = claps
            claps.removeAll()
            return drained
        }
    }

    private func resetClaps() {
        lastClapHost = 0
        lastClapLevel = 0
        noiseFloor = 0.01
        blockFilled = 0
        blockPeak = 0
        clapTimes.withLock { $0.removeAll() }
    }

    /// Track the loudest sample of each block, with the host time it was captured
    /// at, and judge the block when it is complete. The time is the peak's own rather
    /// than the start of the block (which is where the tap left it): a clap's peak is
    /// within a few milliseconds of its attack.
    private func findClaps(count: Int, time: AudioTimeStamp) {
        let blockLength = max(1, Int(sampleRate * clapBlockSeconds))
        let hostValid = time.mFlags.contains(.hostTimeValid)
        let arrived = mach_absolute_time()
        var done = 0
        while done < count {
            let take = min(count - done, blockLength - blockFilled)
            var peak: Float = 0
            var index: vDSP_Length = 0
            vDSP_maxmgvi(scratch + done, 1, &peak, &index, vDSP_Length(take))
            if peak > blockPeak {
                blockPeak = peak
                blockPeakHost = hostValid
                    ? time.mHostTime &+ hostTicks(forSamples: done + Int(index))
                    : arrived
            }
            done += take
            blockFilled += take
            if blockFilled >= blockLength {
                judgeBlock(peak: blockPeak, host: blockPeakHost)
                blockFilled = 0
                blockPeak = 0
            }
        }
    }

    private func hostTicks(forSamples samples: Int) -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanoseconds = Double(samples) / sampleRate * 1e9
        return UInt64(nanoseconds * Double(timebase.denom) / Double(timebase.numer))
    }

    /// Register a clap when a block's peak rises sharply above the ambient level.
    /// Detection is relative to a slowly tracked noise floor so it adapts to each
    /// microphone's gain (a fixed threshold worked for hot mics like AirPods but
    /// missed quieter built-in mics entirely).
    private func judgeBlock(peak: Float, host: UInt64) {
        // Track the ambient level slowly so a single loud clap barely moves it.
        noiseFloor = max(0.005, noiseFloor * 0.995 + peak * 0.005)

        guard peak > clapAbsMin, peak > noiseFloor * clapRatio else { return }

        if lastClapHost != 0 {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let elapsed = Double(host &- lastClapHost) * Double(timebase.numer)
                / Double(timebase.denom) / 1.0e9
            if elapsed < clapMergeWindow {
                // Same clap event: if this onset is louder, it's closer to the true
                // attack, so move the recorded time to it. Otherwise ignore it.
                guard peak > lastClapLevel else { return }
                lastClapHost = host
                lastClapLevel = peak
                clapTimes.withLock { claps in
                    if !claps.isEmpty { claps[claps.count - 1] = host }
                }
                return
            }
        }
        lastClapHost = host
        lastClapLevel = peak
        clapTimes.withLock { $0.append(host) }
    }
}
