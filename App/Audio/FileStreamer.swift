import AVFoundation
import Synchronization

/// Streams an audio file into `RenderCore.ring` on its own thread, converting to the render
/// sample rate with AVAudioConverter. Keeps ≈ 2 s buffered ahead of the render position.
final class FileStreamer: @unchecked Sendable {
    enum StreamError: LocalizedError {
        case unsupportedFormat
        var errorDescription: String? { "This audio file's format can't be played." }
    }

    let file: AVAudioFile
    let core: RenderCore
    let fileRate: Double
    let outRate: Double
    let channelCount: Int
    /// Length in render-rate frames.
    let lengthFrames: Int
    var duration: TimeInterval { Double(file.length) / fileRate }

    private let chunk = 4096
    private let converter: AVAudioConverter?
    private let inBuffer: AVAudioPCMBuffer
    private let outBuffer: AVAudioPCMBuffer
    private var inputDrained = false
    private var eof = false
    private var handledSeekGen = 0
    private var thread: Thread?
    private let stopFlag = Atomic<Bool>(false)
    private let finishedSignal = DispatchSemaphore(value: 0)
    /// Lets the producer skip the seek-ack wait when the render callback isn't running.
    var renderActive: () -> Bool = { true }

    init(url: URL, core: RenderCore) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.core = core
        let pf = file.processingFormat
        fileRate = pf.sampleRate
        outRate = core.sampleRate
        channelCount = Int(pf.channelCount)
        guard channelCount >= 1, fileRate > 0 else { throw StreamError.unsupportedFormat }
        lengthFrames = Int((Double(file.length) * outRate / fileRate).rounded(.down))
        let inFrames = AVAudioFrameCount(Double(chunk) * fileRate / outRate) + 64
        guard let inb = AVAudioPCMBuffer(pcmFormat: pf, frameCapacity: inFrames) else { throw StreamError.unsupportedFormat }
        inBuffer = inb
        if abs(fileRate - outRate) < 0.5 {
            converter = nil
            guard let ob = AVAudioPCMBuffer(pcmFormat: pf, frameCapacity: AVAudioFrameCount(chunk)) else { throw StreamError.unsupportedFormat }
            outBuffer = ob
        } else {
            guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outRate,
                                             channels: pf.channelCount, interleaved: false),
                  let conv = AVAudioConverter(from: pf, to: outFmt),
                  let ob = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(chunk))
            else { throw StreamError.unsupportedFormat }
            conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = conv
            outBuffer = ob
        }
    }

    deinit { stop() }

    var needsResampling: Bool { converter != nil }

    // MARK: Lifecycle

    /// Synchronously fill the start of the stream (≈ 1 s) and publish the first segment, so GO
    /// is instant. Call after `core.quiesce` + `core.ring.reset()`, before `start()`.
    func prime(startFrame: Int = 0) {
        let gen = core.requestSeek(toFrame: startFrame)
        performSeek(gen: gen, target: startFrame, awaitAck: false, prefill: Int(outRate))
    }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "TCPlayback.FileStreamer"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stops the thread and waits for it to exit.
    func stop() {
        guard thread != nil else { return }
        stopFlag.store(true, ordering: .sequentiallyConsistent)
        _ = finishedSignal.wait(timeout: .now() + 1)
        thread = nil
    }

    private func run() {
        while !stopFlag.load(ordering: .sequentiallyConsistent) {
            let req = core.seekRequestGen.load(ordering: .sequentiallyConsistent)
            if req != handledSeekGen {
                let target = core.seekTarget.load(ordering: .sequentiallyConsistent)
                performSeek(gen: req, target: target, awaitAck: true, prefill: chunk * 2)
                continue
            }
            if !fillAvailable(limit: Int.max) { usleep(5_000) }
        }
        finishedSignal.signal()
    }

    // MARK: Streaming

    private func performSeek(gen: Int, target: Int, awaitAck: Bool, prefill: Int) {
        if awaitAck { core.producerAwaitSeekAck(gen, renderActive: renderActive()) }
        handledSeekGen = gen
        core.ring.producerDiscardUnread()
        core.eofMark.store(Int.max, ordering: .sequentiallyConsistent)
        let clamped = min(max(0, target), lengthFrames)
        let filePos = AVAudioFramePosition((Double(clamped) * fileRate / outRate).rounded(.down))
        file.framePosition = min(filePos, file.length)
        converter?.reset()
        inputDrained = false
        eof = false
        let mark = core.ring.totalWritten
        _ = fillAvailable(limit: prefill)
        core.publishSegment(gen: gen, start: clamped, mark: mark)
    }

    /// Fills the ring with up to `limit` frames. Returns true if any work was done.
    @discardableResult
    private func fillAvailable(limit: Int) -> Bool {
        guard !eof else { return false }
        var written = 0
        var worked = false
        while written < limit {
            let space = core.ring.writableCount
            if space < chunk { break }
            if core.seekRequestGen.load(ordering: .relaxed) != handledSeekGen, thread != nil, written > 0 { break }
            let got = readChunk()
            worked = true
            if got == 0 {
                eof = true
                core.eofMark.store(core.ring.totalWritten, ordering: .sequentiallyConsistent)
                break
            }
            guard let ch = outBuffer.floatChannelData else { break }
            let l = UnsafePointer(ch[0])
            let r: UnsafePointer<Float>? = channelCount > 1 ? UnsafePointer(ch[1]) : nil
            core.ring.write(l, r, count: got)
            written += got
        }
        return worked
    }

    /// Decodes the next block into `outBuffer`; returns frames produced (0 = end of file).
    private func readChunk() -> Int {
        guard let converter else {
            outBuffer.frameLength = 0
            do { try file.read(into: outBuffer, frameCount: AVAudioFrameCount(chunk)) } catch { return 0 }
            return Int(outBuffer.frameLength)
        }
        outBuffer.frameLength = 0
        var err: NSError?
        let status = converter.convert(to: outBuffer, error: &err) { [unowned self] _, outStatus in
            if inputDrained { outStatus.pointee = .endOfStream; return nil }
            inBuffer.frameLength = 0
            do { try file.read(into: inBuffer, frameCount: inBuffer.frameCapacity) } catch {
                inputDrained = true; outStatus.pointee = .endOfStream; return nil
            }
            if inBuffer.frameLength == 0 {
                inputDrained = true; outStatus.pointee = .endOfStream; return nil
            }
            outStatus.pointee = .haveData
            return inBuffer
        }
        if status == .error { return 0 }
        return Int(outBuffer.frameLength)
    }
}
