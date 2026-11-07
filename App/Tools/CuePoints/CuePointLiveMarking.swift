import SwiftUI
import UIKit
import QuartzCore
import AVFoundation

/// Timing for marks dropped live: the playhead is read at touch-down, extrapolated past the
/// engine's 30 Hz position updates, then pulled back by what's heard late (speaker delay) and
/// by the operator's reaction time (tap delay). Pure maths so it can be unit tested.
enum CueMarkTiming {
    /// The engine publishes its position about 30 times a second. While playing, add the time
    /// since that value was seen (capped, so a stalled engine can't run the mark away).
    static func playhead(reported: TimeInterval, reportedAt: CFTimeInterval, now: CFTimeInterval, playing: Bool) -> TimeInterval {
        guard playing, reportedAt > 0 else { return reported }
        return reported + min(max(0, now - reportedAt), 0.1)
    }

    /// Time to store for a mark. While playing: minus speaker delay and minus the tap delay
    /// (`tapDelayMs` is 0…−150). Parked: exactly the playhead. Snapped to frames, inside the track.
    static func markTime(playhead: TimeInterval, playing: Bool, tapDelayMs: Double, outputLatency: TimeInterval,
                         fps: Double, duration: TimeInterval) -> TimeInterval {
        var t = playhead
        if playing { t += min(0, tapDelayMs) / 1000 - max(0, outputLatency) }
        let snapped = (max(0, t) * fps).rounded() / fps
        return duration > 0 ? min(snapped, duration) : snapped
    }

    /// What the audio session says reaches the ear late (output + one buffer).
    static var sessionOutputLatency: TimeInterval {
        let s = AVAudioSession.sharedInstance()
        return s.outputLatency + s.ioBufferDuration
    }
}

/// Remembers when the engine's playhead value last changed (fed from `onChange`).
final class PlayheadSampler {
    private(set) var value: TimeInterval = 0
    private(set) var stamp: CFTimeInterval = 0
    func note(_ t: TimeInterval, at now: CFTimeInterval = CACurrentMediaTime()) { value = t; stamp = now }
}

/// Fires on touch-DOWN (not release), so the mark lands when the finger hits the glass.
/// Separate views take simultaneous touches, so two pads can be hit together.
struct TouchDownArea: UIViewRepresentable {
    var label: String
    var enabled: Bool = true
    var action: () -> Void

    func makeUIView(context: Context) -> Control {
        let c = Control()
        c.addTarget(c, action: #selector(Control.down), for: .touchDown)
        c.isExclusiveTouch = false
        c.isAccessibilityElement = true
        c.accessibilityTraits = .button
        return c
    }

    func updateUIView(_ c: Control, context: Context) {
        c.action = action
        c.isEnabled = enabled
        c.accessibilityLabel = label
        c.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
    }

    final class Control: UIControl {
        var action: (() -> Void)?
        @objc func down() { action?() }
        override func accessibilityActivate() -> Bool { guard isEnabled else { return false }; action?(); return true }
    }
}

enum MarkHaptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    static func tap() { light.impactOccurred() }
}
