import SwiftData
import TCKit
import XCTest
@testable import TCPlayback

/// Records calls; `finish()` simulates the item reaching its end.
final class FakeShowEngine: ShowEngine {
    var routing = ChannelRouting()
    var transport: TransportState = .stopped
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 10
    var onItemFinished: (() -> Void)?
    var loads: [EngineSource] = []
    var plays = 0
    var seeks: [TimeInterval] = []

    func load(_ source: EngineSource, routing: ChannelRouting) throws { loads.append(source); self.routing = routing }
    func play() { plays += 1; transport = .playing }
    func stop() { transport = .stopped; currentTime = 0 }
    func seek(to time: TimeInterval) { seeks.append(time); currentTime = time }
    func finish() { transport = .stopped; onItemFinished?() }
}

@MainActor
class LibraryTestCase: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext { container.mainContext }
    var defaults: UserDefaults!
    var suiteName = ""

    override func setUp() async throws {
        container = try ModelContainer(for: Track.self, Playlist.self, Cue.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        suiteName = "LibraryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        container = nil
    }

    func makeTrack(_ title: String, duration: TimeInterval = 30) -> Track {
        let t = Track(title: title, fileName: "\(title)-\(UUID().uuidString).wav", duration: duration, sampleRate: 48_000, channelCount: 2)
        context.insert(t)
        return t
    }

    /// Playlist of generator cues numbered 1…n (generators need no audio file).
    func makeGeneratorPlaylist(_ n: Int) -> Playlist {
        let p = PlaylistEditor.createPlaylist(named: "Show", context: context)
        for _ in 0..<n { _ = PlaylistEditor.appendGenerator(to: p, context: context) }
        for (i, c) in p.orderedCues.enumerated() { c.title = "Cue \(i + 1)"; c.genDuration = 10 }
        return p
    }

    func assertContiguous(_ p: Playlist, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.orderedCues.map(\.position), Array(0..<p.cues.count), file: file, line: line)
    }
}

@MainActor
final class LibraryEditorTests: LibraryTestCase {
    func testAppendNumbersAfterHighestNumeric() {
        let p = PlaylistEditor.createPlaylist(named: "A", context: context)
        PlaylistEditor.append(tracks: [makeTrack("a"), makeTrack("b"), makeTrack("c"), makeTrack("d")], to: p, context: context)
        let cues = p.orderedCues
        XCTAssertEqual(cues.map(\.number), ["1", "2", "3", "4"])
        cues[2].number = "2.5"; cues[3].number = "10A"
        PlaylistEditor.append(tracks: [makeTrack("e")], to: p, context: context)
        XCTAssertEqual(p.orderedCues.last?.number, "11")
        XCTAssertEqual(p.orderedCues.last?.title, "e")
        assertContiguous(p)
        XCTAssertEqual(PlaylistEditor.numericValue(of: "2.5"), 2.5)
        XCTAssertEqual(PlaylistEditor.numericValue(of: "10A"), 10)
        XCTAssertNil(PlaylistEditor.numericValue(of: "A1"))
    }

    func testMoveKeepsPositionsAndNumbers() {
        let p = makeGeneratorPlaylist(5)
        let before = p.updatedAt
        PlaylistEditor.move(in: p, from: IndexSet(integer: 0), to: 3, context: context)
        XCTAssertEqual(p.orderedCues.map(\.title), ["Cue 2", "Cue 3", "Cue 1", "Cue 4", "Cue 5"])
        XCTAssertEqual(p.orderedCues.map(\.number), ["2", "3", "1", "4", "5"], "move must not renumber")
        assertContiguous(p)
        XCTAssertGreaterThanOrEqual(p.updatedAt, before)
        PlaylistEditor.move(in: p, from: IndexSet([3, 4]), to: 0, context: context)
        XCTAssertEqual(p.orderedCues.map(\.title), ["Cue 4", "Cue 5", "Cue 2", "Cue 3", "Cue 1"])
        PlaylistEditor.move(in: p, from: IndexSet(integer: 0), to: 5, context: context)
        XCTAssertEqual(p.orderedCues.last?.title, "Cue 4")
        assertContiguous(p)
    }

    func testRenumberAllAndSelected() {
        let p = makeGeneratorPlaylist(4)
        PlaylistEditor.renumber(p, start: 10, step: 10, context: context)
        XCTAssertEqual(p.orderedCues.map(\.number), ["10", "20", "30", "40"])
        let cues = p.orderedCues
        PlaylistEditor.renumber([cues[3], cues[1]], in: p, start: 1, step: 1, context: context)
        XCTAssertEqual(p.orderedCues.map(\.number), ["10", "1", "30", "2"])
        assertContiguous(p)
    }

