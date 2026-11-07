import Foundation
import SwiftData

/// On-disk show format (`show.json` inside `<name>.tcshow.zip`, audio under `Audio/`).
struct ShowFile: Codable {
    static let currentVersion = 1
    var format = "tcshow"
    var version = ShowFile.currentVersion
    var exportedAt = Date()
    var playlist: PlaylistDTO
    var tracks: [TrackDTO]
    var cues: [CueDTO]
    /// The show's camera brief (added later; older files have none and still import).
    var cameraBrief: CameraBrief? = nil

    struct PlaylistDTO: Codable { var id: UUID; var name: String }

    struct TrackDTO: Codable {
        var id: UUID
        var title: String
        var fileName: String
        /// Path inside the package, e.g. "Audio/Song.wav".
        var path: String
        var duration: TimeInterval
        var sampleRate: Double
        var channelCount: Int
        var ltcChannel: String?
        var ltcStart: String?
        var ltcRate: String?
        var contentHash: String?
        var overview: Data?
    }

    struct CueDTO: Codable {
        var position: Int
        var number: String
        var title: String
        var notes: String
        var kind: String
        var trackID: UUID?
        var genStart: String
        var genRate: String
        var genDuration: TimeInterval
        var genSide: String
        var leftEnabled: Bool
        var rightEnabled: Bool
        var swapped: Bool
        var gainDB: Float
        var follow: String
        var colorHex: String?
    }
}

enum ShowPackage {
    static let jsonName = "show.json"
    static let audioFolder = "Audio"

