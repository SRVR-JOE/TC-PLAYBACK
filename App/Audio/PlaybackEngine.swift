import Foundation
import Observation
import TCKit

// CONTRACT FILE — owned by the AUDIO ENGINE agent. Every `public`/internal declaration in
// this file is the API the UI and Library agents are coding against RIGHT NOW. Implement the
// bodies (add any private helpers / new files under App/Audio/), but do not rename, remove or
// change the signature of anything declared here. Additive changes are fine.

/// What the engine is playing.
enum EngineSource: Equatable {
    case none
    /// An audio file on disk (stereo or mono; mono is treated as L only).
    case file(URL)
    /// Generated SMPTE LTC, optionally alongside nothing else.
    case generator(GeneratorConfig)
}

struct GeneratorConfig: Equatable, Codable {
    var start: Timecode
    var rate: FrameRate
    /// nil = run until stopped.
    var duration: TimeInterval?
    /// Which output side carries the generated LTC.
    var side: OutputSide = .right
    /// Peak level in dBFS (spec typical -10…-18).
    var levelDBFS: Float = -10
}

enum OutputSide: String, Codable, CaseIterable, Identifiable {
    case left, right, both
    var id: String { rawValue }
}

/// Per-source-channel routing. Mutes follow the SOURCE channel; `swapped` crosses the pair
/// so the track's L plays out the right side and vice versa.
struct ChannelRouting: Equatable, Codable {
    var leftEnabled: Bool = true
    var rightEnabled: Bool = true
    var swapped: Bool = false
    /// Gain applied to the track in dB (−∞…+6), applied after routing.
    var gainDB: Float = 0
}

enum TransportState: Equatable {
    case stopped, playing, paused
}

/// Where the on-screen timecode comes from.
enum ClockSource: Equatable {
    /// No LTC found — the clock shows track elapsed time.
    case trackTime
    /// LTC decoded from the given source channel of the file.
    case decoded(SourceChannel)
    /// The engine's own LTC generator.
    case generator
    /// LTC read from the device audio input.
    case externalInput
}

enum SourceChannel: String, Codable { case left, right }

/// Display-ready timecode/clock state, updated on the main thread ~30×/s.
struct ClockStatus: Equatable {
    var source: ClockSource = .trackTime
    /// The timecode to draw (nil → draw "--:--:--:--").
    var timecode: Timecode?
    var lock: TCLockState = .noSignal
    var rate: FrameRate?
    var isReverse: Bool = false
    var ltcLevelDBFS: Float?
    var userBits: UInt32 = 0
    var discontinuities: Int = 0
}

/// Lock-free-ish snapshot the visuals pull at display rate. Values are linear 0…1 except
/// where noted. "source" = file channels before routing; "output" = what leaves the device.
struct AnalysisSnapshot {
    var sourcePeak: (l: Float, r: Float) = (0, 0)
    var sourceRMS: (l: Float, r: Float) = (0, 0)
    var outputPeak: (l: Float, r: Float) = (0, 0)
    var outputRMS: (l: Float, r: Float) = (0, 0)
    /// True if a channel clipped (≥ 0.999) since the last `resetClip()`.
    var outputClip: (l: Bool, r: Bool) = (false, false)
    /// Most recent N samples per SOURCE channel (oldest first), for the oscilloscope.
    /// N == `AnalysisSnapshot.scopeLength`.
    var scopeL: [Float] = []
    var scopeR: [Float] = []
    static let scopeLength = 2048
    var sampleRate: Double = 48_000
}

@Observable
final class PlaybackEngine {
    static let shared = PlaybackEngine()

    // MARK: Observable state (main thread)
    private(set) var transport: TransportState = .stopped
    private(set) var source: EngineSource = .none
    /// Seconds into the current item.
    private(set) var currentTime: TimeInterval = 0
    /// Seconds; 0 for an open-ended generator.
    private(set) var duration: TimeInterval = 0
    private(set) var clock = ClockStatus()
    /// Channel count of the loaded file (1 or 2).
    private(set) var sourceChannelCount: Int = 2
    /// Human-readable current output route, e.g. "Headphones", "USB Audio Interface".
    private(set) var outputRouteName: String = "Speaker"
    /// Last error message suitable for an operator alert; nil when fine.
    var lastError: String?

    /// Live routing for the current item. Setting it applies immediately (click-free ramp).
    var routing = ChannelRouting()

    /// When true, LTC is decoded from both file channels and the clock follows whichever locks.
    var autoDetectTimecode: Bool = true
    /// Read LTC from the device audio input instead of the file (shows `.externalInput`).
    var readExternalInput: Bool = false

    /// Called on the main thread when an item reaches its end naturally (not on stop()).
    var onItemFinished: (() -> Void)?

    init() {}

    // MARK: Transport
    func load(_ source: EngineSource, routing: ChannelRouting = ChannelRouting()) throws {
        self.source = source
        self.routing = routing
    }
    func play() { transport = .playing }
    func pause() { transport = .paused }
    func stop() { transport = .stopped; currentTime = 0 }
    func togglePlayPause() { transport == .playing ? pause() : play() }
    func seek(to time: TimeInterval) { currentTime = time }
    func skip(by delta: TimeInterval) { seek(to: max(0, currentTime + delta)) }

    // MARK: Analysis
    /// Called by visuals from a TimelineView/display link. Must be cheap (copy only).
    func analysisSnapshot() -> AnalysisSnapshot { AnalysisSnapshot() }
    func resetClip() {}
}
