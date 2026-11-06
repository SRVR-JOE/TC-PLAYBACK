import SwiftUI

/// Hardware keyboard shortcuts (iPad): Space = GO, Esc = stop, ↑/↓ = move standby, P = pause.
/// With Show Lock on, Esc must be pressed twice within 1.5 s (a key can't be held-to-confirm
/// through SwiftUI shortcuts); the stop then fades as a panic stop.
struct KeyCommands: View {
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false
    @State private var escArmedAt: Date?

    /// Don't steal keys while the operator is typing.
    private var suspended: Bool {
        shell.showInspector || shell.editingNumberCueID != nil || shell.showRenumber
            || shell.showSettings || shell.showPlaylists || shell.showChecklist
    }

    var body: some View {
        ZStack {
            key(.space) { shell.go() }
            key(.escape) { escape() }
            key(.upArrow) { shell.show.previous() }
            key(.downArrow) { shell.show.next() }
            key("p") { shell.pauseResume() }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .disabled(suspended)
    }

    private func key(_ k: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button("", action: action).keyboardShortcut(k, modifiers: [])
    }

    private func escape() {
        if shell.showFullClock { shell.showFullClock = false; return }
        guard showLock else { shell.stop(locked: false); return }
        if let t = escArmedAt, Date().timeIntervalSince(t) < 1.5 {
            escArmedAt = nil
            shell.banner = nil
            shell.stop(locked: true)
        } else {
            escArmedAt = Date()
            shell.banner = ShellBanner(kind: .warning, text: "Show Lock: press Esc again to stop")
            let armed = escArmedAt
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if escArmedAt == armed {
                    escArmedAt = nil
                    if shell.banner?.kind == .warning { shell.banner = nil }
                }
            }
        }
    }
}
