import Foundation
import Synchronization

/// Lock-free single-producer / single-consumer ring buffer of deinterleaved Float channels.
///
/// Real-time safe on both sides: no allocation, no locks, no Swift array access after `init`.
/// Indices are monotonic 64-bit counters (they never wrap in practice); the storage index is
/// `index & mask`. The producer owns `writeIndex`, the consumer owns `readIndex`.
///
/// Producer API: `writableCount`, `copyIn(channel:from:count:)`, `commitWrite(_:)`, `write(...)`.
/// Consumer API: `readableCount`, `copyOut(channel:to:count:offset:)`, `commitRead(_:)`, `read(...)`.
final class SPSCRingBuffer: @unchecked Sendable {
    let channels: Int
    let capacity: Int
    private let mask: Int
    private let data: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    /// `minimumCapacity` is rounded up to a power of two.
    init(channels: Int, minimumCapacity: Int) {
        precondition(channels > 0 && minimumCapacity > 0)
        var cap = 1
        while cap < minimumCapacity { cap <<= 1 }
        self.channels = channels
        self.capacity = cap
        self.mask = cap - 1
        data = .allocate(capacity: cap * channels)
        data.initialize(repeating: 0, count: cap * channels)
    }

    deinit { data.deallocate() }

    // MARK: Indices

    /// Total frames ever committed by the producer.
    var totalWritten: Int { writeIndex.load(ordering: .acquiring) }
    /// Total frames ever consumed.
    var totalRead: Int { readIndex.load(ordering: .acquiring) }

    // MARK: Producer side

    /// Frames the producer may write now.
    var writableCount: Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        return max(0, capacity - (w - r))
    }

    /// Copy `count` frames of `channel` into the slot after the current write index
    /// (not yet visible to the consumer). `src == nil` writes silence.
    func copyIn(channel: Int, from src: UnsafePointer<Float>?, count: Int) {
        let w = writeIndex.load(ordering: .relaxed)
        let base = data + channel * capacity
        let start = w & mask
        let first = min(count, capacity - start)
        if let src {
            (base + start).update(from: src, count: first)
            if count > first { base.update(from: src + first, count: count - first) }
        } else {
            (base + start).update(repeating: 0, count: first)
            if count > first { base.update(repeating: 0, count: count - first) }
        }
    }

    /// Publish `count` frames previously copied in for every channel.
    func commitWrite(_ count: Int) {
        let w = writeIndex.load(ordering: .relaxed)
        writeIndex.store(w + count, ordering: .releasing)
    }

    /// Writes up to `count` frames from up to two channel pointers (nil = silence). Returns frames written.
    @discardableResult
    func write(_ ch0: UnsafePointer<Float>?, _ ch1: UnsafePointer<Float>? = nil, count: Int) -> Int {
        let n = min(count, writableCount)
        guard n > 0 else { return 0 }
        copyIn(channel: 0, from: ch0, count: n)
        if channels > 1 { copyIn(channel: 1, from: ch1, count: n) }
        for c in stride(from: 2, to: channels, by: 1) { copyIn(channel: c, from: nil, count: n) }
        commitWrite(n)
        return n
    }

    /// Producer-side flush: drop everything unread by moving the write index back to the
    /// read index. Only valid while the consumer is not advancing (see RenderCore seek handshake).
    func producerDiscardUnread() {
        writeIndex.store(readIndex.load(ordering: .acquiring), ordering: .releasing)
    }

    // MARK: Consumer side

    /// Frames the consumer may read now.
    var readableCount: Int {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .relaxed)
        return max(0, w - r)
    }

    /// Copy `count` frames of `channel` starting `offset` frames after the read index, without consuming.
    func copyOut(channel: Int, to dst: UnsafeMutablePointer<Float>, count: Int, offset: Int = 0) {
        let r = readIndex.load(ordering: .relaxed) + offset
        let base = data + channel * capacity
        let start = r & mask
        let first = min(count, capacity - start)
        dst.update(from: base + start, count: first)
        if count > first { (dst + first).update(from: base, count: count - first) }
    }

    func commitRead(_ count: Int) {
        let r = readIndex.load(ordering: .relaxed)
        readIndex.store(r + count, ordering: .releasing)
    }

    /// Reads up to `count` frames into up to two destinations (nil = discard). Returns frames read.
    @discardableResult
    func read(_ ch0: UnsafeMutablePointer<Float>?, _ ch1: UnsafeMutablePointer<Float>? = nil, count: Int) -> Int {
        let n = min(count, readableCount)
        guard n > 0 else { return 0 }
        if let ch0 { copyOut(channel: 0, to: ch0, count: n) }
        if channels > 1, let ch1 { copyOut(channel: 1, to: ch1, count: n) }
        commitRead(n)
        return n
    }

    /// Copies without consuming. Returns frames copied.
    func peek(_ ch0: UnsafeMutablePointer<Float>, _ ch1: UnsafeMutablePointer<Float>?, count: Int) -> Int {
        let n = min(count, readableCount)
        guard n > 0 else { return 0 }
        copyOut(channel: 0, to: ch0, count: n)
        if channels > 1, let ch1 { copyOut(channel: 1, to: ch1, count: n) }
        return n
    }

    /// Consumer-side flush.
    func consumerDiscardAll() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }

    /// Full reset. Only call when neither side is running.
    func reset() {
        writeIndex.store(0, ordering: .releasing)
        readIndex.store(0, ordering: .releasing)
    }
}
