import Compression
import Foundation

/// Minimal streaming ZIP reader: stored (0) and deflate (8) entries, ZIP64 sizes/offsets.
/// Reads through a FileHandle so large audio members never sit in memory. No encryption, no CRC check
/// (sizes are verified instead).
struct MiniZip {
    struct Entry: Equatable {
        var path: String
        var method: UInt16
        var flags: UInt16
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
        var isDirectory: Bool { path.hasSuffix("/") }
    }

    enum ZipError: Error { case notZip, truncated, unsupported(String), corrupt(String) }

    let url: URL
    let entries: [Entry]

    init(url: URL) throws {
        self.url = url
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        self.entries = try MiniZip.readCentralDirectory(h)
    }

    // MARK: Extraction

    /// Extract every file entry under `directory`. Rejects absolute or `..` paths.
    func extractAll(to directory: URL) throws {
        let fm = FileManager.default
        let root = directory.standardizedFileURL
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        for e in entries {
            guard let rel = MiniZip.safeRelativePath(e.path) else { throw ZipError.corrupt("unsafe path \(e.path)") }
            if rel.hasPrefix("__MACOSX") { continue }
            let dest = root.appending(path: rel)
            if e.isDirectory { try fm.createDirectory(at: dest, withIntermediateDirectories: true); continue }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try extract(e, from: h, to: dest)
        }
    }

