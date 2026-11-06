import AVFoundation
import CryptoKit
import Foundation
import TCKit

/// Builds the waveform overview incrementally: `bucketCount` interleaved [L,R] UInt8 peak pairs.
/// Feed de-interleaved chunks in order; memory use is independent of file length.
struct OverviewAccumulator {
    static let defaultBuckets = 2000

    let totalFrames: Int64
    let bucketCount: Int
    private var peaks: [UInt8]
    private var framesSeen: Int64 = 0

    init(totalFrames: Int64, bucketCount: Int = OverviewAccumulator.defaultBuckets) {
        self.totalFrames = max(0, totalFrames)
        self.bucketCount = Int(min(Int64(max(1, bucketCount)), max(1, self.totalFrames)))
        self.peaks = [UInt8](repeating: 0, count: self.bucketCount * 2)
    }

    /// Bucket that absolute frame `frame` falls into.
    func bucket(forFrame frame: Int64) -> Int {
        guard totalFrames > 0 else { return 0 }
        return Int(min(Int64(bucketCount - 1), frame * Int64(bucketCount) / totalFrames))
    }

    /// `right == nil` for mono (R mirrors L).
    mutating func add(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>?) {
        guard totalFrames > 0 else { return }
        let n = left.count
        var i = 0
        while i < n {
            let b = bucket(forFrame: framesSeen + Int64(i))
            // First absolute frame of the next bucket: ceil((b+1) * total / buckets).
            let nextStart = (Int64(b + 1) * totalFrames + Int64(bucketCount) - 1) / Int64(bucketCount)
            let runEnd = b == bucketCount - 1 ? n : max(i + 1, min(n, Int(nextStart - framesSeen)))
            var pl: Float = 0, pr: Float = 0
            for j in i..<runEnd {
                let l = abs(left[j]); if l > pl { pl = l }
                let r = right.map { abs($0[j]) } ?? l; if r > pr { pr = r }
            }
            peaks[b * 2] = max(peaks[b * 2], Self.quantize(pl))
            peaks[b * 2 + 1] = max(peaks[b * 2 + 1], Self.quantize(pr))
            i = runEnd
        }
        framesSeen += Int64(n)
    }

    static func quantize(_ v: Float) -> UInt8 {
        guard v.isFinite else { return 0 }
        return UInt8(min(255, max(0, (v * 255).rounded())))
    }

    var data: Data { Data(peaks) }
}

/// Media fingerprint for integrity checks: "<size>:<sha256 hex of the first 1 MB>".
enum MediaFingerprint {
    static let prefixBytes = 1 << 20

    static func compute(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        try? h.seek(toOffset: 0)
        let head = (try? h.read(upToCount: prefixBytes)) ?? Data()
        let digest = SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
        return "\(size):\(digest)"
    }
}

/// Result of background analysis of one file.
struct AudioAnalysisResult: Sendable {
    var overview: Data
    var contentHash: String?
    var ltcChannel: String?
    var ltcStart: String?
    var ltcRate: String?
}

enum AudioAnalyzer {
    static let ltcScanSeconds: Double = 20
    static let chunkFrames: AVAudioFrameCount = 65_536

    /// Streams the file once: overview for the whole file + LTC scan over the first 20 s.
    static func analyze(url: URL, buckets: Int = OverviewAccumulator.defaultBuckets) throws -> AudioAnalysisResult {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw LibraryError.unreadable(url.lastPathComponent)
        }
        var acc = OverviewAccumulator(totalFrames: file.length, bucketCount: buckets)
        let scanFrames = Int(min(Double(file.length), ltcScanSeconds * format.sampleRate))
        var scan: [[Float]] = Array(repeating: [], count: channels > 1 ? 2 : 1)
        for c in scan.indices { scan[c].reserveCapacity(scanFrames) }

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunkFrames)
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            let l = UnsafeBufferPointer(start: data[0], count: n)
            let r = channels > 1 ? UnsafeBufferPointer(start: data[1], count: n) : nil
            acc.add(left: l, right: r)
            let need = scanFrames - scan[0].count
            if need > 0 {
                let take = min(need, n)
                scan[0].append(contentsOf: l[0..<take])
                if let r, scan.count > 1 { scan[1].append(contentsOf: r[0..<take]) }
            }
        }

        var result = AudioAnalysisResult(overview: acc.data, contentHash: MediaFingerprint.compute(url))
        if scanFrames > 0, let found = LTCScanner.scan(channels: scan, sampleRate: format.sampleRate) {
            result.ltcChannel = sideName(found.channel)
            result.ltcStart = found.start.description
            result.ltcRate = found.rate.rawValue
        }
        return result
    }

    // Overloads so this compiles whether TCKit reports the channel as an index or a named enum.
    static func sideName(_ channel: Int) -> String { channel == 0 ? "left" : "right" }
    static func sideName<T: RawRepresentable>(_ channel: T) -> String where T.RawValue == String {
        channel.rawValue.lowercased().hasPrefix("l") ? "left" : "right"
    }
}
