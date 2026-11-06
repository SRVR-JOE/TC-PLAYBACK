import SwiftUI
import TCKit

// Owned by the VISUALS agent. A development gallery of every visual against the demo signal.
// Not wired into the app; show it from a scratch RootView or a preview.
// Pages (UserDefaults / launch args): -galleryPage main|clocks|scope, -galleryScheme dark|light.

struct VisualsGallery: View {
    var page: String = UserDefaults.standard.string(forKey: "galleryPage") ?? "main"
    var scheme: ColorScheme = UserDefaults.standard.string(forKey: "galleryScheme") == "light" ? .light : .dark

    var body: some View {
        Group {
            switch page {
            case "clocks": ClockGalleryPage()
            case "scope": ScopeGalleryPage()
            case "scope1": SingleScopePage()
            default: MainGalleryPage()
            }
        }
        .background(GalleryPanel.background.ignoresSafeArea())
        .preferredColorScheme(scheme)
    }
}

/// Panel surfaces for the gallery. Theme is dark-only for now, so light mode falls back to system
/// colours here (the shell owns Theme adaptivity).
enum GalleryPanel {
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Theme.background) : .systemGroupedBackground })
    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(Theme.surface) : .secondarySystemGroupedBackground })
}

private struct Panel<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary) }
            content
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(GalleryPanel.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
    }
}

private enum GalleryStore {
    static func defaults(_ name: String, style: ClockStyle, color: ClockColorPreset) -> UserDefaults {
        let d = UserDefaults(suiteName: "gallery.\(name)")!
        d.set(style.rawValue, forKey: SettingsKey.clockStyle)
        d.set(color.rawValue, forKey: SettingsKey.clockColorPreset)
        return d
    }
}

private struct MainGalleryPage: View {
    @State private var demo = DemoVisualsDataSource()
    @State private var mode: OscilloscopeView.Mode = .overlay
    private let overview = DemoVisualsDataSource.demoOverview()

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 700
            VStack(spacing: 10) {
                Panel {
                    TimecodeClockView()
                        .frame(height: wide ? 210 : 120)
                }
                Panel {
                    WaveformOverviewView(overview: overview, channelCount: 2, duration: demo.duration)
                        .frame(height: wide ? 72 : 56)
                }
                if wide {
                    HStack(spacing: 10) {
                        Panel { OscilloscopeView(mode: $mode) }
                        Panel { StereoMeterView() }.frame(width: 104)
                    }
                } else {
                    Panel { StereoMeterView(axis: .horizontal).frame(height: 40) }
                    Panel { OscilloscopeView(mode: $mode) }
                }
            }
            .padding(12)
        }
        .visualsDataSource(demo)
    }
}

private struct ClockGalleryPage: View {
    @State private var locked = DemoVisualsDataSource()
    @State private var freewheel = DemoVisualsDataSource(rate: .fps29_97df, lock: .freewheel)
    @State private var segment = DemoVisualsDataSource(rate: .fps25, source: .decoded(.left), ltcSide: .left)
    @State private var trackTime = DemoVisualsDataSource(source: .trackTime)
    @State private var lost: DemoVisualsDataSource = {
        let d = DemoVisualsDataSource(rate: .fps29_97ndf, source: .externalInput)
        d.discontinuities = 3
        d.isReverse = true
        return d
    }()
    @State private var none = DemoVisualsDataSource(lock: .noSignal)
    @State private var generator = DemoVisualsDataSource(rate: .fps24, source: .generator)

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                clock(locked, "mono", .mono, .white, h: 110)
                clock(segment, "segment", .segment, .green, h: 110)
                clock(freewheel, "rounded", .rounded, .white, h: 90)
                clock(lost, "monoAmber", .mono, .amber, h: 80)
                clock(none, "segRed", .segment, .red, h: 80)
                HStack(spacing: 10) {
                    clock(trackTime, "segBlue", .segment, .blue, h: 50, compact: true)
                    clock(generator, "monoComp", .mono, .white, h: 50, compact: true)
                }
                Panel { LTCHealthView() }.visualsDataSource(lost)
            }
            .padding(12)
        }
    }

    private func clock(_ d: DemoVisualsDataSource, _ name: String, _ s: ClockStyle, _ c: ClockColorPreset,
                       h: CGFloat, compact: Bool = false) -> some View {
        Panel {
            TimecodeClockView(compact: compact).frame(height: h)
        }
        .visualsDataSource(d)
        .defaultAppStorage(GalleryStore.defaults(name, style: s, color: c))
    }
}

