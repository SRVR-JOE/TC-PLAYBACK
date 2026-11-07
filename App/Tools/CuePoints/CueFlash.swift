import SwiftUI
import UIKit
import AVFoundation

/// What happens on the device when playback crosses a mark.
enum CueFlashKey {
    static let torch = "cueFlash.torch"          // Bool — camera light
    static let screen = "cueFlash.screen"        // Bool — full-screen colour
    static let colour = "cueFlash.colour"        // "mark" or "#RRGGBB"
    static let duration = "cueFlash.duration"    // Double seconds
}

enum CueFlash {
    /// Fires the enabled flashes. `markHex` is used when the colour setting is "mark".
    @MainActor
    static func fire(markHex: String?) {
        let d = UserDefaults.standard
        let stored = d.double(forKey: CueFlashKey.duration)
        let duration = stored > 0 ? stored : 0.25
        if d.bool(forKey: CueFlashKey.torch) { Torch.pulse(duration) }
        if d.bool(forKey: CueFlashKey.screen) {
            let choice = d.string(forKey: CueFlashKey.colour) ?? "mark"
            let hex = choice == "mark" ? (markHex ?? CuePointColor.white.rawValue) : choice
            ScreenFlash.shared.flash(UIColor(Color(hexString: hex) ?? .white), duration: duration)
        }
    }
}

/// Camera light pulse. Torch control needs no camera permission and no capture session.
enum Torch {
    static var isAvailable: Bool { AVCaptureDevice.default(for: .video)?.hasTorch ?? false }
    private static var offWork: DispatchWorkItem?

    static func pulse(_ seconds: Double) {
        guard let dev = AVCaptureDevice.default(for: .video), dev.hasTorch, dev.isTorchAvailable else { return }
        do {
            try dev.lockForConfiguration()
            try dev.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            dev.unlockForConfiguration()
        } catch { return }
        offWork?.cancel()
        let w = DispatchWorkItem {
            guard (try? dev.lockForConfiguration()) != nil else { return }
            dev.torchMode = .off
            dev.unlockForConfiguration()
        }
        offWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, seconds), execute: w)
    }

    static func off() {
        offWork?.cancel()
        guard let dev = AVCaptureDevice.default(for: .video), dev.hasTorch, dev.torchMode != .off,
              (try? dev.lockForConfiguration()) != nil else { return }
        dev.torchMode = .off
        dev.unlockForConfiguration()
    }
}

/// Solid full-screen colour, drawn in its own window above everything (status bar, nav bar,
/// sheets) and never touchable, so a flash can't swallow a tap on GO.
@MainActor
final class ScreenFlash {
    static let shared = ScreenFlash()
    private var window: UIWindow?
    private var gen = 0

    /// Builds the (hidden) flash window ahead of time so the first flash isn't late.
    @discardableResult
    func prepare() -> UIWindow? {
        if let window { return window }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return nil }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.isUserInteractionEnabled = false
        w.rootViewController = UIViewController()
        w.alpha = 0
        w.isHidden = true
        window = w
        return w
    }

    func flash(_ color: UIColor, duration: Double) {
        guard let w = prepare() else { return }
        gen += 1
        let mine = gen
        w.rootViewController?.view.backgroundColor = color
        w.alpha = 1
        w.isHidden = false
        // Hold, then a short fade so it reads as a flash, not a glitch.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.03, duration)) {
            guard self.gen == mine else { return }
            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut]) {
                w.alpha = 0
            } completion: { _ in
                if self.gen == mine { w.isHidden = true }
            }
        }
    }
}

/// Toolbar menu: choose torch / screen flash, the colour and the length, and test it.
struct CueFlashMenu: View {
    var compact = false
    @AppStorage(CueFlashKey.torch) private var torch = false
    @AppStorage(CueFlashKey.screen) private var screen = false
    @AppStorage(CueFlashKey.colour) private var colour = "mark"
    @AppStorage(CueFlashKey.duration) private var duration = 0.25

    var body: some View {
        Menu {
            Section("On each mark during playback") {
                Toggle("Flash the camera light", isOn: $torch).disabled(!Torch.isAvailable)
                Toggle("Flash the screen", isOn: $screen)
            }
            Picker("Screen colour", selection: $colour) {
                Text("Mark's own colour").tag("mark")
                ForEach(CuePointColor.allCases) { c in Text(c.label).tag(c.rawValue) }
            }
            .pickerStyle(.menu)
            Picker("Flash length", selection: $duration) {
                Text("Short · 0.1 s").tag(0.1)
                Text("Medium · 0.25 s").tag(0.25)
                Text("Long · 0.5 s").tag(0.5)
                Text("Hold · 1 s").tag(1.0)
            }
            .pickerStyle(.menu)
            Button { CueFlash.fire(markHex: CuePointColor.amber.rawValue) } label: { Label("Test flash", systemImage: "bolt") }
                .disabled(!torch && !screen)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: torch || screen ? "bolt.fill" : "bolt.slash")
                if !compact { Text("Flash") }
            }
            .font(Theme.label)
            .foregroundStyle(torch || screen ? Theme.standby : Theme.textSecondary)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .accessibilityLabel("Flash on marks, \(torch || screen ? "on" : "off")")
    }
}
