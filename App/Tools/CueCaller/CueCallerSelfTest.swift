#if DEBUG
import AVFoundation
import Foundation

/// `-cueCallerTest` (requires `-silentOutput`; refuses otherwise): plays a generated 40 s track with
/// marks through the real engine and caller, seeks once mid-run, and writes when each call
/// actually started/ended (from the render thread) against its target to tmp/cueCallerTest.txt.
@MainActor
enum CueCallerSelfTest {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-cueCallerTest") else { return }
        guard args.contains("-silentOutput") else {
            print("CUECALLERTEST refused: launch with -silentOutput")
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            await run()
        }
    }

    static func run() async {
        var lines: [String] = []
        let engine = PlaybackEngine.shared
        guard let url = try? makeSilentWAV(seconds: 40) else { write(["could not write test track"]); return }
        do { try engine.load(.file(url)) } catch { write(["load failed: \(error)"]); return }

        let caller = CueCaller.shared
        caller.defaults = UserDefaults(suiteName: "cueCallerTest") ?? .standard
        caller.renderer = StubCueCallRenderer()
        caller.renderStep = StubCueCallRenderer().renderStep() // go onset = duration
        caller.translator = PassthroughCueCallTranslator()
        caller.noteLanguage = "en-US"
        let english = CueCallArea(name: "Cameras", language: "en-US", outputChannels: [0, 1])
        let spanish = CueCallArea(name: "Cámaras", language: "es-MX", outputChannels: [2, 3])
        var s = CueCallerSettings()
        s.enabled = true; s.source = .playback; s.standbyLead = 3; s.sayStandby = true
        s.onlyMarksWithNotes = true; s.areas = [english, spanish]
        let marks = [
            CueCallMark(time: 6, name: "A", note: "Camera 3, push in slow"),
            CueCallMark(time: 9, name: "B", note: "Camera 1, wide"),
            CueCallMark(time: 9.6, name: "C", note: "Lights"),            // overlaps B's go
            CueCallMark(time: 12, name: "D", note: ""),                  // no note → no call
            CueCallMark(time: 16, name: "E", note: "Camera 2, crane up"), // skipped by the seek
            CueCallMark(time: 24, name: "F", note: "Camera 4, follow"),
        ]
        caller.prepare(marks: marks, fileURL: url, duration: 40)
        caller.settings = s
        try? await Task.sleep(for: .seconds(1)) // plan + pre-render
        caller.debugReports = []
        let sr = engine.cueCallMixer?.sampleRate ?? 48_000
        lines.append(String(format: "sampleRate %.0f outputChannels %d latency %.4f", sr, engine.outputChannelCount, engine.measuredOutputLatency))
        lines.append("planned calls \(caller.timeline.count) (estimated durations: \(caller.timeline.filter(\.estimated).count))")
        for t in caller.timeline {
            lines.append(String(format: "  plan %@ %@ at %.3f start %.3f dur %.3f onset %@%@ \"%@\"", t.call.kind.rawValue,
                                areaName(t.call.areaID, s), t.call.at, t.start, t.duration,
                                t.goOnset.map { String(format: "%.3f", $0) } ?? "-",
                                t.cutAt.map { String(format: " cut %.3f", $0) } ?? "", t.call.text))
        }

        engine.seek(to: 0); engine.play()
        try? await Task.sleep(for: .seconds(11.5))
        let seekFrom = engine.preciseTime
        engine.seek(to: 19.5)  // jump over E (standby 13, go ~15.x)
        lines.append(String(format: "seek from %.3f to 19.500", seekFrom))
        try? await Task.sleep(for: .seconds(6))
        engine.stop()
        try? await Task.sleep(for: .milliseconds(300))

        // Report: one line per finished voice.
        var worstGo = 0.0, worstStart = 0.0, count = 0
        let finished = caller.debugReports.filter { $0.report.endedAt != nil }
        for e in finished {
            let r = e.report, t = e.call
            guard let st = r.startedAt, let en = r.endedAt else { continue }
            count += 1
            let ms = Double(st) / e.sampleRate, me = Double(en) / e.sampleRate
            let startErr = (ms - t.start) * 1000
            worstStart = max(worstStart, abs(startErr))
            var line = String(format: "%@ %@ mark %.3f  target start %.4f measured %.4f (%+.2f ms)", t.call.kind.rawValue,
                              areaName(t.call.areaID, s), t.call.kind == .go ? t.call.at : t.call.at + s.standbyLead,
                              t.start, ms, startErr)
            if t.call.kind == .go && !r.wasFaded {
                let endErr = (me - t.call.at) * 1000
                worstGo = max(worstGo, abs(endErr))
                let goWord = ms + (t.goOnset ?? t.duration)
                line += String(format: "  end %.4f vs mark (%+.2f ms), go word %.4f (%+.2f ms)", me, endErr,
                               goWord, (goWord - t.call.at) * 1000)
            } else if r.wasFaded {
                line += String(format: "  faded, ended %.4f (cut %.3f)", me, t.cutAt ?? -1)
            }
            lines.append(line)
        }
        // A call aimed before the seek target that still started after the seek = backlog.
        let afterSeekEarly = finished.filter { e in
            guard let st = e.report.startedAt else { return false }
            return e.call.start < 19.5 && Double(st) / e.sampleRate >= 19.5 - 0.001
        }
        let eCalls = finished.filter { $0.call.call.markID == marks[4].id }
        lines.append("voices finished \(count); calls for skipped mark E: \(eCalls.count); stale calls after seek: \(afterSeekEarly.count)")
        lines.append(String(format: "worst go-end error %.3f ms, worst start error %.3f ms", worstGo, worstStart))
        caller.settings.enabled = false
        caller.renderStep = nil
        caller.defaults.removePersistentDomain(forName: "cueCallerTest")
        caller.defaults = .standard
        write(lines)
    }

    private static func areaName(_ id: UUID, _ s: CueCallerSettings) -> String {
        s.areas.first { $0.id == id }?.language ?? "?"
    }

    private static func write(_ lines: [String]) {
        let report = lines.joined(separator: "\n")
        print("CUECALLERTEST\n" + report)
        try? report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("cueCallerTest.txt"),
                          atomically: true, encoding: .utf8)
    }

    private static func makeSilentWAV(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cueCallerTest.wav")
        try? FileManager.default.removeItem(at: url)
        let rate = 48_000.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(seconds * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n) // zero-filled: silence
        for c in 0..<Int(buf.format.channelCount) { buf.floatChannelData![c].update(repeating: 0, count: n) }
        try file.write(from: buf)
        return url
    }
}
#endif
