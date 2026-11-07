import AVFoundation

/// AVAudioEngine + AVAudioSourceNode wired to a `RenderCore`. Used for live output and,
/// with `manualRenderingFormat`, for offline rendering in tests.
final class AudioGraph {
    let engine = AVAudioEngine()
    let core: RenderCore
    let sourceNode: AVAudioSourceNode
    let format: AVAudioFormat

    init(manualRenderingFormat: AVAudioFormat? = nil, maximumFrameCount: AVAudioFrameCount = 4096) throws {
        var rate: Double
        if let manual = manualRenderingFormat {
            try engine.enableManualRenderingMode(.offline, format: manual, maximumFrameCount: maximumFrameCount)
            rate = manual.sampleRate
        } else {
            rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            if rate <= 0 { rate = AVAudioSession.sharedInstance().sampleRate }
            if rate <= 0 { rate = 48_000 }
        }
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false) else {
            throw FileStreamer.StreamError.unsupportedFormat
        }
        format = fmt
        let core = RenderCore(sampleRate: rate)
        self.core = core
        unowned(unsafe) let c = core
        sourceNode = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                if buffers.count == 1, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                    l.update(repeating: 0, count: n)
                }
                return noErr
            }
            c.render(frames: n, outL: l, outR: r)
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 1
        #if DEBUG
        // QA: -silentOutput runs the whole engine with the speaker muted at the mixer.
        if ProcessInfo.processInfo.arguments.contains("-silentOutput") { engine.mainMixerNode.outputVolume = 0 }
        #endif
        engine.prepare()
    }

    /// True while the render callback is being driven by the hardware.
    var isRendering: Bool { engine.isRunning && !engine.isInManualRenderingMode }

    func start() throws {
        if !engine.isRunning { try engine.start() }
    }

    func stop() { engine.stop() }
}
