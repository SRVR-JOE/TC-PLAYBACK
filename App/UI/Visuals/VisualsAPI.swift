import SwiftUI
import TCKit

// CONTRACT FILE — owned by the VISUALS agent. These are the views the APP SHELL agent places
// on screen. Keep every type name and init signature; replace the placeholder bodies.
// All visuals pull data themselves from `PlaybackEngine` (clock via @Observable, audio via
// `analysisSnapshot()` inside a TimelineView(.animation)), so the shell only sizes/places them.
// Implementations live in the sibling files; data comes from `\.visualsDataSource` (defaults to
// the live engine; `DemoVisualsDataSource` for previews).

/// The big timecode readout. Reads PlaybackEngine.shared.clock; colour/style from @AppStorage
/// (SettingsKey.clockColorPreset / clockCustomColorHex / clockStyle). Scales to fill its frame
/// (uses the largest font that fits — must look right from 60pt wide on iPhone to full-width iPad).
/// Shows a status line beneath: lock lamp + state, rate, source ("LTC · Right"), LTC level,
/// and elapsed / remaining track time. `compact` hides the status line.
struct TimecodeClockView: View {
    var compact: Bool = false
    var body: some View { TimecodeClockContent(compact: compact) }
}

/// Vertical (or horizontal) stereo bar meter for OUTPUT L/R, dBFS scale -60…0 with ticks at
/// 0, -6, -12, -18, -24, -40, -60, peak-hold line (1.5 s), clip lamps (tap to reset), broadcast
/// ballistics (fast attack, ~20 dB/s fall).
struct StereoMeterView: View {
    enum Axis { case vertical, horizontal }
    var axis: Axis = .vertical
    /// Meter source/post-routing toggle.
    var showSource: Bool = false
    var body: some View { StereoMeterContent(axis: axis, showSource: showSource) }
}

/// Oscilloscope of the SOURCE channels. Modes: L/R overlaid, L/R stacked, X/Y (phase/goniometer).
/// Rising-edge trigger for a stable trace, adjustable timebase (pinch / buttons), graticule.
/// LTC shows as a clean bi-phase square train — this is the "is my timecode healthy" view.
/// `.eye` (additive) overlays every LTC bit period; only offered while a channel carries LTC.
struct OscilloscopeView: View {
    enum Mode: String, CaseIterable, Identifiable { case overlay, stacked, xy, eye; var id: String { rawValue } }
    @Binding var mode: Mode
    var body: some View { OscilloscopeContent(mode: $mode) }
}

/// Waveform overview strip of the active cue with playhead, elapsed tint, tap/drag to seek
/// (disabled when `scrubEnabled` is false, e.g. show-lock). L above centre, R below, each
/// dimmed when muted, labelled where LTC lives.
struct WaveformOverviewView: View {
    var overview: Data?
    var channelCount: Int
    var duration: TimeInterval
    var scrubEnabled: Bool = true
    var body: some View {
        WaveformOverviewContent(overview: overview, channelCount: channelCount, duration: duration,
                                scrubEnabled: scrubEnabled)
    }
}

/// Small round indicator lamp (lock / signal / tally). Flat colour, thin dark rim, no glow.
struct IndicatorLamp: View {
    var color: Color
    var isOn: Bool
    var size: CGFloat = 8
    var body: some View {
        let rim = max(0.5, size * 0.09)
        Circle()
            .fill(isOn ? color : Theme.lockOff)
            // Thin inner highlight ring: reads as a lens without any gradient or glow.
            .overlay(Circle().inset(by: rim).strokeBorder(Color.white.opacity(isOn ? 0.22 : 0.07), lineWidth: max(0.5, rim * 0.6)))
            // Dark rim, like a panel-mount lamp bezel.
            .overlay(Circle().strokeBorder(Color.black.opacity(isOn ? 0.35 : 0.5), lineWidth: rim))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
