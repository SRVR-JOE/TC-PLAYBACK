import Foundation
import Synchronization
import TCKit

/// Which source the render thread is playing.
enum RenderSourceKind: Int {
    case none = 0, file = 1, generator = 2
}

/// Render-thread-owned mutable state. Lives behind an `UnsafeMutablePointer` so the render
/// block touches it without Swift exclusivity checks, retain/release or copy-on-write.
struct RenderState {
    var routingBits: UInt64
    var ramp: GainRamp
    var transport = ScalarRamp(0)
    var master = ScalarRamp(1)
    var masterFadeHandled = 0
    var masterFadePending = false
    // File seek handshake
    var handledSeekGen = 0
    var ackedSeekGen = 0
    var segStart = 0
    var segMark = 0
    var tailLen = 0
    var tailPos = 0
    var tailGain: Float = 0
    var finishedReported = false
    // Generator
    var genFrames = 0
    var genLocateHandled = 0
    var genFinished = false
    // Meters (mean-square, one-pole smoothed)
    var msSrcL: Float = 0, msSrcR: Float = 0, msOutL: Float = 0, msOutR: Float = 0
}

/// Written by the main thread ONLY while the source kind is `.none` and the render thread
/// has acknowledged quiescence (see `RenderCore.quiesce`).
struct RenderConfig {
    var encoder: Unmanaged<LTCEncoder>?
    var genSide: OutputSide = .right
    /// Generator length in frames; -1 = open-ended.
    var genDurationFrames = -1
}

/// The real-time heart of the engine: everything the AVAudioSourceNode render block touches.
///
/// Main → render communication is via atomics only. The render function never allocates,
/// locks, prints, sends ObjC messages, or touches Swift arrays.
final class RenderCore: @unchecked Sendable {
    let sampleRate: Double
    static let maxChunk = 4096
    let routingRampFrames: Int
    let transportRampFrames: Int
    /// Streamed file audio (deinterleaved L/R, ≈ 2.7 s at 48 kHz).
    let ring: SPSCRingBuffer
    /// Source L/R samples for the timecode readers and scope.
    let analysisRing: SPSCRingBuffer
    /// Post-mix output tap (what leaves for the device), written only while `outputTapEnabled`.
    /// Read by the Scope page. Additive.
    let outputTap: SPSCRingBuffer
    let outputTapEnabled = Atomic<Bool>(false)
    let outputTapClock = TapClock()
    /// Cue caller voices, mixed onto hardware channels after program routing. Additive.
    let callMixer: CueCallMixer

    // MARK: Control (main → render)
    let sourceKind = Atomic<Int>(0)
    let configGen = Atomic<Int>(0)
    let seenConfigGen = Atomic<Int>(0)
    let routingBits: Atomic<UInt64>
    let runRequested = Atomic<Bool>(false)
    let masterFadeGen = Atomic<Int>(0)
    /// Frames of the requested master fade; 0 = restore to unity immediately.
    let masterFadeFrames = Atomic<Int>(0)

    // MARK: Seek handshake (main/producer ↔ render)
    let seekRequestGen = Atomic<Int>(0)
    let seekTarget = Atomic<Int>(0)
    let seekAckGen = Atomic<Int>(0)
    let segSeq = Atomic<Int>(0)
    let segGen = Atomic<Int>(0)
    let segStart = Atomic<Int>(0)
    let segMark = Atomic<Int>(0)
    /// Absolute ring index where the file ends (Int.max = not reached yet).
    let eofMark = Atomic<Int>(Int.max)

    // MARK: Generator control
    let genLocateGen = Atomic<Int>(0)
    let genLocateFrames = Atomic<Int>(0)
    let genLocateTC = Atomic<Int>(0)

    // MARK: Render → main
    let handledSeekGenOut = Atomic<Int>(0)
    let positionFrames = Atomic<Int>(0)
    let finished = Atomic<Bool>(false)
    let masterFadeDoneGen = Atomic<Int>(0)
    let renderedFrames = Atomic<Int>(0)
    let underruns = Atomic<Int>(0)
    /// Absolute frame number of the timecode the generator will render next.
    let genFrameNumber = Atomic<Int>(0)
    let srcPeakL = Atomic<UInt32>(0), srcPeakR = Atomic<UInt32>(0)
    let outPeakL = Atomic<UInt32>(0), outPeakR = Atomic<UInt32>(0)
    let srcMSL = Atomic<UInt32>(0), srcMSR = Atomic<UInt32>(0)
    let outMSL = Atomic<UInt32>(0), outMSR = Atomic<UInt32>(0)
    let clipL = Atomic<Bool>(false), clipR = Atomic<Bool>(false)

