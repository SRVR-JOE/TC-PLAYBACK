import SwiftUI
import UniformTypeIdentifiers

/// One thing that can be saved to the USB drive.
struct ExportDriveItem: Identifiable {
    let id: String
    let title: String
    var detail: String = ""
    /// Builds the files to copy (called on tap).
    let files: () throws -> [URL]
}

extension ExportDrive {
    /// Shows the Files folder picker (handled by `.exportDriveSupport()`).
    func requestPicker() { pickerRequested = true }

    /// Copies an item's files and reports the result in the feedback strip.
    func save(_ item: ExportDriveItem) {
        do {
            let names = try save(try item.files())
            feedback = .init(ok: true, text: names.count == 1
                             ? "Saved \(names[0]) to \(name)"
                             : "Saved \(names.count) files to \(name)")
        } catch {
            feedback = .init(ok: false, text: error.localizedDescription)
        }
    }
}

/// Menu section: "Save to KINGSTON" with the items, plus choose or change drive.
struct ExportDriveMenuSection: View {
    var groups: [(title: String, items: [ExportDriveItem])]
    @Bindable private var drive = ExportDrive.shared

    var body: some View {
        Section("USB drive") {
            switch drive.state {
            case .ready(let name):
                Menu {
                    ForEach(groups, id: \.title) { g in
                        Section(g.title) {
                            ForEach(g.items) { item in
                                Button { drive.save(item) } label: {
                                    if item.detail.isEmpty { Text(item.title) } else { Text(item.title); Text(item.detail) }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Save to \(name)", systemImage: "externaldrive")
                }
                Button { drive.requestPicker() } label: { Label("Change drive…", systemImage: "externaldrive.badge.plus") }
            case .missing(let name):
                Button { drive.refresh() } label: {
                    Label { Text("\(name) isn’t plugged in"); Text("Plug it in and open this menu again") } icon: {
                        Image(systemName: "externaldrive.badge.xmark")
                    }
                }
                Button { drive.requestPicker() } label: { Label("Choose another drive…", systemImage: "externaldrive.badge.plus") }
            case .notChosen:
                Button { drive.requestPicker() } label: {
                    Label { Text("Choose USB drive…"); Text("Pick it once, then save to it in one tap") } icon: {
                        Image(systemName: "externaldrive.badge.plus")
                    }
                }
            }
        }
    }
}

/// Attach once per screen that offers USB export: the folder picker and the save feedback strip.
struct ExportDriveSupport: ViewModifier {
    @Bindable private var drive = ExportDrive.shared

    func body(content: Content) -> some View {
        content
            .background(
                Color.clear
                    .fileImporter(isPresented: $drive.pickerRequested, allowedContentTypes: [.folder]) { result in
                        switch result {
                        case .success(let url):
                            do {
                                try drive.choose(url)
                                drive.feedback = .init(ok: true, text: "Exports will save to \(drive.name)")
                            } catch {
                                drive.feedback = .init(ok: false, text: "Couldn’t use that folder: \(error.localizedDescription)")
                            }
                        case .failure(let error):
                            drive.feedback = .init(ok: false, text: error.localizedDescription)
                        }
                    }
            )
            .overlay(alignment: .top) {
                if let f = drive.feedback {
                    HStack(spacing: 8) {
                        Image(systemName: f.ok ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(f.ok ? Theme.go : Theme.standby)
                        Text(f.text).font(Theme.label).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
                    .padding(.top, 8)
                    .transition(.opacity)
                    .task(id: f.id) {
                        try? await Task.sleep(for: .seconds(3.5))
                        if drive.feedback?.id == f.id { withAnimation { drive.feedback = nil } }
                    }
                    .onTapGesture { drive.feedback = nil }
                }
            }
            .animation(.easeOut(duration: 0.2), value: drive.feedback?.id)
    }
}

extension View {
    func exportDriveSupport() -> some View { modifier(ExportDriveSupport()) }
}
