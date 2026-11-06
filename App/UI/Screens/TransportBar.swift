import SwiftUI

/// Previous · Stop · GO · Pause/Resume · Next, plus elapsed/remaining, follow mode and next cue.
struct TransportBar: View {
    enum Layout { case regular, compact }
    var layout: Layout = .regular
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false

    private var standby: Cue? { shell.standbyCue }
    private var active: Cue? { shell.activeCue }

    var body: some View {
        switch layout {
        case .regular: regular
        case .compact: compact
        }
    }

    // MARK: Layouts

    private var regular: some View {
        HStack(spacing: 10) {
            prevButton.frame(width: 56)
            StopKey().frame(width: 76)
            GoKey(titleSize: 30).frame(width: 240)
            PauseKey().frame(width: 76)
            nextButton.frame(width: 56)
            Rectangle().fill(Theme.hairline).frame(width: Theme.hairlineWidth).padding(.vertical, 4).padding(.horizontal, 8)
            infoBlock
        }
        .frame(height: 84)
    }

    private var compact: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Fmt.elapsed(active == nil ? 0 : shell.elapsed))
                    .font(Theme.numeric(15, weight: .semibold))
                    .foregroundStyle(shell.isRunning ? Theme.textPrimary : Theme.textTertiary)
                nextLabel.frame(maxWidth: .infinity)
                Text(Fmt.remaining(active == nil ? nil : shell.remaining))
                    .font(Theme.numeric(15, weight: .regular))
                    .foregroundStyle(shell.isRunning ? Theme.textSecondary : Theme.textTertiary)
            }
            HStack(spacing: 8) {
                prevButton.frame(width: 44)
                StopKey().frame(width: 62)
                GoKey(titleSize: 24)
                PauseKey(showsLabel: false).frame(width: 62)
                nextButton.frame(width: 44)
            }
            .frame(height: 64)
        }
    }

    // MARK: Info

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                timeReadout("Elapsed", Fmt.elapsed(active == nil ? 0 : shell.elapsed), primary: true)
                timeReadout("Remaining", Fmt.remaining(active == nil ? nil : shell.remaining), primary: false)
                Spacer(minLength: 0)
                if shell.canBackOne {
                    Button { shell.backOne() } label: {
                        Label("Back one", systemImage: "arrow.uturn.backward")
                            .font(Theme.caption)
                            .padding(.horizontal, 10).frame(height: 26)
                    }
                    .buttonStyle(FlatButtonStyle(tint: Theme.textSecondary))
                    .fixedSize()
                    .help("Re-arm the cue that was just fired")
                }
            }
            HStack(spacing: 14) {
                if let cue = active ?? standby {
                    HStack(spacing: 5) {
                        FollowGlyph(mode: cue.follow)
                        Text(cue.follow.label)
                    }
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                }
                nextLabel
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeReadout(_ title: String, _ value: String, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(Theme.numeric(22, weight: primary ? .semibold : .regular))
                .foregroundStyle(shell.isRunning ? (primary ? Theme.textPrimary : Theme.textSecondary) : Theme.textTertiary)
                .monospacedDigit()
        }
        .fixedSize()
    }

    /// While a cue runs the standby cue is the next one; otherwise the one after standby.
    private var nextCue: Cue? { shell.isRunning ? standby : shell.cue(after: standby) }

    private var nextLabel: some View {
        HStack(spacing: 5) {
            Text("Next").foregroundStyle(Theme.textTertiary)
            if let n = nextCue {
                Text(n.number).font(Theme.numeric(12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Text(n.title).foregroundStyle(Theme.textSecondary).lineLimit(1)
            } else {
                Text("End of list").foregroundStyle(Theme.textTertiary)
            }
        }
        .font(Theme.caption)
        .lineLimit(1)
    }

    // MARK: Buttons

    private var prevButton: some View {
        Button { shell.show.previous(); Haptics.tick() } label: {
            Image(systemName: "chevron.up").font(.system(size: 16, weight: .medium))
        }
        .buttonStyle(FlatButtonStyle(tint: Theme.textSecondary))
        .accessibilityLabel("Previous cue to standby")
    }

    private var nextButton: some View {
        Button { shell.show.next(); Haptics.tick() } label: {
            Image(systemName: "chevron.down").font(.system(size: 16, weight: .medium))
        }
        .buttonStyle(FlatButtonStyle(tint: Theme.textSecondary))
        .accessibilityLabel("Next cue to standby")
    }
}