    func testDeleteCuesKeepsContiguous() {
        let p = makeGeneratorPlaylist(5)
        let cues = p.orderedCues
        PlaylistEditor.delete(cues: [cues[1], cues[3]], from: p, context: context)
        XCTAssertEqual(p.orderedCues.map(\.title), ["Cue 1", "Cue 3", "Cue 5"])
        assertContiguous(p)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Cue>()), 3)
    }

    func testDeleteTrackRemovesItsCues() {
        let p = PlaylistEditor.createPlaylist(named: "A", context: context)
        let a = makeTrack("a"), b = makeTrack("b")
        PlaylistEditor.append(tracks: [a, b, a], to: p, context: context)
        _ = PlaylistEditor.appendGenerator(to: p, context: context)
        TrackImporter.delete(a, context: context)
        XCTAssertEqual(p.orderedCues.map(\.title), ["b", "LTC Generator"])
        assertContiguous(p)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Track>()), 1)
    }

    func testDuplicateCueAndPlaylist() {
        let p = makeGeneratorPlaylist(3)
        let second = p.orderedCues[1]
        second.leftEnabled = false; second.gainDB = -3; second.follow = .loop
        PlaylistEditor.duplicate(cue: second, in: p, context: context)
        let cues = p.orderedCues
        XCTAssertEqual(cues.count, 4)
        XCTAssertEqual(cues[2].title, "Cue 2")
        XCTAssertEqual(cues[2].number, "4")
        XCTAssertNotEqual(cues[2].id, second.id)
        XCTAssertEqual(cues[2].routing, second.routing)
        XCTAssertEqual(cues[2].follow, .loop)
        assertContiguous(p)

        let t = makeTrack("shared")
        PlaylistEditor.append(tracks: [t], to: p, context: context)
        let copy = PlaylistEditor.duplicate(p, context: context)
        XCTAssertEqual(copy.orderedCues.map(\.number), p.orderedCues.map(\.number))
        XCTAssertTrue(Set(copy.cues.map(\.id)).isDisjoint(with: Set(p.cues.map(\.id))), "deep copy")
        XCTAssertEqual(copy.orderedCues.last?.track?.id, t.id, "tracks shared")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Track>()), 1)
        XCTAssertNotEqual(copy.sortIndex, p.sortIndex)
        assertContiguous(copy)
    }

    func testVerifyFlagsMissingAndChangedMedia() throws {
        let p = PlaylistEditor.createPlaylist(named: "V", context: context)
        let missing = makeTrack("missing")
        let url = Track.directory.appending(path: "verify-\(UUID().uuidString).wav")
        try DemoContent.writeDemo(DemoContent.specs[0], to: url, seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let ok = Track(title: "ok", fileName: url.lastPathComponent, duration: 0.5, sampleRate: 48_000, channelCount: 2)
        ok.contentHash = MediaFingerprint.compute(url)
        context.insert(ok)
        PlaylistEditor.append(tracks: [missing, ok], to: p, context: context)
        _ = PlaylistEditor.appendGenerator(to: p, context: context)
        XCTAssertEqual(PlaylistEditor.verify(p).map(\.title), ["missing"])
        XCTAssertTrue(missing.isMissing)
        XCTAssertFalse(ok.isMissing)
        ok.contentHash = "1:deadbeef"
        XCTAssertEqual(Set(PlaylistEditor.verify(p).map(\.title)), ["missing", "ok"])
    }
}

@MainActor
final class LibraryShowControllerTests: LibraryTestCase {
    var fake: FakeShowEngine!
    var show: ShowController!

    override func setUp() async throws {
        try await super.setUp()
        fake = FakeShowEngine()
        show = ShowController(driver: fake, defaults: defaults)
        show.goGuardInterval = 0
    }

    func testOpenGoAdvance() {
        let p = makeGeneratorPlaylist(3)
        show.open(p)
        let cues = p.orderedCues
        XCTAssertTrue(show.isStandby(cues[0]))
        XCTAssertEqual(show.nextCueTitle, "Cue 1")
        show.go()
        XCTAssertEqual(fake.loads, [cues[0].engineSource])
        XCTAssertEqual(fake.plays, 1)
        XCTAssertEqual(show.activeCue?.id, cues[0].id)
        XCTAssertTrue(show.isPlaying(cues[0]))
        XCTAssertTrue(show.isStandby(cues[1]))
        XCTAssertEqual(show.remainingTime, 10)
        show.go(); show.go()
        XCTAssertEqual(show.activeCue?.id, cues[2].id)
        XCTAssertNil(show.standbyCue, "past the end")
        show.go()
        XCTAssertEqual(fake.plays, 3, "GO with nothing in standby does nothing")
    }

