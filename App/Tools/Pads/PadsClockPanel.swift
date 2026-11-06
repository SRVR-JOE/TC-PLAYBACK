import SwiftUI
import TCKit

/// Big running clock for the pads page, with Stop / Pause and nudge buttons.
struct PadsClockPanel: View {
    let controller: PadController
    var compact: Bool

    @AppStorage(SettingsKey.clockColorPreset) private var clockPreset = ClockColorPreset.amber.rawValue
    @AppStorage(SettingsKey.clockCustomColorHex) private var clockCustomHex = "#FFB020"

    private var clockColor: Color {
        let preset = ClockColorPreset(rawValue: clockPreset) ?? .amber
        if preset == .custom { return Color(hexString: clockCustomHex) ?? ClockColorPreset.amber.color }
        return preset.color
    }

    var body: some View {
        VStack(spacing: compact ? 10 : 12) {
            TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                let tc = controller.liveTimecode
                Text(tc?.description ?? "--:--:--:--")
                    .font(.system(size: compact ? 96 : 150, weight: .medium, design: .monospaced))
                    .foregroundStyle(tc == nil ? Theme.textTertiary : clockColor.opacity(controller.isPaused ? 0.6 : 1))
                    .lineLimit(1)
                    .minimumScaleFactor(0.1)
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 64 : 132)
            }
            statusLine
            Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
            transportRow
        }
        .padding(compact ? 12 : 16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private var statusLine: some View {
        let running = controller.isRunning
        let paused = controller.isPaused
        let cfg = controller.isOurs ? controller.activeConfig : nil
        let pad = controller.activePadID.flatMap { controller.pad($0) }
        return HStack(spacing: 14) {
            HStack(spacing: 6) {
                IndicatorLamp(color: paused ? Theme.standby : Theme.go, isOn: running || paused)
                Text(running ? "Running" : paused ? "Paused" : "Stopped")
                    .font(Theme.label)
                    .foregroundStyle(running || paused ? Theme.textPrimary : Theme.textSecondary)
            }
            if let cfg {
                Text(PadsFormat.rate(cfg.rate)).font(Theme.numeric(13)).foregroundStyle(Theme.textSecondary)
                Text("LTC · \(sideName(cfg.side))").font(Theme.label).foregroundStyle(Theme.textSecondary)
                if !compact {
                    Text(String(format: "%.0f dBFS", cfg.levelDBFS)).font(Theme.numeric(13)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            if let pad {
                Text(pad.label).font(Theme.label).foregroundStyle(Theme.textPrimary).lineLimit(1)
            }
        }
        .lineLimit(1)
    }

    private var transportRow: some View {
        let ours = controller.isOurs
        return HStack(spacing: compact ? 6 : 8) {
            transportButton(systemImage: "stop.fill", tint: Theme.stop, label: "Stop") { controller.stop() }
                .disabled(!ours)
            transportButton(systemImage: controller.isPaused ? "play.fill" : "pause.fill", tint: Theme.textPrimary,
                            label: controller.isPaused ? "Resume" : "Pause") { controller.togglePause() }
                .disabled(!ours)
            if !compact { Spacer(minLength: 12) }
            ForEach(Nudge.allCases) { n in
                Button { controller.nudge(n) } label: {
                    Text(n.label)
                        .font(.system(size: compact ? 13 : 15, weight: .medium).monospacedDigit())
                        .foregroundStyle(ours ? Theme.textPrimary : Theme.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: compact ? .infinity : 74, minHeight: compact ? 40 : 44)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.corner))
                        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(KeyPressStyle())
                .disabled(!ours)
                .accessibilityLabel("Nudge \(n.label)")
            }
        }
    }

    private func transportButton(systemImage: String, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 16 : 18, weight: .regular))
                .foregroundStyle(controller.isOurs ? tint : Theme.textTertiary)
                .frame(width: compact ? 46 : 56, height: compact ? 40 : 44)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.corner))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(KeyPressStyle())
        .accessibilityLabel(label)
    }

    private func sideName(_ s: OutputSide) -> String {
        switch s { case .left: "Left"; case .right: "Right"; case .both: "Both" }
    }
}
