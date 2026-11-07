#if DEBUG
import AVFoundation
import CoreVideo
import UIKit

/// QA only (`-seedVideo`): writes a short generated movie and links it to the track, so the
/// panel and film strip can be checked on a fresh simulator without Photos. Never plays sound.
enum CueVideoDebugSeed {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-seedVideo") }

    static func seedIfNeeded(trackID: UUID) async -> CueVideoLink? {
        guard enabled, CueVideoStore.load(trackID) == nil else { return nil }
        let name = CueVideoStore.newFileName(for: trackID, ext: "mov")
        let url = CueVideoStore.directory.appending(path: name)
        guard (try? await makeMovie(url: url, seconds: 60)) != nil else { return nil }
        let link = CueVideoLink(fileName: name, offset: 4, rate: 1, displayName: "Rehearsal wide shot")
        CueVideoStore.save(link, for: trackID)
        return link
    }

    /// 320×180 at 30 fps: a dark frame with a bar that sweeps once a second and a flash every 5 s.
    static func makeMovie(url: URL, seconds: Int, fps: Int32 = 30) async throws {
        try? FileManager.default.removeItem(at: url)
        let w = 320, h = 180
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for f in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { break }
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pb)
            let flash = f % (5 * Int(fps)) < 3
            let barX = (f % Int(fps)) * w / Int(fps)
            let shade = UInt8(40 + (f / Int(fps)) % 6 * 20)
            for y in 0..<h {
                for x in 0..<w {
                    let p = base + y * row + x * 4
                    let v: UInt8 = flash ? 240 : (abs(x - barX) < 6 ? 200 : shade)
                    p[0] = v; p[1] = v; p[2] = flash ? 240 : v / 2 + 20; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
#endif
