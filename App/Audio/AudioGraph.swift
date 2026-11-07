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
        // Cue caller: on a multichannel interface the node carries every hardware output channel
        // (discrete, in order) so calls can go to comms channels. Program still renders on 0/1
        // only; on a stereo output (and offline) the format is unchanged.
        var channels: AVAudioChannelCount = 2
        if manualRenderingFormat == nil {
            let hw = engine.outputNode.outputFormat(forBus: 0).channelCount
            if hw > 2 { channels = min(hw, 64) }
        }
        let made: AVAudioFormat?
        if channels > 2, let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) {
            made = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
        } else {
            made = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)
        }
        guard let fmt = made else {
            throw FileStreamer.StreamError.unsupportedFormat
        }
        format = fmt
        let core = RenderCore(sampleRate: rate)
        self.core = core
        unowned(unsafe) let c = core
        sourceNode = AVAudioSourceNode(format: fmt) { _, timestamp, frameCount, abl -> OSStatus in
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
            let ts = timestamp.pointee
            let host: UInt64 = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : 0
            let posBefore = c.positionFrames.load(ordering: .acquiring)
            c.render(frames: n, outL: l, outR: r, hostTime: host)
            // Channels past the program pair start silent, then the cue caller mixes in.
            if buffers.count > 2 {
                for ch in 2..<buffers.count {
                    buffers[ch].mData?.assumingMemoryBound(to: Float.self).update(repeating: 0, count: n)
                }
            }
            let posAfter = c.positionFrames.load(ordering: .acquiring)
            c.callMixer.mix(buffers, frames: n, trackStart: posAfter - n, trackRunning: posAfter > posBefore)
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: fmt)
        if fmt.channelCount > 2 { engine.connect(engine.mainMixerNode, to: engine.outputNode, format: fmt) }
        engine.mainMixerNode.outputVolume = 1
        #if DEBUG
        // QA: -silentOutput runs the whole engine with the speaker muted at the mixer.
        if ProcessInfo.processInfo.arguments.contains("-silentOutput") { engine.mainMixerNode.outputVolume = 0 }
        #endif
        engine.prepare()
    }

    /// Output channels the graph drives (2 on a stereo output; more on a multichannel interface).
    var channelCount: Int { Int(format.channelCount) }

    /// True while the render callback is being driven by the hardware.
    var isRendering: Bool { engine.isRunning && !engine.isInManualRenderingMode }

    func start() throws {
        if !engine.isRunning { try engine.start() }
    }

    func stop() { engine.stop() }
}