    // MARK: Render-owned storage
    let state: UnsafeMutablePointer<RenderState>
    let config: UnsafeMutablePointer<RenderConfig>
    private let srcL: UnsafeMutablePointer<Float>
    private let srcR: UnsafeMutablePointer<Float>
    private let genBuf: UnsafeMutablePointer<Float>
    private let tailL: UnsafeMutablePointer<Float>
    private let tailR: UnsafeMutablePointer<Float>
    private let msCoef: Float
    /// Retains the encoder referenced by `config.encoder`.
    private var encoderOwner: LTCEncoder?

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        callMixer = CueCallMixer(sampleRate: sampleRate)
        routingRampFrames = max(1, Int(sampleRate * 0.010))
        transportRampFrames = min(Self.maxChunk, max(1, Int(sampleRate * 0.005)))
        ring = SPSCRingBuffer(channels: 2, minimumCapacity: Int(sampleRate * 2.5))
        analysisRing = SPSCRingBuffer(channels: 2, minimumCapacity: Int(sampleRate * 1.0))
        outputTap = SPSCRingBuffer(channels: 2, minimumCapacity: Int(sampleRate * 2.0))
        let initialBits = RoutingMath.pack(ChannelRouting())
        routingBits = Atomic<UInt64>(initialBits)
        state = .allocate(capacity: 1)
        state.initialize(to: RenderState(routingBits: initialBits,
                                         ramp: GainRamp(rampFrames: routingRampFrames,
                                                        initial: RoutingMath.matrix(for: ChannelRouting()))))
        config = .allocate(capacity: 1)
        config.initialize(to: RenderConfig())
        func buf() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxChunk)
            p.initialize(repeating: 0, count: Self.maxChunk)
            return p
        }
        srcL = buf(); srcR = buf(); genBuf = buf(); tailL = buf(); tailR = buf()
        msCoef = Float(1 - exp(-1 / (0.3 * sampleRate)))
    }

    deinit {
        state.deinitialize(count: 1); state.deallocate()
        config.deinitialize(count: 1); config.deallocate()
        for p in [srcL, srcR, genBuf, tailL, tailR] { p.deallocate() }
    }

    // MARK: - Main-thread control API

    var kind: RenderSourceKind { RenderSourceKind(rawValue: sourceKind.load(ordering: .acquiring)) ?? .none }

    func setRouting(_ r: ChannelRouting) { routingBits.store(RoutingMath.pack(r), ordering: .releasing) }
    func setRun(_ run: Bool) { runRequested.store(run, ordering: .releasing) }

    /// Detaches the current source and waits until the render thread is guaranteed not to be
    /// using any per-source state. `renderActive` = the render callback is currently being called.
    func quiesce(renderActive: Bool) {
        runRequested.store(false, ordering: .releasing)
        sourceKind.store(RenderSourceKind.none.rawValue, ordering: .sequentiallyConsistent)
        let g = configGen.load(ordering: .relaxed) &+ 1
        configGen.store(g, ordering: .sequentiallyConsistent)
        guard renderActive else { return }
        let deadline = Date().addingTimeInterval(0.25)
        while seenConfigGen.load(ordering: .sequentiallyConsistent) != g && Date() < deadline {
            usleep(500)
        }
    }

    /// Install a generator. Call only after `quiesce`.
    func configureGenerator(encoder: LTCEncoder, side: OutputSide, durationFrames: Int, startFrameNumber: Int) {
        encoderOwner = encoder
        config.pointee.encoder = Unmanaged.passUnretained(encoder)
        config.pointee.genSide = side
        config.pointee.genDurationFrames = durationFrames
        // The render thread resets its generator counters when it sees a new locate generation.
        requestGeneratorLocate(frames: 0, timecodeFrameNumber: startFrameNumber)
    }

    func clearGenerator() {
        config.pointee.encoder = nil
        encoderOwner = nil
    }

    /// Activate a source after configuring it.
    func activate(_ k: RenderSourceKind) {
        finished.store(false, ordering: .releasing)
        sourceKind.store(k.rawValue, ordering: .sequentiallyConsistent)
    }

    @discardableResult
    func requestSeek(toFrame frame: Int) -> Int {
        finished.store(false, ordering: .releasing)
        seekTarget.store(max(0, frame), ordering: .sequentiallyConsistent)
        let g = seekRequestGen.load(ordering: .relaxed) &+ 1
        seekRequestGen.store(g, ordering: .sequentiallyConsistent)
        return g
    }

    func requestGeneratorLocate(frames: Int, timecodeFrameNumber: Int) {
        finished.store(false, ordering: .releasing)
        genLocateFrames.store(frames, ordering: .sequentiallyConsistent)
        genLocateTC.store(timecodeFrameNumber, ordering: .sequentiallyConsistent)
        genFrameNumber.store(timecodeFrameNumber, ordering: .releasing)
        positionFrames.store(frames, ordering: .releasing)
        let g = genLocateGen.load(ordering: .relaxed) &+ 1
        genLocateGen.store(g, ordering: .sequentiallyConsistent)
    }

    /// Fade every output to silence over `frames`; `frames == 0` restores unity gain at once.
    @discardableResult
    func requestMasterFade(frames: Int) -> Int {
        masterFadeFrames.store(frames, ordering: .sequentiallyConsistent)
        let g = masterFadeGen.load(ordering: .relaxed) &+ 1
        masterFadeGen.store(g, ordering: .sequentiallyConsistent)
        return g
    }

    // MARK: - Producer (file reader thread) API

    /// Waits (bounded) for the render thread to freeze its read index for seek `gen`.
    func producerAwaitSeekAck(_ gen: Int, renderActive: Bool) {
        let deadline = Date().addingTimeInterval(renderActive ? 0.05 : 0.0)
        while seekAckGen.load(ordering: .sequentiallyConsistent) != gen && Date() < deadline {
            usleep(250)
        }
    }

    func publishSegment(gen: Int, start: Int, mark: Int) {
        let s = segSeq.load(ordering: .relaxed)
        segSeq.store(s &+ 1, ordering: .sequentiallyConsistent)
        segGen.store(gen, ordering: .sequentiallyConsistent)
        segStart.store(start, ordering: .sequentiallyConsistent)
        segMark.store(mark, ordering: .sequentiallyConsistent)
        segSeq.store(s &+ 2, ordering: .sequentiallyConsistent)
    }

    // MARK: - Render (REAL-TIME THREAD)

    /// Render `frames` frames into the two output channel buffers. Real-time safe.
    func render(frames: Int, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>) {
        render(frames: frames, outL: outL, outR: outR, hostTime: 0)
    }

    /// As above; `hostTime` (mach ticks of the buffer's first frame, 0 = unknown) anchors the
    /// post-mix output tap in host time so it can be lined up against the input.
    func render(frames: Int, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, hostTime: UInt64) {
        seenConfigGen.store(configGen.load(ordering: .sequentiallyConsistent), ordering: .sequentiallyConsistent)
        let tapOn = outputTapEnabled.load(ordering: .relaxed)
        if tapOn { outputTapClock.note(hostTime: hostTime, frameIndex: outputTap.totalWritten, sampleRate: sampleRate) }
        var offset = 0
        while offset < frames {
            let n = min(Self.maxChunk, frames - offset)
            renderChunk(n, outL + offset, outR + offset)
            offset += n
        }
    }

    @inline(__always)
    private static func raisePeak(_ a: borrowing Atomic<UInt32>, _ v: Float) {
        var cur = a.load(ordering: .relaxed)
        while Float(bitPattern: cur) < v {
            let (done, orig) = a.compareExchange(expected: cur, desired: v.bitPattern, ordering: .relaxed)
            if done { break }
            cur = orig
        }
    }

    private func renderChunk(_ n: Int, _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>) {
        let st = state
        srcL.update(repeating: 0, count: n)
        srcR.update(repeating: 0, count: n)

        // Routing target
        let bits = routingBits.load(ordering: .acquiring)
        if bits != st.pointee.routingBits {
            st.pointee.routingBits = bits
            st.pointee.ramp.setTarget(RoutingMath.matrix(for: RoutingMath.unpack(bits)))
        }
        // Master (panic) fade
        let mfg = masterFadeGen.load(ordering: .sequentiallyConsistent)
        if mfg != st.pointee.masterFadeHandled {
            st.pointee.masterFadeHandled = mfg
            let f = masterFadeFrames.load(ordering: .sequentiallyConsistent)
            if f <= 0 {
                st.pointee.master.snap(to: 1)
                st.pointee.masterFadePending = false
            } else {
                st.pointee.master.ramp(to: 0, frames: f)
                st.pointee.masterFadePending = true
            }
        }

        let run = runRequested.load(ordering: .acquiring)
        let kind = sourceKind.load(ordering: .sequentiallyConsistent)
        if kind == RenderSourceKind.file.rawValue {
            renderFile(n, run: run)
        } else if kind == RenderSourceKind.generator.rawValue {
            renderGenerator(n, run: run)
        } else {
            st.pointee.transport.snap(to: 0)
        }

        // Source meters + analysis
        var pl: Float = 0, pr: Float = 0
        var msl = st.pointee.msSrcL, msr = st.pointee.msSrcR
        let a = msCoef
        for i in 0..<n {
            let l = srcL[i], r = srcR[i]
            let al = abs(l), ar = abs(r)
            if al > pl { pl = al }
            if ar > pr { pr = ar }
            msl += a * (l * l - msl)
            msr += a * (r * r - msr)
        }
        st.pointee.msSrcL = msl; st.pointee.msSrcR = msr
        Self.raisePeak(srcPeakL, pl); Self.raisePeak(srcPeakR, pr)
        srcMSL.store(msl.bitPattern, ordering: .relaxed); srcMSR.store(msr.bitPattern, ordering: .relaxed)
        analysisRing.write(srcL, srcR, count: n)

        // Routing → output
        st.pointee.ramp.process(srcL: srcL, srcR: srcR, outL: outL, outR: outR, count: n)
        st.pointee.master.apply(outL, outR, count: n)
        if st.pointee.masterFadePending && st.pointee.master.isSettled {
            st.pointee.masterFadePending = false
            masterFadeDoneGen.store(st.pointee.masterFadeHandled, ordering: .releasing)
        }

        // Output meters + clip
        var ol: Float = 0, or: Float = 0
        var msol = st.pointee.msOutL, msor = st.pointee.msOutR
        for i in 0..<n {
            let l = outL[i], r = outR[i]
            let al = abs(l), ar = abs(r)
            if al > ol { ol = al }
            if ar > or { or = ar }
            msol += a * (l * l - msol)
            msor += a * (r * r - msor)
        }
        st.pointee.msOutL = msol; st.pointee.msOutR = msor
        Self.raisePeak(outPeakL, ol); Self.raisePeak(outPeakR, or)
        outMSL.store(msol.bitPattern, ordering: .relaxed); outMSR.store(msor.bitPattern, ordering: .relaxed)
        if ol >= 0.999 { clipL.store(true, ordering: .relaxed) }
        if or >= 0.999 { clipR.store(true, ordering: .relaxed) }
        if outputTapEnabled.load(ordering: .relaxed) { outputTap.write(outL, outR, count: n) }

        renderedFrames.wrappingAdd(n, ordering: .releasing)
    }

    private func renderFile(_ n: Int, run: Bool) {
        let st = state
        let req = seekRequestGen.load(ordering: .sequentiallyConsistent)
        if req != st.pointee.handledSeekGen {
            if st.pointee.ackedSeekGen != req {
                // Freeze the read index. Capture a short tail to fade out (no consumption).
                if st.pointee.tailPos >= st.pointee.tailLen {
                    let g = st.pointee.transport.value
                    st.pointee.tailLen = g > 0 ? ring.peek(tailL, tailR, count: transportRampFrames) : 0
                    st.pointee.tailPos = 0
                    st.pointee.tailGain = g
                }
                st.pointee.ackedSeekGen = req
                seekAckGen.store(req, ordering: .sequentiallyConsistent)
            }
            // Has the producer published the new segment?
            let s1 = segSeq.load(ordering: .sequentiallyConsistent)
            var picked = false
            if s1 & 1 == 0 {
                let g = segGen.load(ordering: .sequentiallyConsistent)
                let start = segStart.load(ordering: .sequentiallyConsistent)
                let mark = segMark.load(ordering: .sequentiallyConsistent)
                let s2 = segSeq.load(ordering: .sequentiallyConsistent)
                if s1 == s2 && g == req {
                    st.pointee.segStart = start
                    st.pointee.segMark = mark
                    st.pointee.handledSeekGen = req
                    st.pointee.finishedReported = false
                    st.pointee.transport.snap(to: 0) // fade the new material in
                    st.pointee.tailLen = 0; st.pointee.tailPos = 0
                    positionFrames.store(start, ordering: .releasing)
                    handledSeekGenOut.store(req, ordering: .releasing)
                    picked = true
                }
            }
            if !picked {
                // Play out the faded tail of the old material while we wait.
                let remaining = st.pointee.tailLen - st.pointee.tailPos
                if remaining > 0 {
                    let k = min(n, remaining)
                    let total = Float(st.pointee.tailLen)
                    let g0 = st.pointee.tailGain
                    for i in 0..<k {
                        let p = Float(st.pointee.tailPos + i)
                        let g = g0 * (1 - p / total)
                        srcL[i] = tailL[st.pointee.tailPos + i] * g
                        srcR[i] = tailR[st.pointee.tailPos + i] * g
                    }
                    st.pointee.tailPos += k
                }
                st.pointee.transport.snap(to: 0)
                return
            }
        }

        let target: Float = run ? 1 : 0
        st.pointee.transport.ramp(to: target, frames: transportRampFrames)
        if !run && st.pointee.transport.isSettled && st.pointee.transport.value == 0 { return }

        let got = ring.read(srcL, srcR, count: n)
        if got < n {
            let eof = eofMark.load(ordering: .acquiring)
            if ring.totalRead >= eof {
                if !st.pointee.finishedReported {
                    st.pointee.finishedReported = true
                    finished.store(true, ordering: .releasing)
                }
            } else if run {
                underruns.wrappingAdd(1, ordering: .relaxed)
            }
        }
        st.pointee.transport.apply(srcL, srcR, count: n)
        positionFrames.store(st.pointee.segStart + (ring.totalRead - st.pointee.segMark), ordering: .releasing)
    }

    private func renderGenerator(_ n: Int, run: Bool) {
        let st = state
        let cfg = config
        guard let enc = cfg.pointee.encoder?.takeUnretainedValue() else { return }
        let lg = genLocateGen.load(ordering: .sequentiallyConsistent)
        if lg != st.pointee.genLocateHandled {
            st.pointee.genLocateHandled = lg
            st.pointee.genFrames = genLocateFrames.load(ordering: .sequentiallyConsistent)
            let fn = genLocateTC.load(ordering: .sequentiallyConsistent)
            enc.locate(to: Timecode(frameNumber: fn, rate: enc.rate))
            st.pointee.genFinished = false
        }
        guard run, !st.pointee.genFinished else { return }
        var k = n
        let dur = cfg.pointee.genDurationFrames
        if dur >= 0 { k = max(0, min(n, dur - st.pointee.genFrames)) }
        if k > 0 {
            enc.render(into: UnsafeMutableBufferPointer(start: genBuf, count: k))
            switch cfg.pointee.genSide {
            case .left: srcL.update(from: genBuf, count: k)
            case .right: srcR.update(from: genBuf, count: k)
            case .both: srcL.update(from: genBuf, count: k); srcR.update(from: genBuf, count: k)
            }
            st.pointee.genFrames += k
            positionFrames.store(st.pointee.genFrames, ordering: .releasing)
            genFrameNumber.store(enc.currentTimecode.frameNumber, ordering: .releasing)
        }
        if dur >= 0 && st.pointee.genFrames >= dur {
            st.pointee.genFinished = true
            finished.store(true, ordering: .releasing)
        }
    }

    // MARK: - Snapshot helpers (main thread)

    func takePeaks() -> (sl: Float, sr: Float, ol: Float, or: Float) {
        (Float(bitPattern: srcPeakL.exchange(0, ordering: .relaxed)),
         Float(bitPattern: srcPeakR.exchange(0, ordering: .relaxed)),
         Float(bitPattern: outPeakL.exchange(0, ordering: .relaxed)),
         Float(bitPattern: outPeakR.exchange(0, ordering: .relaxed)))
    }

    func rms() -> (sl: Float, sr: Float, ol: Float, or: Float) {
        (sqrtf(Float(bitPattern: srcMSL.load(ordering: .relaxed))),
         sqrtf(Float(bitPattern: srcMSR.load(ordering: .relaxed))),
         sqrtf(Float(bitPattern: outMSL.load(ordering: .relaxed))),
         sqrtf(Float(bitPattern: outMSR.load(ordering: .relaxed))))
    }
}
