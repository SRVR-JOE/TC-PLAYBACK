import SwiftUI
import TCKit

/// Mono timecode field driven by `TCEntry` (right-to-left). Digits typed since arming are drawn
/// bright, untouched leading digits dim — the way a TC calculator shows entry progress.
struct TCEntryField: View {
    let entry: TCEntry
    let rate: FrameRate
    var isActive: Bool = true
    var isValid: Bool = true
    var size: CGFloat = 34

    var body: some View {
        let text = entry.display(rate: rate)
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { idx, ch in
                Text(String(ch))
                    .foregroundStyle(color(forCharAt: idx, in: text))
            }
        }
        .font(Theme.numeric(size, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(isActive ? (isValid ? Theme.accent : Theme.stop) : Theme.hairline,
                              lineWidth: isActive ? 1.5 : Theme.hairlineWidth)
        )
        .accessibilityLabel(text)
    }

    private func color(forCharAt idx: Int, in text: String) -> Color {
        let chars = Array(text)
        guard chars[idx].isNumber else { return Theme.textSecondary }
        guard isActive, !entry.isFresh else { return isValid ? Theme.textPrimary : Theme.stop }
        let digitIndex = chars[...idx].filter(\.isNumber).count - 1
        let typed = digitIndex >= 8 - entry.typedCount
        guard typed else { return Theme.textTertiary }
        return isValid ? Theme.textPrimary : Theme.stop
    }
}

/// Numeric keypad laid out like a calculator: 7 8 9 / 4 5 6 / 1 2 3 / 00 0 ⌫, plus Clear.
struct TCKeypad: View {
    var onDigit: (Int) -> Void
    var onDoubleZero: () -> Void
    var onBackspace: () -> Void
    var onClear: () -> Void
    var keyHeight: CGFloat = 48

    private let rows: [[Int]] = [[7, 8, 9], [4, 5, 6], [1, 2, 3]]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { d in key(Text("\(d)").font(Theme.numeric(22))) { onDigit(d) } }
                }
            }
            HStack(spacing: 6) {
                key(Text("00").font(Theme.numeric(22)), action: onDoubleZero)
                key(Text("0").font(Theme.numeric(22))) { onDigit(0) }
                key(Image(systemName: "delete.left").font(.system(size: 19, weight: .light)), action: onBackspace)
                    .accessibilityLabel("Delete")
            }
            key(Text("Clear").font(Theme.label), action: onClear)
        }
    }

    private func key<L: View>(_ label: L, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: keyHeight)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.corner))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
        }
        .buttonStyle(KeyPressStyle())
    }
}

/// Flat press feedback: darken, no scale bounce.
struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