    func testRoutingLoadsAndCommits() {
        let p = makeGeneratorPlaylist(2)
        p.orderedCues[0].swapped = true
        show.open(p)
        show.go()
        XCTAssertTrue(fake.routing.swapped)
        fake.routing.gainDB = -6; fake.routing.rightEnabled = false
        show.commitRoutingToActiveCue()
        XCTAssertEqual(p.orderedCues[0].gainDB, -6)
        XCTAssertFalse(p.orderedCues[0].rightEnabled)
    }

    func testFollowStopParks() {
        let p = makeGeneratorPlaylist(3)
        show.open(p)
        show.go()
        fake.finish()
        XCTAssertEqual(fake.plays, 1)
        XCTAssertTrue(show.isStandby(p.orderedCues[1]))
        XCTAssertFalse(show.isPlaying(p.orderedCues[0]))
    }

    func testFollowAutoContinue() {
        let p = makeGeneratorPlaylist(3)
        p.orderedCues[0].follow = .autoContinue
        show.goGuardInterval = 5
        show.open(p)
        show.go()
        fake.finish()
        XCTAssertEqual(fake.plays, 2, "auto-continue isn't blocked by the GO guard")
        XCTAssertEqual(show.activeCue?.id, p.orderedCues[1].id)
        XCTAssertTrue(show.isStandby(p.orderedCues[2]))
    }

    func testFollowLoop() {
        let p = makeGeneratorPlaylist(2)
        p.orderedCues[0].follow = .loop
        show.open(p)
        show.go()
        fake.currentTime = 10
        fake.finish()
        XCTAssertEqual(fake.seeks, [0])
        XCTAssertEqual(fake.plays, 2)
        XCTAssertEqual(fake.loads.count, 1)
        XCTAssertEqual(show.activeCue?.id, p.orderedCues[0].id)
        XCTAssertTrue(show.isStandby(p.orderedCues[1]))
    }

    func testPlaySpecificNextPreviousBackOne() {
        let p = makeGeneratorPlaylist(4)
        let cues = p.orderedCues
        show.open(p)
        show.previous()
        XCTAssertTrue(show.isStandby(cues[0]), "previous stops at the top")
        show.next(); show.next()
        XCTAssertTrue(show.isStandby(cues[2]))
        show.previous()
        XCTAssertTrue(show.isStandby(cues[1]))
        show.play(cues[2])
        XCTAssertEqual(show.activeCue?.id, cues[2].id)
        XCTAssertTrue(show.isStandby(cues[3]))
        show.next()
        XCTAssertTrue(show.isStandby(cues[3]), "next stops at the end")
        show.go() // fires 4
        show.backOne()
        XCTAssertTrue(show.isStandby(cues[2]), "back one re-arms the previously fired cue")
    }

    func testGoGuard() {
        let p = makeGeneratorPlaylist(3)
        var clock = Date(timeIntervalSince1970: 1000)
        show.now = { clock }
        show.goGuardInterval = 1.0
        show.open(p)
        show.go()
        clock += 0.3
        show.go()
        XCTAssertEqual(fake.plays, 1, "double GO ignored")
        clock += 1.0
        show.go()
        XCTAssertEqual(fake.plays, 2)
    }

    func testDeletingStandbyMovesItAndRestore() {
        let p = makeGeneratorPlaylist(3)
        show.open(p)
        show.go()
        let cues = p.orderedCues
        PlaylistEditor.delete(cues: [cues[1]], from: p, context: context)
        XCTAssertTrue(show.isStandby(cues[2]))
        PlaylistEditor.delete(cues: [cues[0]], from: p, context: context)
        XCTAssertNil(show.activeCue)
        XCTAssertEqual(fake.transport, .stopped)

        let other = PlaylistEditor.createPlaylist(named: "Other", context: context)
        let restored = ShowController(driver: FakeShowEngine(), defaults: defaults)
        restored.restore(context: context)
        XCTAssertEqual(restored.playlist?.id, p.id)
        restored.open(other)
        let again = ShowController(driver: FakeShowEngine(), defaults: defaults)
        again.restore(context: context)
        XCTAssertEqual(again.playlist?.id, other.id)
    }
}

