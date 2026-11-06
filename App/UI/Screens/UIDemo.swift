#if DEBUG
import SwiftUI
import SwiftData
import TCKit

/// DEBUG-only: `-uiDemo` seeds a realistic show straight through the SwiftData models so the
/// shell can be reviewed before the Library/Engine implementations land.
/// `-uiDemoScreen <settings|inspector|renumber|playlists|checklist|fullclock|cues|empty|idle>`
/// opens a specific screen for screenshots.
@MainActor
enum UIDemo {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-uiDemo") }
    static var screen: String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-uiDemoScreen"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func seed(context: ModelContext) {
        for p in (try? context.fetch(FetchDescriptor<Playlist>())) ?? [] { context.delete(p) }
        for t in (try? context.fetch(FetchDescriptor<Track>())) ?? [] { context.delete(t) }
        try? context.save()

        let show = Playlist(name: "Arena tour · Night 2", sortIndex: 0)
        let rehearsal = Playlist(name: "Production rehearsal", sortIndex: 1)
        let empty = Playlist(name: "Festival set", sortIndex: 2)
        [show, rehearsal, empty].forEach(context.insert)

        struct Spec { var n: String; var title: String; var dur: Double; var ltc: String?; var start: String?; var rate: String?
            var follow: FollowMode = .stop; var color: CueColorTag? = nil; var swapped = false; var lMute = false; var rMute = false; var mono = false }
        let specs: [Spec] = [
            Spec(n: "1", title: "Walk-in loop", dur: 912, ltc: nil, start: nil, rate: nil, follow: .loop, color: .grey),
            Spec(n: "2", title: "Intro — Overture", dur: 221.4, ltc: "right", start: "01:00:00:00", rate: "25", follow: .autoContinue, color: .blue),
            Spec(n: "3", title: "Opener", dur: 248.2, ltc: "right", start: "01:04:00:00", rate: "25", color: .blue),
            Spec(n: "4", title: "Bridge interlude", dur: 64.5, ltc: "right", start: "01:09:00:00", rate: "25", follow: .autoContinue),
            Spec(n: "4.5", title: "Costume change VT", dur: 95.0, ltc: "left", start: "01:10:30:00", rate: "25", color: .purple, swapped: true),
            Spec(n: "5", title: "Ballad (IEM click only)", dur: 287.0, ltc: "right", start: "01:12:30:00", rate: "25", lMute: true),
            Spec(n: "6", title: "Drum feature", dur: 132.0, ltc: "right", start: "01:18:00:00", rate: "25", color: .orange),
            Spec(n: "7", title: "Finale", dur: 356.7, ltc: "right", start: "01:20:30:00", rate: "25", follow: .autoContinue, color: .red),
            Spec(n: "8", title: "Encore", dur: 242.0, ltc: "right", start: "01:27:00:00", rate: "25", color: .red),
            Spec(n: "9", title: "Walk-out", dur: 600, ltc: nil, start: nil, rate: nil, mono: true),
        ]
        var cues: [Cue] = []
        for (i, s) in specs.enumerated() {
            let file = "demo-\(i).wav"
            FileManager.default.createFile(atPath: Track.directory.appending(path: file).path, contents: Data())
            let t = Track(title: s.title, fileName: file, duration: s.dur, sampleRate: 48_000, channelCount: s.mono ? 1 : 2)
            t.ltcChannel = s.ltc; t.ltcStart = s.start; t.ltcRate = s.rate
            t.overview = overview(seed: i, ltc: s.ltc, mono: s.mono)
            context.insert(t)
            let c = Cue(position: i, number: s.n, title: s.title, kind: .track, track: t)
            c.follow = s.follow; c.colorHex = s.color?.rawValue
            c.swapped = s.swapped; c.leftEnabled = !s.lMute; c.rightEnabled = !s.rMute
            context.insert(c); c.playlist = show
            cues.append(c)
        }
        let gen = Cue(position: specs.count, number: "10", title: "LTC chase (house clock)", kind: .generator)
        gen.genStart = "02:00:00;00"; gen.genRateRaw = FrameRate.fps29_97df.rawValue; gen.genDuration = 0
        gen.leftEnabled = false
        context.insert(gen); gen.playlist = show

        for (i, title) in ["Line check", "Timecode test 25 fps"].enumerated() {
            let c = Cue(position: i, number: "\(i + 1)", title: title, kind: .generator)
            c.genRateRaw = FrameRate.fps25.rawValue
            context.insert(c); c.playlist = rehearsal
        }
        try? context.save()

        let shell = ShellModel.shared
        shell.open(show)
        if screen == "idle" { shell.show.standby(cues[0]); return }
        if screen == "empty" { shell.open(empty); return }
        // Cue 2 playing, cue 3 in standby.
        let playing = cues[1]
        try? shell.engine.load(playing.engineSource, routing: playing.routing)
        shell.engine.play()
        shell.engine.seek(to: 83.4)
        shell.demoActiveCue = playing
        shell.show.standby(cues[2])
        switch screen {
        case "inspector": shell.inspect(cues[4])
        case "inspectorGen": shell.inspect(gen)
        case "renumber": shell.showRenumber = true; shell.phonePage = .cues
        case "playlists": shell.showPlaylists = true
        case "settings": shell.showSettings = true
        case "checklist": shell.showChecklist = true
        case "fullclock": shell.showFullClock = true
        case "cues": shell.phonePage = .cues
        default: break
        }
    }

    /// Plausible peak overview: music envelope on one side, flat LTC block on the other.
    private static func overview(seed: Int, ltc: String?, mono: Bool) -> Data {
        var bytes: [UInt8] = []
        let n = 2000
        var rng = UInt64(seed * 7919 + 17)
        func rnd() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 33) / Double(1 << 31) }
        for i in 0..<n {
            let x = Double(i) / Double(n)
            let env = 0.35 + 0.45 * pow(sin(x * .pi), 0.6) + 0.15 * sin(x * 37 + Double(seed))
            let music = UInt8(max(0, min(255, (env + (rnd() - 0.5) * 0.35) * 220)))
            let tc = UInt8(i > 6 && i < n - 4 ? 120 : 0)
            let l: UInt8 = ltc == "left" ? tc : music
            let r: UInt8 = mono ? 0 : (ltc == "right" ? tc : UInt8(max(0, min(255, Double(music) * (0.85 + rnd() * 0.2)))))
            bytes.append(l); bytes.append(r)
        }
        return Data(bytes)
    }
}

/// DEBUG `-uiDemoLandscape`: lays the app out at landscape size, rotated to fit the portrait
/// window of a headless simulator (screenshots are rotated back afterwards).
struct DemoRotator<Content: View>: View {
    @ViewBuilder var content: Content
    private var on: Bool { ProcessInfo.processInfo.arguments.contains("-uiDemoLandscape") }
    var body: some View {
        if on {
            GeometryReader { geo in
                let full = CGSize(width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                                  height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
                content
                    .environment(\.verticalSizeClass, UIDevice.current.userInterfaceIdiom == .phone ? .compact : .regular)
                    .frame(width: full.height, height: full.width)
                    .rotationEffect(.degrees(-90))
                    .frame(width: full.width, height: full.height)
            }
            .ignoresSafeArea()
        } else {
            content
        }
    }
}
#endif
