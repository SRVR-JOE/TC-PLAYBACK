import SwiftUI

// Navigation slots for screens built by another agent. TODO(merge): the lead replaces each
// body with `TCPadsView()` / `OutputTestView()`. Keep each body a single line.

struct PadsSlot: View {
    var body: some View { Text("Pads") }
}

struct OutputTestSlot: View {
    var body: some View { Text("Output test") }
}

/// Hosts a slot as a sheet destination with a title and Done.
struct ToolSheet<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
