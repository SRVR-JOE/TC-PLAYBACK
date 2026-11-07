import XCTest
import SwiftUI
import TCKit
@testable import TCPlayback

final class ToolsFrameGridTests: XCTestCase {

    // MARK: Snap

    func testSnapLandsOnWholeFramesAtEveryRate() {
        let rates: [(String, Double)] = [("23.976", 24_000.0 / 1001), ("25", 25), ("29.97", 30_000.0 / 1001),
                                         ("30", 30), ("59.94", 60_000.0 / 1001), ("60", 60)]
        for (name, fps) in rates {
            for t in [0.0, 0.0001, 1.234567, 10.5, 47.0 + 0.4 / fps, 3599.99] {
                let s = FrameGrid.snap(t, fps: fps)
                let frames = s * fps
                XCTAssertEqual(frames, frames.rounded(), accuracy: 1e-6, "\(name): \(t) → \(s) is not on a frame")
                XCTAssertLessThanOrEqual(abs(s - t), 0.5 / fps + 1e-9, "\(name): snapped more than half a frame")
            }
        }
    }

    func testSnapUsesRealRateNotNominal() {
        // 29.97: frame 30 is at 1.001 s, not 1.0 s.
        XCTAssertEqual(FrameGrid.snap(1.0, rate: .fps29_97ndf), 30 * 1001 / 30_000.0, accuracy: 1e-12)
        XCTAssertEqual(FrameGrid.snap(1.0, rate: .fps23_976), 24 * 1001 / 24_000.0, accuracy: 1e-12)
        XCTAssertEqual(FrameGrid.snap(1.0, rate: .fps25), 1.0)
    }

    func testSnapClampsToTrack() {
        XCTAssertEqual(FrameGrid.snap(-3, fps: 25), 0)
        // 10.03 s at 25 fps: the last whole frame inside the track is 250 (10.00 s).
        XCTAssertEqual(FrameGrid.snap(11, fps: 25, duration: 10.03), 10, accuracy: 1e-12)
        XCTAssertEqual(FrameGrid.snap(.nan, fps: 25), 0)
    }

    // MARK: Step

    func testStepFromMidFrameGoesToNeighbouringWholeFrames() {
        let fps = 25.0
        let mid = 4.0 + 0.6 / fps // 60 % into frame 100
        XCTAssertEqual(FrameGrid.step(from: mid, frames: 1, fps: fps) * fps, 101, accuracy: 1e-9)
        XCTAssertEqual(FrameGrid.step(from: mid, frames: -1, fps: fps) * fps, 100, accuracy: 1e-9, "back to the frame it's in")
        XCTAssertEqual(FrameGrid.step(from: mid, frames: 10, fps: fps) * fps, 110, accuracy: 1e-9)
        XCTAssertEqual(FrameGrid.step(from: mid, frames: -10, fps: fps) * fps, 91, accuracy: 1e-9)
    }

    func testStepOnAFrameMovesExactlyAndNeverDrifts() {
        let rate = FrameRate.fps29_97df
        var t = FrameGrid.time(ofFrame: 1000, fps: rate.fps)
        for _ in 0..<5000 { t = FrameGrid.step(from: t, frames: 1, rate: rate) }
        XCTAssertEqual(FrameGrid.nearestFrame(t, fps: rate.fps), 6000)
        XCTAssertEqual(t * rate.fps, 6000, accuracy: 1e-6)
        // A seek lands on the nearest audio sample, a hair off the grid: still counts as on it.
        let onSample = (FrameGrid.time(ofFrame: 77, fps: rate.fps) * 48_000).rounded() / 48_000
        XCTAssertEqual(FrameGrid.nearestFrame(FrameGrid.step(from: onSample, frames: -1, rate: rate), fps: rate.fps), 76)
    }

    func testStepClampsAtBothEnds() {
        XCTAssertEqual(FrameGrid.step(from: 0, frames: -1, fps: 30), 0)
        XCTAssertEqual(FrameGrid.step(from: 9.99, frames: 10, fps: 30, duration: 10), 10, accuracy: 1e-12)
    }

    // MARK: Timecode readout

    func testTimecodeAtTrackTimeIncludesStartOffset() {
        let clock = CuePointClock(start: Timecode(hours: 1, rate: .fps25))
        XCTAssertEqual(clock.label(at: 95.2), "01:01:35:05")
        XCTAssertEqual(clock.label(at: 0), "01:00:00:00")
        let df = CuePointClock(start: Timecode(hours: 1, rate: .fps29_97df))
        XCTAssertEqual(df.label(at: FrameGrid.time(ofFrame: 1800, fps: FrameRate.fps29_97df.fps)), "01:01:00;02",
                       "drop-frame labels skip ;00 and ;01 at the minute")
    }

