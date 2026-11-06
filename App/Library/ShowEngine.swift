import Foundation

/// The slice of `PlaybackEngine` that `ShowController` drives. Lets tests substitute a fake
/// (PlaybackEngine is final). PlaybackEngine conforms as-is.
protocol ShowEngine: AnyObject {
    var routing: ChannelRouting { get set }
    var transport: TransportState { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var onItemFinished: (() -> Void)? { get set }
    func load(_ source: EngineSource, routing: ChannelRouting) throws
    func play()
    func stop()
    func seek(to time: TimeInterval)
}

extension PlaybackEngine: ShowEngine {}