private struct ScopeGalleryPage: View {
    @State private var demo = DemoVisualsDataSource()
    @State private var overlay: OscilloscopeView.Mode = .overlay
    @State private var stacked: OscilloscopeView.Mode = .stacked
    @State private var xy: OscilloscopeView.Mode = .xy

    var body: some View {
        VStack(spacing: 10) {
            Panel { OscilloscopeView(mode: $overlay) }
            Panel { OscilloscopeView(mode: $stacked) }
            HStack(spacing: 10) {
                Panel { OscilloscopeView(mode: $xy) }
                Panel { StereoMeterView(showSource: true) }.frame(width: 104)
            }
        }
        .padding(12)
        .visualsDataSource(demo)
    }
}

/// One large scope; mode from -scopeMode overlay|stacked|xy|eye.
private struct SingleScopePage: View {
    @State private var demo = DemoVisualsDataSource()
    @State private var mode = OscilloscopeView.Mode(rawValue: UserDefaults.standard.string(forKey: "scopeMode") ?? "") ?? .overlay
    var body: some View {
        VStack(spacing: 10) {
            Panel { OscilloscopeView(mode: $mode) }
            Panel { StereoMeterView(axis: .horizontal).frame(height: 40) }
        }
        .padding(12)
        .visualsDataSource(demo)
    }
}

// MARK: - Previews

#Preview("Gallery, dark") { VisualsGallery(page: "main", scheme: .dark) }
#Preview("Gallery, light") { VisualsGallery(page: "main", scheme: .light) }
#Preview("Clocks, dark") { VisualsGallery(page: "clocks", scheme: .dark) }
#Preview("Clocks, light") { VisualsGallery(page: "clocks", scheme: .light) }

#Preview("Clock, dark") {
    TimecodeClockView().frame(height: 160).padding().background(Theme.background)
        .visualsDataSource(DemoVisualsDataSource()).preferredColorScheme(.dark)
}
#Preview("Clock, light") {
    TimecodeClockView().frame(height: 160).padding().background(Color(.systemBackground))
        .visualsDataSource(DemoVisualsDataSource(rate: .fps29_97df, lock: .freewheel)).preferredColorScheme(.light)
}
#Preview("Meters, dark") {
    HStack(spacing: 20) {
        StereoMeterView().frame(width: 90, height: 280)
        StereoMeterView(axis: .horizontal).frame(width: 280, height: 40)
    }
    .padding().background(Theme.background)
    .visualsDataSource(DemoVisualsDataSource()).preferredColorScheme(.dark)
}
#Preview("Meters, light") {
    HStack(spacing: 20) {
        StereoMeterView().frame(width: 90, height: 280)
        StereoMeterView(axis: .horizontal).frame(width: 280, height: 40)
    }
    .padding().background(Color(.systemBackground))
    .visualsDataSource(DemoVisualsDataSource()).preferredColorScheme(.light)
}
#Preview("Scope, dark") {
    @Previewable @State var mode: OscilloscopeView.Mode = .overlay
    OscilloscopeView(mode: $mode).frame(height: 260).padding().background(Theme.background)
        .visualsDataSource(DemoVisualsDataSource()).preferredColorScheme(.dark)
}
#Preview("Scope, light") {
    @Previewable @State var mode: OscilloscopeView.Mode = .stacked
    OscilloscopeView(mode: $mode).frame(height: 260).padding().background(Color(.systemBackground))
        .visualsDataSource(DemoVisualsDataSource()).preferredColorScheme(.light)
}
#Preview("Waveform, dark") {
    VStack {
        WaveformOverviewView(overview: DemoVisualsDataSource.demoOverview(), channelCount: 2, duration: 225).frame(height: 64)
        WaveformOverviewView(overview: nil, channelCount: 2, duration: 225).frame(height: 64)
    }
    .padding().background(Theme.background)
    .visualsDataSource(DemoVisualsDataSource()).preferredColorScheme(.dark)
}
#Preview("Waveform, light") {
    WaveformOverviewView(overview: DemoVisualsDataSource.demoOverview(), channelCount: 2, duration: 225).frame(height: 64)
        .padding().background(Color(.systemBackground))
        .visualsDataSource(DemoVisualsDataSource()).preferredColorScheme(.light)
}
#Preview("Lamps") {
    HStack(spacing: 12) {
        IndicatorLamp(color: Theme.lockOK, isOn: true, size: 10)
        IndicatorLamp(color: Theme.lockWarn, isOn: true, size: 10)
        IndicatorLamp(color: Theme.stop, isOn: true, size: 10)
        IndicatorLamp(color: Theme.stop, isOn: false, size: 10)
        IndicatorLamp(color: Theme.lockOK, isOn: true, size: 24)
    }
    .padding().background(Theme.background)
}
