import SwiftUI

// Shared view modifiers and button styles. Flat surfaces, hairline borders, no shadows.

// MARK: - Panel

struct PanelModifier: ViewModifier {
    var padding: CGFloat = Theme.pad
    var fill: Color = Theme.surface
    var corner: CGFloat = Theme.cornerLarge
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
    }
}

struct SectionHeaderModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.sectionHeader)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
    }
}

extension View {
    /// Flat surface + hairline border + corner.
    func panel(padding: CGFloat = Theme.pad, fill: Color = Theme.surface, corner: CGFloat = Theme.cornerLarge) -> some View {
        modifier(PanelModifier(padding: padding, fill: fill, corner: corner))
    }
    /// SF Pro 12 semibold, secondary colour, sentence case.
    func sectionHeaderStyle() -> some View { modifier(SectionHeaderModifier()) }

    /// Hairline divider drawn on one edge.
    func hairline(_ edge: Edge) -> some View {
        overlay(alignment: edge.alignment) {
            Rectangle().fill(Theme.hairline)
                .frame(width: edge.isHorizontal ? Theme.hairlineWidth : nil,
                       height: edge.isHorizontal ? nil : Theme.hairlineWidth)
        }
    }
}

private extension Edge {
    var isHorizontal: Bool { self == .leading || self == .trailing }
    var alignment: Alignment {
        switch self { case .top: .top; case .bottom: .bottom; case .leading: .leading; case .trailing: .trailing }
    }
}

/// A sentence-case section header with optional trailing accessory.
struct SectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing
    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.trailing = trailing()
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).sectionHeaderStyle().fixedSize().layoutPriority(1)
            Spacer(minLength: 4)
            trailing
        }
    }
}

// MARK: - Buttons

/// GO: big solid green when a cue is in standby; flat grey when there is nothing to fire.
struct GoButtonStyle: ButtonStyle {
    var armed: Bool
    var corner: CGFloat = Theme.cornerLarge
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .foregroundStyle(armed ? Color.white : Theme.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(armed ? Theme.go : Theme.surfaceRaised)
                    .brightness(pressed && armed ? -0.14 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(armed ? Color.black.opacity(pressed ? 0.35 : 0.18) : Theme.hairline,
                                  lineWidth: pressed ? 2 : Theme.hairlineWidth)
            )
            .scaleEffect(pressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Flat, outlined transport/utility button. `tint` colours the symbol (state only).
struct FlatButtonStyle: ButtonStyle {
    var tint: Color = Theme.textPrimary
    var corner: CGFloat = Theme.corner
    var fill: Color = Theme.surfaceRaised
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? tint : Theme.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(configuration.isPressed ? Theme.hairline : fill))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Latching button (hardware "lit key"). Off: outlined. On: solid state colour.
struct LatchButtonStyle: ButtonStyle {
    var isOn: Bool
    var onColor: Color
    var corner: CGFloat = Theme.corner
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? Color.white : (isEnabled ? Theme.textPrimary : Theme.textTertiary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(isOn ? onColor : (configuration.isPressed ? Theme.hairline : Theme.surfaceRaised))
                .brightness(isOn && configuration.isPressed ? -0.1 : 0))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(isOn ? Color.clear : Theme.hairline, lineWidth: Theme.hairlineWidth))
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .animation(.easeOut(duration: 0.1), value: isOn)
    }
}

/// Small text button for secondary actions (sheets, empty states).
struct OutlineButtonStyle: ButtonStyle {
    var prominent: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label)
            .foregroundStyle(prominent ? Color.white : Theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(prominent ? Theme.accent : (configuration.isPressed ? Theme.hairline : Theme.surfaceRaised))
                .brightness(prominent && configuration.isPressed ? -0.1 : 0))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(prominent ? Color.clear : Theme.hairline, lineWidth: Theme.hairlineWidth))
            .contentShape(Rectangle())
    }
}

// MARK: - Hold-to-confirm

/// Wraps content in a press-and-hold gesture with a progress ring/bar. Used for locked stop,
/// and for routing changes while a cue plays under Show Lock.
struct HoldToConfirm<Label: View>: View {
    var duration: Double
    var enabled: Bool = true
    var ringColor: Color = Theme.stop
    var corner: CGFloat = Theme.corner
    var action: () -> Void
    @ViewBuilder var label: Label
    @State private var progress: CGFloat = 0
    @State private var holding = false

    var body: some View {
        label
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .trim(from: 0, to: progress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(1.5)
                    .opacity(holding ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onLongPressGesture(minimumDuration: duration, maximumDistance: 30) {
                holding = false; progress = 0
                action()
            } onPressingChanged: { pressing in
                guard enabled else { return }
                holding = pressing
                if pressing {
                    progress = 0
                    withAnimation(.linear(duration: duration)) { progress = 1 }
                } else {
                    withAnimation(.easeOut(duration: 0.12)) { progress = 0 }
                }
            }
    }
}

// MARK: - Haptics

enum Haptics {
    static func go() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func stop() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - Segmented

/// Compact flat segmented control (hardware-style page keys, no capsule).
struct FlatSegmented<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value
    var height: CGFloat = 24
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                let on = opt.0 == selection
                Button { selection = opt.0; Haptics.tick() } label: {
                    Text(opt.1)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: height)
                        .background(on ? Theme.surfaceRaised : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < options.count - 1 {
                    Rectangle().fill(Theme.hairline).frame(width: Theme.hairlineWidth, height: height)
                }
            }
        }
        .background(Theme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
        .fixedSize()
    }
}

// MARK: - Fader

/// Flat horizontal fader: hairline track, unity tick, small rectangular cap (no system capsule).
struct FaderSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var unity: Double? = 0
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 12
            let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline).frame(height: 3).padding(.horizontal, 6)
                Capsule().fill(Theme.textSecondary).frame(width: max(0, w * f), height: 3).padding(.leading, 6)
                if let unity {
                    let u = (unity - range.lowerBound) / (range.upperBound - range.lowerBound)
                    Rectangle().fill(Theme.textTertiary).frame(width: 1, height: 12).offset(x: 6 + w * u)
                }
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.textSecondary, lineWidth: 1))
                    .overlay(Rectangle().fill(Theme.textPrimary).frame(width: 1, height: 10))
                    .frame(width: 12, height: 22)
                    .offset(x: w * f)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard isEnabled else { return }
                let x = min(max(0, g.location.x - 6), w)
                value = range.lowerBound + Double(x / w) * (range.upperBound - range.lowerBound)
            })
            .opacity(isEnabled ? 1 : 0.45)
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Gain")
        .accessibilityValue(Fmt.dB(Float(value)))
        .accessibilityAdjustableAction { dir in
            value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? 0.5 : -0.5)))
        }
    }
}
