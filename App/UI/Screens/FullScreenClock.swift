import SwiftUI

/// Black, clock-only view with a small status line. Swipe down (or tap Done) to exit.
struct FullScreenClock: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var shell = ShellModel.shared
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                TimecodeClockView(compact: true)
                    .frame(maxWidth: .infinity)
                    .frame(height: landscape ? geo.size.height * 0.62 : geo.size.width * 0.34)
                    .padding(.horizontal, landscape ? 32 : 12)
                Spacer(minLength: 0)
                statusLine
                    .padding(.horizontal, 24)
                    .padding(.bottom, landscape ? 16 : 28)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .offset(y: max(0, drag))
        .opacity(1 - Double(max(0, drag) / 600))
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { drag = $0.translation.height }
                .onEnded { v in
                    if v.translation.height > 120 || v.predictedEndTranslation.height > 300 { dismiss() }
                    else { withAnimation(.easeOut(duration: 0.2)) { drag = 0 } }
                }
        )
        .onTapGesture(count: 2) { dismiss() }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .ignoresSafeArea()
        .accessibilityAction(.escape) { dismiss() }
    }

    private var statusLine: some View {
        HStack(spacing: 18) {
            ClockStatusLine(showsLockState: true)
            Spacer()
            Group {
                if let cue = shell.activeCue {
                    Text(cue.number).font(Theme.numeric(13, weight: .semibold))
                    Text(cue.title).lineLimit(1)
                    Text(Fmt.remaining(shell.remaining)).font(Theme.numeric(13, weight: .regular))
                } else if let s = shell.standbyCue {
                    Text("Standby").foregroundStyle(Theme.standby)
                    Text(s.number).font(Theme.numeric(13, weight: .semibold))
                    Text(s.title).lineLimit(1)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
        }
    }
}
