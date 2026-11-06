import AVFoundation
import Foundation
import SwiftData

/// File metadata gathered off the main actor before a Track is created.
struct PreparedAudioFile: Sendable {
    var title: String
    var fileName: String
    var duration: TimeInterval
    var sampleRate: Double
    var channelCount: Int
    var contentHash: String?
}

extension TrackImporter {
    // MARK: Open in / AirDrop

    /// Entry point for `.onOpenURL`: imports a `.tcshow.zip` as a playlist, anything else as audio.
    /// Errors land in `LibraryStatus.shared.lastError`.
    static func handleOpenURL(_ url: URL, context: ModelContext) {
        Task { @MainActor in
            do {
                if isShowPackage(url) {
                    let playlist = try await PlaylistEditor.importShow(from: url, context: context)
                    ShowController.shared.open(playlist)
                } else {
                    try await importFiles([url], into: context)
                }
            } catch {
                LibraryStatus.shared.lastError = error.localizedDescription
            }
            removeIfInbox(url)
        }
    }

    static func isShowPackage(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".tcshow.zip") || name.hasSuffix(".tcshow") || url.pathExtension.lowercased() == "zip"
    }

    /// "Open in" copies land in Documents/Inbox; we've copied them into the library, so tidy up.
    nonisolated static func removeIfInbox(_ url: URL) {
        let inbox = URL.documentsDirectory.appending(path: "Inbox").standardizedFileURL.path
        if url.standardizedFileURL.path.hasPrefix(inbox) { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Copy + metadata (off main)

    /// Copies `url` into `Track.directory` and reads its metadata. Throws `LibraryError`.
    nonisolated static func prepare(_ url: URL) async throws -> PreparedAudioFile {
        let display = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        if let isProtected = try? await AVURLAsset(url: url).load(.hasProtectedContent), isProtected {
            throw LibraryError.protected(display)
        }
        let dest = uniqueDestination(for: display)
        try coordinatedCopy(from: url, to: dest)
        do {
            let file = try AVAudioFile(forReading: dest)
            let format = file.fileFormat
            guard file.length > 0, format.sampleRate > 0, format.channelCount > 0 else {
                throw LibraryError.empty(display)
            }
            return PreparedAudioFile(
                title: url.deletingPathExtension().lastPathComponent,
                fileName: dest.lastPathComponent,
                duration: Double(file.length) / file.processingFormat.sampleRate,
                sampleRate: format.sampleRate,
                channelCount: Int(format.channelCount),
                contentHash: MediaFingerprint.compute(dest))
        } catch let e as LibraryError {
            try? FileManager.default.removeItem(at: dest)
            throw e
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw LibraryError.unreadable(display)
        }
    }

    nonisolated static func coordinatedCopy(from src: URL, to dest: URL) throws {
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [], error: &coordError) { readURL in
            do { try FileManager.default.copyItem(at: readURL, to: dest) } catch { copyError = error }
        }
        if coordError != nil || copyError != nil { throw LibraryError.copyFailed(src.lastPathComponent) }
    }

    /// A file name in `directory` derived from `name` that doesn't exist yet ("Song.wav", "Song 2.wav", …).
    nonisolated static func uniqueDestination(for name: String, in directory: URL = Track.directory) -> URL {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = (cleaned as NSString).deletingPathExtension.isEmpty ? "Track" : (cleaned as NSString).deletingPathExtension
        let ext = (cleaned as NSString).pathExtension
        var candidate = directory.appending(path: cleaned.isEmpty ? "Track" : cleaned)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: Background analysis

    /// Computes the overview and scans for LTC in a detached task, then updates `track` on the main actor.
    static func startAnalysis(for track: Track, context: ModelContext) {
        let url = track.fileURL
        let id = track.id
        LibraryStatus.shared.analyzingTrackIDs.insert(id)
        Task.detached(priority: .utility) {
            let result = try? AudioAnalyzer.analyze(url: url)
            await MainActor.run {
                LibraryStatus.shared.analyzingTrackIDs.remove(id)
                guard let result, track.modelContext != nil, !track.isDeleted else { return }
                track.overview = result.overview
                if track.contentHash == nil { track.contentHash = result.contentHash }
                if let ch = result.ltcChannel {
                    track.ltcChannel = ch; track.ltcStart = result.ltcStart; track.ltcRate = result.ltcRate
                }
                try? context.save()
            }
        }
    }
}