    func testScrubReleaseSeeksToAWholeFrameAndReadoutIsTimecode() {
        let clock = CuePointClock(start: Timecode(hours: 1, minutes: 4, rate: .fps25))
        for x in stride(from: CGFloat(0), through: 1000, by: 37.3) {
            let t = WaveformOverviewContent.scrubTime(x: x, width: 1000, length: 248.2, clock: clock)
            XCTAssertEqual(t * 25, (t * 25).rounded(), accuracy: 1e-9, "scrub at \(x) not on a frame")
            XCTAssertLessThanOrEqual(t, 248.2)
        }
        let label = WaveformOverviewContent.scrubLabel(x: 400, width: 1000, length: 248.2, clock: clock)
        XCTAssertEqual(label, "01:05:39:07")
        XCTAssertNotNil(label.range(of: #"^\d\d:\d\d:\d\d[:;]\d\d$"#, options: .regularExpression), "readout must be HH:MM:SS:FF")
        // Past the end of the bar clamps to the last frame inside the track.
        XCTAssertEqual(WaveformOverviewContent.scrubTime(x: 2000, width: 1000, length: 10.03, clock: clock), 10, accuracy: 1e-12)
    }

    func testFrameStepControlTargets() {
        let clock = CuePointClock(start: Timecode(rate: .fps30))
        let mid = 2.0 + 0.5 / 30
        XCTAssertEqual(FrameStepControl.target(from: mid, frames: 1, clock: clock, duration: 60) * 30, 61, accuracy: 1e-9)
        XCTAssertEqual(FrameStepControl.target(from: mid, frames: -1, clock: clock, duration: 60) * 30, 60, accuracy: 1e-9)
        XCTAssertEqual(FrameStepControl.target(from: mid, frames: -10, clock: clock, duration: 60) * 30, 51, accuracy: 1e-9)
        XCTAssertEqual(FrameStepControl.target(from: 59.99, frames: 10, clock: clock, duration: 60), 60, accuracy: 1e-9)
    }

    func testPlaybackClockFollowsTrackLTC() {
        let t = Track(title: "x", fileName: "x.wav", duration: 10, sampleRate: 48_000, channelCount: 2)
        XCTAssertEqual(CuePointClock.playback(for: t).start, Timecode(rate: .fps30), "no LTC: track time at 30")
        t.ltcStart = "01:04:00:00"; t.ltcRate = "25"
        XCTAssertEqual(CuePointClock.playback(for: t).start.description, "01:04:00:00")
        XCTAssertEqual(CuePointClock.playback(for: t).rate, .fps25)
    }

    // MARK: Waveform pyramid

    func testPyramidFoldsExactlyAndKeepsSignedPeaks() {
        let sr = 48_000.0
        let samples = (0..<Int(sr * 2)).map { i in Float(sin(Double(i) / sr * 2 * .pi * 220)) * (i < 48_000 ? 0.5 : 0.9) }
        let levels = WaveformPyramid.build(samples: samples, sampleRate: sr)
        XCTAssertEqual(levels.map(\.perSecond), [10, 100, 1000])
        XCTAssertEqual(levels[2].count, 2000)
        XCTAssertEqual(levels[1].count, 200)
        XCTAssertEqual(levels[0].count, 20)
        XCTAssertEqual(levels[0].maxs[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(levels[0].mins[0], -0.5, accuracy: 0.001)
        XCTAssertEqual(levels[0].maxs[19], 0.9, accuracy: 0.001)
        // Coarse = fold of fine.
        XCTAssertEqual(levels[1], WaveformPyramid.fold(levels[2], to: 100))
    }

    func testLevelChoiceNeverStretchesCoarseData() {
        let levels = [10.0, 100, 1000].map { WaveLevel(perSecond: $0, mins: [], maxs: []) }
        XCTAssertEqual(WaveformPyramid.level(forPixelsPerSecond: 4, in: levels), 0)
        XCTAssertEqual(WaveformPyramid.level(forPixelsPerSecond: 10, in: levels), 0)
        XCTAssertEqual(WaveformPyramid.level(forPixelsPerSecond: 11, in: levels), 1)
        XCTAssertEqual(WaveformPyramid.level(forPixelsPerSecond: 999, in: levels), 2)
        XCTAssertNil(WaveformPyramid.level(forPixelsPerSecond: 1001, in: levels), "finer than 1 kHz: draw real samples")
    }

    @MainActor
    func testDeepZoomDrawsSamplesNotPeaks() {
        let sr = 48_000.0
        let samples = (0..<Int(sr * 3)).map { Float(sin(Double($0) / sr * 2 * .pi * 440)) }
        let wf = TimelineWaveform(levels: WaveformPyramid.build(samples: samples, sampleRate: sr), sampleRate: sr, samples: samples)
        XCTAssertEqual(wf.samples(from: 95_990, count: 20), Array(samples[95_990..<96_010]), "reads across a block boundary")
        // 0.08 s across 1400 pt at 2x: 2800 px for 3840 samples → under 2 per pixel → the sample curve.
        let deep = WaveShape.make(wf, vp: (origin: 1.0, pps: 1400 / 0.08, scale: 2), width: 1400, duration: 3)
        guard case .samples(let pts, _) = deep else { return XCTFail("expected samples at deep zoom, got \(deep)") }
        XCTAssertGreaterThan(pts.count, 3800)
        // 30 s across 1400 pt: from the pyramid, one column per device pixel.
        let wide = WaveShape.make(wf, vp: (origin: 0, pps: 1400 / 30, scale: 2), width: 1400, duration: 3)
        guard case .envelope(_, let step, let lo, let hi) = wide else { return XCTFail("expected an envelope") }
        XCTAssertEqual(step, 0.5)
        XCTAssertEqual(lo.count, hi.count)
        XCTAssertGreaterThan(hi.max() ?? 0, 0.99)
    }

    // MARK: Ruler

    func testRulerGoesToFramesWhenZoomedIn() {
        let wide = TimelineEditor.RulerPlan.make(secondWidth: 20, nominalFPS: 30)
        XCTAssertEqual(wide.unit, .seconds)
        XCTAssertEqual(wide.majorSeconds, 5, "a full TC label needs ~96 pt")
        let close = TimelineEditor.RulerPlan.make(secondWidth: 300, nominalFPS: 30)
        XCTAssertEqual(close.unit, .frames)
        XCTAssertEqual(close.minorStep, 1, "a tick per frame at 10 pt a frame")
        XCTAssertEqual(close.frameLabelStep, 3)
        let deep = TimelineEditor.RulerPlan.make(secondWidth: 30 * 600, nominalFPS: 25)
        XCTAssertEqual(deep.frameLabelStep, 1, "every frame numbered at deep zoom")
    }

    // MARK: Mark labels

    func testFlagLabelsTruncateButKeepTheCueNumber() {
        let font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        XCTAssertEqual(TextFit.fit(number: "4", name: "Chorus drop", font: font, width: 500), "4 Chorus drop")
        let short = TextFit.fit(number: "4", name: "Chorus drop", font: font, width: 50)
        XCTAssertTrue((short.hasPrefix("4 ") && short.hasSuffix("\u{2026}")) || short == "4", short)
        XCTAssertEqual(TextFit.fit(number: "12", name: "Chorus drop", font: font, width: 5), "12")
    }

    func testFlagInkContrast() {
        XCTAssertEqual(TextFit.ink(on: "#E5A50A"), Color(hex: 0x111316), "dark text on amber")
        XCTAssertEqual(TextFit.ink(on: "#1A3A8A"), Color(hex: 0xF4F5F7), "light text on deep blue")
    }

    // MARK: Snapshots (set SNAPSHOT_DIR to write them)

    @MainActor
    func testRenderPhoneWidthSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { throw XCTSkip("SNAPSHOT_DIR not set") }
        let sr = 48_000.0
        let samples = (0..<Int(sr * 30)).map { i -> Float in
            let t = Double(i) / sr
            return Float(sin(t * 2 * .pi * 110) * 0.6 * abs(sin(t * .pi / 2)) + sin(t * 2 * .pi * 1700) * 0.08)
        }
        let wf = TimelineWaveform(levels: WaveformPyramid.build(samples: samples, sampleRate: sr), sampleRate: sr, samples: samples)
        let track = UUID()
        let types = CuePointType.defaults
        let pts = [(4.0, "Intro hit", 0), (8.0, "Blackout", 1), (12.0, "Screens on", 2), (12.0, "Verse 1", 0), (20.0, "Gerbs", 3)]
            .map { t, n, ty -> CuePoint in
                let p = CuePoint(trackID: track, time: t, name: n)
                p.typeID = ty < types.count && types[ty].id != CuePointType.defaultID ? types[ty].id : nil
                return p
            }
        for (name, span, at, scheme) in [("timeline-iphone", 24.0, 10.0, ColorScheme.dark),
                                         ("timeline-iphone-light", 24.0, 10.0, .light),
                                         ("timeline-iphone-frames", 0.5, 12.0, .dark)] {
            let view = TimelineEditor(duration: 30, waveform: wf, points: pts, clock: CuePointClock(start: Timecode(hours: 1, rate: .fps25)),
                                      playhead: at, isPlaying: false, selected: .constant(pts[3].id),
                                      onSeek: { _ in }, onMove: { _, _ in }, span: .constant(span),
                                      lanes: types, selection: .constant([pts[3].id]), audioChannel: "Left")
                .frame(width: 369, height: 200)
                .padding(12)
                .background(Theme.background)
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view)
            r.scale = 3
            let img = try XCTUnwrap(r.uiImage)
            try XCTUnwrap(img.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let bar = VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Playing").font(Theme.sectionHeader).foregroundStyle(Theme.go)
                Text("Intro").font(Theme.sectionHeader).foregroundStyle(Theme.textPrimary)
                Spacer()
                FrameStepControl(clock: CuePointClock(start: Timecode(hours: 1, rate: .fps25)), duration: 221, enabled: true, compact: true)
                Text("3:41").font(Theme.numeric(12, weight: .regular)).foregroundStyle(Theme.textSecondary)
            }
            WaveformOverviewView(overview: DemoVisualsDataSource.demoOverview(), channelCount: 2, duration: 225)
                .frame(height: 44)
        }
        .padding(10)
        .frame(width: 373)
        .background(Theme.surface)
        .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: bar)
        r.scale = 3
        try XCTUnwrap(r.uiImage?.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("playbar-iphone.png"))
    }
}
