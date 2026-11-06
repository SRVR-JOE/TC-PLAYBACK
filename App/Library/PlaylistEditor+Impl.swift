import Foundation
import SwiftData

extension Notification.Name {
    /// Posted (main thread) just before cues are deleted. userInfo["ids"]: Set<UUID>, optional
    /// userInfo["playlistID"]: UUID when the whole playlist is being deleted.
    static let libraryWillDeleteCues = Notification.Name("TCPlayback.libraryWillDeleteCues")
}

extension PlaylistEditor {
    // MARK: Additive API

    /// Renumber only `cues` (e.g. the selection), in playlist order: start, start+step, …
    /// Other cues keep their numbers.
    static func renumber(_ cues: [Cue], in playlist: Playlist, start: Int = 1, step: Int = 1, context: ModelContext) {
        let ids = Set(cues.map(\.id))
        var n = start
        for cue in playlist.orderedCues where ids.contains(cue.id) {
            cue.number = String(n); n += step
        }
        touch(playlist, context: context)
    }

    /// Cues whose media is missing or has changed since import (show these red before the show).
    static func verify(_ playlist: Playlist) -> [Cue] {
        playlist.orderedCues.filter { cue in
            guard cue.kind == .track else { return false }
            guard let track = cue.track else { return true }
            if track.isMissing { return true }
            if let expected = track.contentHash, MediaFingerprint.compute(track.fileURL) != expected { return true }
            return false
        }
    }

    // MARK: Numbering

    /// Leading numeric value of a cue number: "2.5" → 2.5, "10A" → 10, "A1" → nil.
    static func numericValue(of number: String) -> Double? {
        let s = number.trimmingCharacters(in: .whitespaces)
        var digits = ""
        var seenDot = false
        for ch in s {
            if ch.isASCII, ch.isNumber { digits.append(ch) }
            else if ch == ".", !seenDot, !digits.isEmpty { seenDot = true; digits.append(ch) }
            else { break }
        }
        if digits.hasSuffix(".") { digits.removeLast() }
        return digits.isEmpty ? nil : Double(digits)
    }

    /// Next whole number after the highest numeric cue number ("1","2","2.5","10A" → "11").
    static func nextCueNumber(in playlist: Playlist) -> String {
        let highest = playlist.cues.compactMap { numericValue(of: $0.number) }.max() ?? 0
        return String(Int(highest.rounded(.down)) + 1)
    }

    // MARK: Internals

    /// Rewrite positions to 0…n-1 in `order` (defaults to the current order).
    static func compact(_ playlist: Playlist, order: [Cue]? = nil) {
        for (i, cue) in (order ?? playlist.orderedCues).enumerated() where cue.position != i { cue.position = i }
    }

    static func touch(_ playlist: Playlist, context: ModelContext) {
        playlist.updatedAt = .now
        save(context)
    }

    static func save(_ context: ModelContext) {
        do { try context.save() } catch { print("TCPlayback library save failed: \(error)") }
    }

    static func announceDeletion(of cues: [Cue], playlistID: UUID? = nil) {
        guard !cues.isEmpty || playlistID != nil else { return }
        var info: [String: Any] = ["ids": Set(cues.map(\.id))]
        if let playlistID { info["playlistID"] = playlistID }
        NotificationCenter.default.post(name: .libraryWillDeleteCues, object: nil, userInfo: info)
    }

    /// Field-for-field copy (new id; same track).
    static func copy(_ c: Cue, position: Int, number: String) -> Cue {
        let n = Cue(position: position, number: number, title: c.title, kind: c.kind, track: c.track)
        n.notes = c.notes
        n.genStart = c.genStart; n.genRateRaw = c.genRateRaw; n.genDuration = c.genDuration; n.genSideRaw = c.genSideRaw
        n.leftEnabled = c.leftEnabled; n.rightEnabled = c.rightEnabled; n.swapped = c.swapped; n.gainDB = c.gainDB
        n.followRaw = c.followRaw; n.colorHex = c.colorHex
        return n
    }

    static func nextSortIndex(_ context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        return (all.map(\.sortIndex).max() ?? -1) + 1
    }
}
