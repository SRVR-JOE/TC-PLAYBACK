import Foundation
import Observation

/// Operator-facing errors from importing, exporting and opening shows.
enum LibraryError: LocalizedError, Equatable {
    case unreadable(String)
    case protected(String)
    case empty(String)
    case copyFailed(String)
    case notAShow(String)
    case damagedShow(String)
    case unsupportedShow(String)
    case exportFailed(String)
    /// Some files imported, others didn't.
    case partial(imported: Int, failed: [String])

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "“\(name)” can’t be played. Use a WAV, AIFF, MP3 or AAC/M4A file."
        case .protected(let name):
            return "“\(name)” is copy-protected (DRM) and can’t be imported. Use an unprotected copy of the file."
        case .empty(let name):
            return "“\(name)” contains no audio."
        case .copyFailed(let name):
            return "“\(name)” couldn’t be copied into the library. Check there is enough free space and try again."
        case .notAShow(let name):
            return "“\(name)” isn’t a TC Playback show."
        case .damagedShow(let name):
            return "The show “\(name)” is damaged and can’t be opened."
        case .unsupportedShow(let name):
            return "The show “\(name)” was made with a newer version of TC Playback."
        case .exportFailed(let name):
            return "The show “\(name)” couldn’t be exported."
        case .partial(let imported, let failed):
            return "\(imported) of \(imported + failed.count) files imported. Couldn’t import: \(failed.joined(separator: ", "))."
        }
    }
}

/// Observable library state for the UI: background analysis in progress and errors raised by
/// fire-and-forget operations (e.g. files opened from other apps).
@MainActor
@Observable
final class LibraryStatus {
    static let shared = LibraryStatus()
    /// Tracks whose waveform / timecode analysis is still running.
    var analyzingTrackIDs: Set<UUID> = []
    /// Last error to show the operator; the UI clears it after presenting.
    var lastError: String?
    func isAnalyzing(_ track: Track) -> Bool { analyzingTrackIDs.contains(track.id) }
}