    static func safeName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Show" : s
    }

    // MARK: Export

    @MainActor
    static func export(_ playlist: Playlist, briefs: CameraBriefStore = .shared) throws -> URL {
        let fm = FileManager.default
        let name = safeName(playlist.name)
        let staging = URL.temporaryDirectory.appending(path: "tcshow-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = staging.appending(path: name, directoryHint: .isDirectory)
        let audio = folder.appending(path: audioFolder, directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: audio, withIntermediateDirectories: true)
            let cues = playlist.orderedCues
            var tracks: [ShowFile.TrackDTO] = []
            var seen = Set<UUID>()
            for track in cues.compactMap(\.track) where !seen.contains(track.id) {
                seen.insert(track.id)
                let dest = audio.appending(path: track.fileName)
                guard !track.isMissing else { continue }
                // Hard link is instant and free within the app container; fall back to a copy.
                if (try? fm.linkItem(at: track.fileURL, to: dest)) == nil { try fm.copyItem(at: track.fileURL, to: dest) }
                tracks.append(.init(id: track.id, title: track.title, fileName: track.fileName,
                                    path: "\(audioFolder)/\(track.fileName)", duration: track.duration,
                                    sampleRate: track.sampleRate, channelCount: track.channelCount,
                                    ltcChannel: track.ltcChannel, ltcStart: track.ltcStart, ltcRate: track.ltcRate,
                                    contentHash: track.contentHash, overview: track.overview))
            }
            let exported = Set(tracks.map(\.id))
            let show = ShowFile(
                playlist: .init(id: playlist.id, name: playlist.name), tracks: tracks,
                cues: cues.map { c in
                    .init(position: c.position, number: c.number, title: c.title, notes: c.notes, kind: c.kindRaw,
                          trackID: c.track.flatMap { exported.contains($0.id) ? $0.id : nil },
                          genStart: c.genStart, genRate: c.genRateRaw, genDuration: c.genDuration, genSide: c.genSideRaw,
                          leftEnabled: c.leftEnabled, rightEnabled: c.rightEnabled, swapped: c.swapped, gainDB: c.gainDB,
                          follow: c.followRaw, colorHex: c.colorHex)
                },
                cameraBrief: briefs.hasBrief(playlist.id) ? briefs.brief(playlist.id) : nil)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(show).write(to: folder.appending(path: jsonName), options: .atomic)

            let out = URL.temporaryDirectory.appending(path: "\(name).tcshow.zip")
            try? fm.removeItem(at: out)
            var coordError: NSError?
            var moveError: Error?
            NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordError) { zipURL in
                do { try fm.moveItem(at: zipURL, to: out) } catch {
                    do { try fm.copyItem(at: zipURL, to: out) } catch { moveError = error }
                }
            }
            if let e = coordError ?? moveError { throw e }
            return out
        } catch {
            throw LibraryError.exportFailed(playlist.name)
        }
    }

    // MARK: Import

    /// Unzips + decodes off the main actor; returns the folder containing show.json.
    nonisolated static func unpack(_ url: URL) async throws -> (ShowFile, URL, URL) {
        let display = url.lastPathComponent
        return try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let work = URL.temporaryDirectory.appending(path: "tcshow-in-\(UUID().uuidString)", directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zip: MiniZip
                do { zip = try MiniZip(url: url) } catch { throw LibraryError.notAShow(display) }
                guard let jsonEntry = zip.entries.first(where: {
                    ($0.path as NSString).lastPathComponent == jsonName && !$0.path.hasPrefix("__MACOSX")
                }) else { throw LibraryError.notAShow(display) }
                do { try zip.extractAll(to: work) } catch { throw LibraryError.damagedShow(display) }
                let jsonURL = work.appending(path: MiniZip.safeRelativePath(jsonEntry.path) ?? jsonName)
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                let show: ShowFile
                do { show = try dec.decode(ShowFile.self, from: Data(contentsOf: jsonURL)) } catch {
                    throw LibraryError.damagedShow(display)
                }
                guard show.format == "tcshow" else { throw LibraryError.notAShow(display) }
                guard show.version <= ShowFile.currentVersion else { throw LibraryError.unsupportedShow(show.playlist.name) }
                return (show, jsonURL.deletingLastPathComponent(), work)
            } catch {
                try? FileManager.default.removeItem(at: work)
                throw error
            }
        }.value
    }

    @MainActor
    static func importShow(from url: URL, context: ModelContext, briefs: CameraBriefStore = .shared) async throws -> Playlist {
        let (show, root, work) = try await unpack(url)
        defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default

        let existing = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        var trackMap: [UUID: Track] = [:]
        var needsAnalysis: [Track] = []
        for dto in show.tracks {
            if let match = existing.first(where: { $0.fileName == dto.fileName && abs($0.duration - dto.duration) < 0.05 && !$0.isMissing }) {
                trackMap[dto.id] = match
                continue
            }
            guard let rel = MiniZip.safeRelativePath(dto.path) else { continue }
            let src = root.appending(path: rel)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dest = TrackImporter.uniqueDestination(for: dto.fileName)
            do { try fm.moveItem(at: src, to: dest) } catch { throw LibraryError.copyFailed(dto.fileName) }
            let t = Track(title: dto.title, fileName: dest.lastPathComponent, duration: dto.duration,
                          sampleRate: dto.sampleRate, channelCount: dto.channelCount)
            t.ltcChannel = dto.ltcChannel; t.ltcStart = dto.ltcStart; t.ltcRate = dto.ltcRate
            t.contentHash = MediaFingerprint.compute(dest)
            t.overview = dto.overview
            context.insert(t)
            trackMap[dto.id] = t
            if dto.overview == nil { needsAnalysis.append(t) }
        }

        let playlist = Playlist(name: show.playlist.name, sortIndex: PlaylistEditor.nextSortIndex(context))
        context.insert(playlist)
        for (i, d) in show.cues.sorted(by: { $0.position < $1.position }).enumerated() {
            let kind = CueKind(rawValue: d.kind) ?? .track
            let c = Cue(position: i, number: d.number, title: d.title, kind: kind, track: d.trackID.flatMap { trackMap[$0] })
            c.notes = d.notes
            c.genStart = d.genStart; c.genRateRaw = d.genRate; c.genDuration = d.genDuration; c.genSideRaw = d.genSide
            c.leftEnabled = d.leftEnabled; c.rightEnabled = d.rightEnabled; c.swapped = d.swapped; c.gainDB = d.gainDB
            c.followRaw = d.follow; c.colorHex = d.colorHex
            context.insert(c)
            playlist.cues.append(c)
        }
        if let brief = show.cameraBrief { briefs.set(brief, for: playlist.id) }
        PlaylistEditor.save(context)
        for t in needsAnalysis { TrackImporter.startAnalysis(for: t, context: context) }
        return playlist
    }
}
