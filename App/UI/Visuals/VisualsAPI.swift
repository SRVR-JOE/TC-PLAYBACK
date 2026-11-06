import SwiftUI
import TCKit

// CONTRACT FILE — owned by the VISUALS agent. These are the views the APP SHELL agent places
// on screen. Keep every type name and init signature; replace the placeholder bodies.
// All visuals pull data themselves from `PlaybackEngine` (clock via @Observable, audio via
// `analysisSnapshot()` inside a TimelineView(.animation)), so the shell only sizes/places them.

/// The big timecode readout. Reads PlaybackEngine.shared.clock; colour/style from @AppStorage
/// (SettingsKey.clockColorPreset / clockCustomColorHex / clockStyle). Scales to fill its frame
/// (uses the largest font that fits — must look right from 60pt wide on iPhone to full-width iPad).
/// Shows a status line beneath: lock lamp + state, rate, source ("LTC · Right"), LTC level,
/// and elapsed / remaining track time. `compact` hides the status line.
struct TimecodeClockView: View {
    var compact: Bool = false
    var body: some View { Text("--:--:--:--").font(Theme.numeric(48)) }
}

/// Vertical (or horizontal) stereo bar meter for OUTPUT L/R, dBFS scale -60…0 with ticks at
/// 0, -6, -12, -18, -24, -40, -60, peak-hold line (1.5 s), clip lamps (tap to reset), broadcast
/// ballistics (fast attack, ~20 dB/s fall).
struct StereoMeterView: View {
    enum Axis { case vertical, horizontal }
    var axis: Axis = .vertical
    /// Meter source/post-routing toggle.
    var showSource: Bool = false
    var body: some View { Rectangle().fill(Theme.surfaceSunken) }
}

/// Oscilloscope of the SOURCE channels. Modes: L/R overlaid, L/R stacked, X/Y (phase/goniometer).
/// Rising-edge trigger for a stable trace, adjustable timebase (pinch / buttons), graticule.
/// LTC shows as a clean bi-phase square train — this is the "is my timecode healthy" view.
struct OscilloscopeView: View {
    enum Mode: String, CaseIterable, Identifiable { case overlay, stacked, xy; var id: String { rawValue } }
    @Binding var mode: Mode
    var body: some View { Rectangle().fill(Theme.surfaceSunken) }
}

/// Waveform overview strip of the active cue with playhead, elapsed tint, tap/drag to seek
/// (disabled when `scrubEnabled` is false, e.g. show-lock). L above centre, R below, each
/// dimmed when muted, labelled where LTC lives.
struct WaveformOverviewView: View {
    var overview: Data?
    var channelCount: Int
    var duration: TimeInterval
    var scrubEnabled: Bool = true
    var body: some View { Rectangle().fill(Theme.surfaceSunken) }
}

/// Small round indicator lamp (lock / signal / tally). Flat colour, thin dark rim, no glow.
struct IndicatorLamp: View {
    var color: Color
    var isOn: Bool
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(isOn ? color : Theme.lockOff).frame(width: size, height: size)
    }
}