    func extract(_ e: Entry, from h: FileHandle, to dest: URL) throws {
        if e.flags & 0x1 != 0 { throw ZipError.unsupported("encrypted entry") }
        // Local header: fixed 30 bytes, then name + extra (lengths may differ from the central record).
        try h.seek(toOffset: e.localHeaderOffset)
        guard let lh = try h.read(upToCount: 30), lh.count == 30 else { throw ZipError.truncated }
        guard lh.u32(0) == 0x04034b50 else { throw ZipError.corrupt("bad local header") }
        let dataStart = e.localHeaderOffset + 30 + UInt64(lh.u16(26)) + UInt64(lh.u16(28))

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        try h.seek(toOffset: dataStart)

        var written: UInt64 = 0
        switch e.method {
        case 0:
            var remaining = e.compressedSize
            while remaining > 0 {
                guard let chunk = try h.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty else {
                    throw ZipError.truncated
                }
                try out.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count); written += UInt64(chunk.count)
            }
        case 8:
            written = try MiniZip.inflate(from: h, compressedSize: e.compressedSize, to: out)
        default:
            throw ZipError.unsupported("compression method \(e.method)")
        }
        guard written == e.uncompressedSize else { throw ZipError.corrupt("size mismatch for \(e.path)") }
    }

    /// Raw-deflate decode via the Compression framework (COMPRESSION_ZLIB = raw DEFLATE, no header).
    static func inflate(from h: FileHandle, compressedSize: UInt64, to out: FileHandle) throws -> UInt64 {
        let srcCap = 1 << 16, dstCap = 1 << 18
        let src = UnsafeMutablePointer<UInt8>.allocate(capacity: srcCap)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { src.deallocate(); dst.deallocate(); stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.corrupt("inflate init")
        }
        defer { compression_stream_destroy(stream) }

        var remaining = compressedSize
        var written: UInt64 = 0
        stream.pointee.src_ptr = UnsafePointer(src)
        stream.pointee.src_size = 0
        while true {
            if stream.pointee.src_size == 0 && remaining > 0 {
                guard let chunk = try h.read(upToCount: Int(min(remaining, UInt64(srcCap)))), !chunk.isEmpty else {
                    throw ZipError.truncated
                }
                chunk.copyBytes(to: src, count: chunk.count)
                stream.pointee.src_ptr = UnsafePointer(src)
                stream.pointee.src_size = chunk.count
                remaining -= UInt64(chunk.count)
            }
            stream.pointee.dst_ptr = dst
            stream.pointee.dst_size = dstCap
            let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let consumedBefore = stream.pointee.src_size
            let status = compression_stream_process(stream, flags)
            let produced = dstCap - stream.pointee.dst_size
            if produced > 0 {
                try out.write(contentsOf: Data(bytesNoCopy: dst, count: produced, deallocator: .none))
                written += UInt64(produced)
            }
            switch status {
            case COMPRESSION_STATUS_END: return written
            case COMPRESSION_STATUS_OK:
                if produced == 0 && remaining == 0 && stream.pointee.src_size == consumedBefore {
                    throw ZipError.truncated // no progress and no more input
                }
            default: throw ZipError.corrupt("inflate")
            }
        }
    }

    // MARK: Central directory

    static func readCentralDirectory(_ h: FileHandle) throws -> [Entry] {
        let size = try h.seekToEnd()
        guard size >= 22 else { throw ZipError.notZip }
        let tailLen = min(size, 22 + 65_535 + 20)
        try h.seek(toOffset: size - tailLen)
        guard let tail = try h.read(upToCount: Int(tailLen)) else { throw ZipError.truncated }
        guard let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: { tail.u32($0) == 0x06054b50 }) else {
            throw ZipError.notZip
        }
        var count = UInt64(tail.u16(eocd + 10))
        var cdSize = UInt64(tail.u32(eocd + 12))
        var cdOffset = UInt64(tail.u32(eocd + 16))

        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // ZIP64 end-of-central-directory locator sits right before the EOCD.
            let loc = eocd - 20
            guard loc >= 0, tail.u32(loc) == 0x07064b50 else { throw ZipError.corrupt("missing zip64 locator") }
            try h.seek(toOffset: tail.u64(loc + 8))
            guard let z = try h.read(upToCount: 56), z.count == 56, z.u32(0) == 0x06064b50 else {
                throw ZipError.corrupt("bad zip64 record")
            }
            count = z.u64(32); cdSize = z.u64(40); cdOffset = z.u64(48)
        }
        guard cdOffset + cdSize <= size else { throw ZipError.truncated }
        try h.seek(toOffset: cdOffset)
        guard let cd = try h.read(upToCount: Int(cdSize)), UInt64(cd.count) == cdSize else { throw ZipError.truncated }

        var entries: [Entry] = []
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, cd.u32(p) == 0x02014b50 else { throw ZipError.corrupt("bad central record") }
            let nameLen = Int(cd.u16(p + 28)), extraLen = Int(cd.u16(p + 30)), commentLen = Int(cd.u16(p + 32))
            guard p + 46 + nameLen + extraLen <= cd.count else { throw ZipError.truncated }
            let name = String(decoding: cd[(cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLen)], as: UTF8.self)
            var e = Entry(path: name, method: cd.u16(p + 10), flags: cd.u16(p + 8),
                          compressedSize: UInt64(cd.u32(p + 20)), uncompressedSize: UInt64(cd.u32(p + 24)),
                          localHeaderOffset: UInt64(cd.u32(p + 42)))
            // ZIP64 extended information extra field (id 0x0001): present only for saturated fields, in order.
            var x = p + 46 + nameLen
            let xEnd = x + extraLen
            while x + 4 <= xEnd {
                let id = cd.u16(x), len = Int(cd.u16(x + 2))
                if id == 0x0001 {
                    var q = x + 4
                    if e.uncompressedSize == 0xFFFF_FFFF { e.uncompressedSize = cd.u64(q); q += 8 }
                    if e.compressedSize == 0xFFFF_FFFF { e.compressedSize = cd.u64(q); q += 8 }
                    if e.localHeaderOffset == 0xFFFF_FFFF { e.localHeaderOffset = cd.u64(q) }
                }
                x += 4 + len
            }
            entries.append(e)
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// Normalised relative path, or nil if it escapes the destination.
    static func safeRelativePath(_ path: String) -> String? {
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." }) else { return nil }
        return parts.filter { $0 != "." }.joined(separator: "/") + (path.hasSuffix("/") ? "/" : "")
    }
}

fileprivate extension Data {
    func u16(_ o: Int) -> UInt16 {
        let b = startIndex + o
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }
    func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
}
