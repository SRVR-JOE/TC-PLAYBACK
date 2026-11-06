import SwiftUI

// Owned by the APP SHELL agent.
struct RootView: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            TimecodeClockView()
        }
        .preferredColorScheme(.dark)
    }
}