@MainActor
final class LibraryPackageTests: LibraryTestCase {
    func testOverviewBuckets() {
        var acc = OverviewAccumulator(totalFrames: 10, bucketCount: 5)
        let l: [Float] = [0, 1, 0.5, 0, 0, -0.25, 0, 0, 0.1, 0]
        let r: [Float] = [0, 0, 0, 0.2, 0, 0, 0, 0, 0, -1]
        l.withUnsafeBufferPointer { lb in r.withUnsafeBufferPointer { rb in
            acc.add(left: UnsafeBufferPointer(rebasing: lb[0..<3]), right: UnsafeBufferPointer(rebasing: rb[0..<3]))
            acc.add(left: UnsafeBufferPointer(rebasing: lb[3..<10]), right: UnsafeBufferPointer(rebasing: rb[3..<10]))
        } }
        XCTAssertEqual(Array(acc.data), [255, 0, 128, 51, 64, 0, 0, 0, 26, 255])

        var mono = OverviewAccumulator(totalFrames: 4, bucketCount: 2000)
        XCTAssertEqual(mono.bucketCount, 4, "never more buckets than frames")
        [Float](arrayLiteral: 0.5, 0, 0, 1).withUnsafeBufferPointer { mono.add(left: $0, right: nil) }
        XCTAssertEqual(Array(mono.data), [128, 128, 0, 0, 0, 0, 255, 255])

        // Every frame lands in a bucket and the last bucket is last.
        let big = OverviewAccumulator(totalFrames: 48_000 * 3600, bucketCount: 2000)
        XCTAssertEqual(big.bucket(forFrame: 0), 0)
        XCTAssertEqual(big.bucket(forFrame: 48_000 * 3600 - 1), 1999)
    }

