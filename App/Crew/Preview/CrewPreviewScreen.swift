#if DEBUG
import SwiftUI
import TCKit

/// DEBUG-only developer preview of the crew framework. Launch with `-crewPreview`.
/// Not a product UI: it exists to exercise the engine pieces on a device. It never starts
/// playback; the playhead is simulated, or read from the engine if something else is playing.
enum CrewPreview {
    static var isRequested: Bool { FeatureFlags.crewCueing && ProcessInfo.processInfo.arguments.contains("-crewPreview") }

    /// A made-up 3-minute song: a shot lane with four cameras plus lighting and SFX cues.
    static let shotLane = CuePointType(id: UUID(uuidString: "00000000-0000-0000-0000-0000000C5A01")!, name: "Shots", colorHex: CuePointColor.purple.rawValue)
    static let lightLane = CuePointType(id: UUID(uuidString: "00000000-0000-0000-0000-0000000C5A02")!, name: "Lights", colorHex: CuePointColor.blue.rawValue)
    static let sfxLane = CuePointType(id: UUID(uuidString: "00000000-0000-0000-0000-0000000C5A03")!, name: "Special FX", colorHex: CuePointColor.red.rawValue)
    static var lanes: [CuePointType] { [shotLane, lightLane, sfxLane] }

    static func sampleCues() -> [CrewCue] {
        var out: [CrewCue] = []
        let sizes = ["WS", "MS", "CU", "MCU", "ECU"]
        var t: TimeInterval = 2
        var n = 1
        while t < 180 {
            out.append(CrewCue(id: UUID(), time: t, name: "Shot \(n)", laneID: shotLane.id, camera: (n - 1) % 4 + 1,
                               shotNumber: String(n), shotSize: sizes[n % sizes.count], shotNote: n % 5 == 0 ? "Push in" : ""))
            t += [3, 4, 2, 6, 5][n % 5]; n += 1
        }
        for (i, lt) in stride(from: 8.0, to: 180, by: 16).enumerated() {
            out.append(CrewCue(id: UUID(), time: lt, name: "LX \(i + 1)", laneID: lightLane.id, cueID: String(i + 1)))
        }
        for (i, ft) in [30.0, 62, 95, 150].enumerated() {
            out.append(CrewCue(id: UUID(), time: ft, name: "Pyro \(i + 1)", laneID: sfxLane.id, cueID: String(i + 1)))
        }
        return out.sorted(by: CrewCue.timeOrder)
    }

    static let grid = BeatGrid(bpm: 120, firstBeat: 0)
}

struct CrewPreviewScreen: View {
    @State private var cues = CrewPreview.sampleCues()
    @State private var roles = CrewRoleStore.starterRoles(types: CrewPreview.lanes)
    @State private var roleID: UUID?
    @State private var useEngine = false
    @State private var simStart = Date()
    @State private var follow = FollowMachine()
    @State private var ltcRunning = true
    @State private var syncResult: CrewLoopbackDemo.Result?
    @State private var pdfURL: URL?

    private var role: CrewRole? { roles.first { $0.id == roleID } ?? roles.first }

    var body: some View {
        NavigationStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                let host = ProcessInfo.processInfo.systemUptime
                let source = sourcePlayhead(ctx.date)
                List {
                    Section("Role") {
                        Picker("Role", selection: Binding(get: { role?.id }, set: { roleID = $0 })) {
                            ForEach(roles) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Toggle("Use engine playhead", isOn: $useEngine)
                    }
                    Section("Follow") { followSection(host: host, source: source) }
                    if let role { Section("Countdown") { countdown(role: role, playhead: follow.playhead(at: host)) } }
                    Section("Loopback sync") {
                        Button("Run 20 s simulation") { syncResult = CrewLoopbackDemo.run() }
                        if let r = syncResult {
                            row("Max error", String(format: "%.2f ms", r.maxErrorAfterSync * 1000))
                            row("Offset error", String(format: "%.3f ms", (r.estimatedOffset - r.trueOffset) * 1000))
                            row("Median round trip", String(format: "%.1f ms", r.medianRoundTrip * 1000))
                        }
                    }
                    Section("Cue sheet") {
                        Button("Make PDF for this role") { makePDF() }
                        if let pdfURL { ShareLink("Share PDF", item: pdfURL) }
                    }
                }
                .onChange(of: Int(ctx.date.timeIntervalSince1970 * 30)) { _, _ in
                    if ltcRunning { follow.ltc(trackTime: source, host: host) }
                    follow.tick(host: host)
                }
            }
            .navigationTitle("Crew preview")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func sourcePlayhead(_ date: Date) -> TimeInterval {
        if useEngine { return PlaybackEngine.shared.preciseTime }
        return date.timeIntervalSince(simStart).truncatingRemainder(dividingBy: 180)
    }

    @ViewBuilder private func followSection(host: TimeInterval, source: TimeInterval) -> some View {
        row("State", follow.state.label)
        row("Playhead", String(format: "%.2f s", follow.playhead(at: host)))
        row("Nudge", String(format: "%+.3f s", follow.nudge))
        Toggle("Timecode arriving", isOn: $ltcRunning)
        HStack {
            Button("Prev") { step(-1, host: host) }.buttonStyle(.bordered)
            Button("Next") { step(1, host: host) }.buttonStyle(.bordered)
            Spacer()
            Button("Resume") { follow.resumeFollowing(host: host) }.buttonStyle(.bordered)
        }
        HStack {
            Button("−1 frame") { follow.nudge(by: -1.0 / 30) }.buttonStyle(.bordered)
            Button("+1 frame") { follow.nudge(by: 1.0 / 30) }.buttonStyle(.bordered)
            Spacer()
            Button("Reset") { follow.resetNudge() }.buttonStyle(.bordered)
        }
    }

    @ViewBuilder private func countdown(role: CrewRole, playhead: TimeInterval) -> some View {
        let m = CountdownModel(role: role, cues: cues, playhead: playhead, grid: CrewPreview.grid)
        row("Now", m.window.now.map(label) ?? "–")
        row("Next", m.window.next.map(label) ?? "–")
        row("After", m.window.after.map(label) ?? "–")
        row("In", m.secondsToNext.map { String(format: "%.1f s", $0) } ?? "–")
        if let bb = m.barsBeatsToNext { row("Bars / beats", "\(bb.bars) / \(bb.beats)") }
        ProgressView(value: m.progress)
    }

    private func label(_ c: CrewCue) -> String {
        var s = c.name
        if let cam = c.camera { s += " · Cam \(cam)" }
        if !c.shotSize.isEmpty { s += " · \(c.shotSize)" }
        return s
    }

    private func step(_ d: Int, host: TimeInterval) {
        guard let role else { return }
        follow.step(d, cueTimes: CrewLaneFilter.cues(for: role, in: cues).map(\.time), host: host)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(Theme.textSecondary); Spacer(); Text(v).monospacedDigit() }
    }

    private func makePDF() {
        guard let role else { return }
        let clock = CuePointClock(start: Timecode(hours: 1, rate: .fps30))
        let r = CueSheetRenderer()
        let data = r.render(title: "Sample show", track: "Sample song", roleName: role.name,
                            rows: CueSheetRenderer.rows(cues: cues, role: role, lanes: CrewPreview.lanes, clock: clock))
        let url = URL.temporaryDirectory.appending(path: "\(role.name) cue sheet.pdf")
        try? data.write(to: url, options: .atomic)
        pdfURL = url
    }
}
#endif
