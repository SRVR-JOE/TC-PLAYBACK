import Foundation
import Observation

/// "Save to USB": a folder the operator picked once in Files (usually on a USB drive or
/// SD card). iOS doesn't let apps write to drives on their own, so the folder is remembered as a
/// security-scoped bookmark. While that drive is plugged in, exports are copied straight into
/// it with one tap.
@MainActor
@Observable
final class ExportDrive {
    static let shared = ExportDrive()

    enum State: Equatable {
        /// No folder chosen yet.
        case notChosen
        /// The folder is there and writable.
        case ready(name: String)
        /// A folder was chosen, but its drive isn't plugged in (or was renamed or erased).
        case missing(name: String)
    }

    private(set) var state: State = .notChosen
    /// Name of the chosen drive or folder, shown in menus ("KINGSTON", "SHOW USB").
    private(set) var name: String = ""
    /// True while the Files folder picker should be showing.
    var pickerRequested = false
    /// Last save result, shown briefly by `.exportDriveSupport()`.
    var feedback: Feedback?

    struct Feedback: Equatable {
        var id = UUID()
        var ok: Bool
        var text: String
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private static let bookmarkKey = "exportDrive.bookmark"
    @ObservationIgnored private static let nameKey = "exportDrive.name"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        name = defaults.string(forKey: Self.nameKey) ?? ""
        refresh()
    }

    var isReady: Bool { if case .ready = state { return true }; return false }
    var hasChoice: Bool { state != .notChosen }

    /// Remember a folder the operator picked with the Files folder picker.
    func choose(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Self.bookmarkKey)
        name = Self.displayName(for: url)
        defaults.set(name, forKey: Self.nameKey)
        refresh()
    }

    func forget() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.nameKey)
        name = ""
        state = .notChosen
    }

    /// Re-checks whether the drive is plugged in. Cheap; call when a menu opens.
    func refresh() {
        guard let url = resolve() else {
            state = defaults.data(forKey: Self.bookmarkKey) == nil ? .notChosen : .missing(name: name)
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        state = there ? .ready(name: name) : .missing(name: name)
    }

    /// Copies `files` into the drive folder, replacing files with the same name. Returns the names
    /// written.
    @discardableResult
    func save(_ files: [URL]) throws -> [String] {
        guard let folder = resolve() else {
            refresh()
            throw ExportDriveError.notConnected(name)
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            state = .missing(name: name)
            throw ExportDriveError.notConnected(name)
        }
        var written: [String] = []
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: folder, options: [], error: &coordError) { dir in
            do {
                for src in files {
                    let dest = dir.appendingPathComponent(src.lastPathComponent)
                    if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                    try FileManager.default.copyItem(at: src, to: dest)
                    written.append(src.lastPathComponent)
                }
            } catch { writeError = error }
        }
        if let e = coordError ?? writeError { throw e }
        state = .ready(name: name)
        return written
    }

    private func resolve() -> URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: Self.bookmarkKey)
        }
        return url
    }

    /// "KINGSTON" for the root of a drive; "KINGSTON › Show files" for a folder on it.
    static func displayName(for url: URL) -> String {
        let volume = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? ""
        let folder = url.lastPathComponent
        if volume.isEmpty || volume == folder { return folder }
        return "\(volume) › \(folder)"
    }
}

enum ExportDriveError: LocalizedError {
    case notConnected(String)
    var errorDescription: String? {
        switch self {
        case .notConnected(let n):
            n.isEmpty ? "Choose a USB drive first." : "\(n) isn’t plugged in. Plug it in, or choose another drive."
        }
    }
}