    func testAnalyzerOnGeneratedFile() throws {
        let url = Track.directory.appending(path: "analyze-\(UUID().uuidString).wav")
        try DemoContent.writeDemo(DemoContent.specs[0], to: url, seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try AudioAnalyzer.analyze(url: url)
        XCTAssertEqual(r.overview.count, 4000)
        let left = stride(from: 0, to: r.overview.count, by: 2).map { r.overview[$0] }
        XCTAssertGreaterThan(left.max() ?? 0, 20, "pad audible on L")
        XCTAssertLessThan(left.max() ?? 255, 80, "pad is soft (about -14 dBFS)")
        XCTAssertNotNil(r.contentHash)
    }

    func testStoredZipReader() throws {
        let payload = Data("hello show".utf8)
        let name = Data("dir/a.txt".utf8)
        var z = Data()
        func u16(_ v: Int) { z.append(UInt8(v & 0xff)); z.append(UInt8(v >> 8 & 0xff)) }
        func u32(_ v: Int) { u16(v & 0xffff); u16(v >> 16 & 0xffff) }
        u32(0x04034b50); u16(20); u16(0); u16(0); u16(0); u16(0); u32(0)
        u32(payload.count); u32(payload.count); u16(name.count); u16(0); z.append(name); z.append(payload)
        let cd = z.count
        u32(0x02014b50); u16(20); u16(20); u16(0); u16(0); u16(0); u16(0); u32(0)
        u32(payload.count); u32(payload.count); u16(name.count); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0)
        z.append(name)
        let cdSize = z.count - cd
        u32(0x06054b50); u16(0); u16(0); u16(1); u16(1); u32(cdSize); u32(cd); u16(0)

        let dir = URL.temporaryDirectory.appending(path: "zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zipURL = dir.appending(path: "t.zip")
        try z.write(to: zipURL)
        let zip = try MiniZip(url: zipURL)
        XCTAssertEqual(zip.entries.map(\.path), ["dir/a.txt"])
        try zip.extractAll(to: dir.appending(path: "out"))
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "out/dir/a.txt")), payload)
        XCTAssertNil(MiniZip.safeRelativePath("../evil"))
        XCTAssertNil(MiniZip.safeRelativePath("/abs"))
    }

    func testExportImportRoundTrip() async throws {
        let url = TrackImporter.uniqueDestination(for: "Roundtrip \(UUID().uuidString).wav")
        try DemoContent.writeDemo(DemoContent.specs[1], to: url, seconds: 2)
        let track = Track(title: "Roundtrip", fileName: url.lastPathComponent, duration: 2, sampleRate: 48_000, channelCount: 2)
        track.ltcChannel = "right"; track.ltcStart = "10:00:00:00"; track.ltcRate = "25"
        track.overview = Data([1, 2, 3, 4])
        context.insert(track)
        let p = PlaylistEditor.createPlaylist(named: "Round/Trip", context: context)
        PlaylistEditor.append(tracks: [track], to: p, context: context)
        let gen = PlaylistEditor.appendGenerator(to: p, context: context)
        gen.genRateRaw = FrameRate.fps29_97df.rawValue; gen.genDuration = 300; gen.number = "2.5"
        p.orderedCues[0].swapped = true; p.orderedCues[0].follow = .autoContinue

        let zip = try PlaylistEditor.exportShow(p)
        defer { try? FileManager.default.removeItem(at: zip) }
        XCTAssertTrue(zip.lastPathComponent.hasSuffix(".tcshow.zip"))

        // 1) Same library: track deduped.
        let same = try await PlaylistEditor.importShow(from: zip, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Track>()), 1)
        XCTAssertEqual(same.orderedCues.first?.track?.id, track.id)

        // 2) Fresh library: track + file recreated, cues identical.
        let fileBytes = try Data(contentsOf: url)
        TrackImporter.delete(track, context: context)
        let imported = try await PlaylistEditor.importShow(from: zip, context: context)
        XCTAssertEqual(imported.name, "Round/Trip")
        let cues = imported.orderedCues
        XCTAssertEqual(cues.map(\.number), ["1", "2.5"])
        XCTAssertEqual(cues[0].kind, .track)
        XCTAssertTrue(cues[0].swapped)
        XCTAssertEqual(cues[0].follow, .autoContinue)
        XCTAssertEqual(cues[1].kind, .generator)
        XCTAssertEqual(cues[1].generatorConfig.rate, .fps29_97df)
        XCTAssertEqual(cues[1].genDuration, 300)
        let t = try XCTUnwrap(cues[0].track)
        XCTAssertEqual(t.ltcStart, "10:00:00:00")
        XCTAssertEqual(t.overview, Data([1, 2, 3, 4]))
        XCTAssertEqual(try Data(contentsOf: t.fileURL), fileBytes)
        XCTAssertNotNil(t.contentHash)
        XCTAssertTrue(PlaylistEditor.verify(imported).isEmpty)
        TrackImporter.delete(t, context: context)
    }

    func testImportRejectsUnreadableFile() async throws {
        let bogus = URL.temporaryDirectory.appending(path: "not-audio-\(UUID().uuidString).wav")
        try Data("definitely not audio".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        do {
            try await TrackImporter.importFiles([bogus], into: context)
            XCTFail("should throw")
        } catch let e as LibraryError {
            XCTAssertEqual(e, .unreadable(bogus.lastPathComponent))
            XCTAssertNotNil(e.errorDescription)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Track>()), 0)
    }

    func testImportReadsMetadata() async throws {
        let src = URL.temporaryDirectory.appending(path: "My Song.wav")
        try DemoContent.writeDemo(DemoContent.specs[0], to: src, seconds: 1.5)
        defer { try? FileManager.default.removeItem(at: src) }
        let tracks = try await TrackImporter.importFiles([src], into: context)
        let t = try XCTUnwrap(tracks.first)
        XCTAssertEqual(t.title, "My Song")
        XCTAssertEqual(t.duration, 1.5, accuracy: 0.001)
        XCTAssertEqual(t.sampleRate, 48_000)
        XCTAssertEqual(t.channelCount, 2)
        XCTAssertFalse(t.isMissing)
        // Second import of the same name gets a unique file.
        let t2 = try await TrackImporter.importFiles([src], into: context).first
        XCTAssertNotEqual(t2?.fileName, t.fileName)
        // Background analysis fills the overview.
        for _ in 0..<50 where t.overview == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(t.overview?.count, 4000)
        TrackImporter.delete(t, context: context)
        if let t2 { TrackImporter.delete(t2, context: context) }
    }

    func testDemoSeedOnce() async throws {
        let p = DemoContent.seedIfNeeded(context: context, defaults: defaults)
        let tracks = p!.orderedCues.compactMap(\.track)
        defer { for t in tracks { TrackImporter.delete(t, context: context) } }
        for _ in 0..<600 where tracks.contains(where: { $0.overview == nil }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(tracks.allSatisfy { !$0.isMissing && $0.overview?.count == 4000 }, "demo audio generated in background")
        XCTAssertEqual(tracks.first?.duration, 60)
        XCTAssertNotNil(p)
        XCTAssertNil(DemoContent.seedIfNeeded(context: context, defaults: defaults))
        let cues = p!.orderedCues
        XCTAssertEqual(p!.name, "Demo Show")
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[2].kind, .generator)
        XCTAssertEqual(cues[2].generatorConfig.rate, .fps29_97df)
        XCTAssertEqual(cues[2].generatorConfig.start.description, "01:00:00;00")
        XCTAssertEqual(cues[2].genDuration, 300)
        XCTAssertEqual(cues[2].generatorConfig.side, .right)
        XCTAssertEqual(cues[0].track?.ltcStart, "01:00:00:00")
        XCTAssertEqual(cues[1].track?.ltcRate, "25")
    }
}
