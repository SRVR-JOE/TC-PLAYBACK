import SwiftUI

/// The Cameras page: the show's camera brief. Cards on iPad, a list on iPhone; tap to edit,
/// Brief for a big-type read mode to hand to an operator, Share for a PDF.
struct CamerasPage: View {
    /// nil = the current show (or the default brief when no show is open).
    var playlistID: UUID? = nil
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var editing: BriefCamera?
    @State private var isNew = false
    @State private var reading: Int?
    @State private var showShots = false
    @State private var showShotLibrary = false
    @State private var pdfURL: URL?
    private var store: CameraBriefStore { .shared }

    private var id: UUID { playlistID ?? store.currentID }
    private var brief: CameraBrief { store.brief(id) }
    private var showName: String {
        if let p = ShowController.shared.playlist, p.id == id { return p.name }
        return id == CameraBriefStore.defaultID ? "" : "Show"
    }

    var body: some View {
        Group {
            if brief.cameras.isEmpty {
                ContentUnavailableView {
                    Label("No cameras yet", systemImage: "video")
                } description: {
                    Text("Write each camera’s mission: who it follows and how. The names are also the caller’s camera keys.")
                } actions: {
                    Button("Add camera") { add() }.buttonStyle(OutlineButtonStyle())
                }
            } else if hSize == .regular {
                grid
            } else {
                list
            }
        }
        .background(Theme.background)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Shots") { showShotLibrary = true }
                    .accessibilityHint("Shot reference: each shot's name, meaning and picture")
                Button("Brief") { reading = 0 }
                    .disabled(brief.cameras.isEmpty)
                    .accessibilityHint("Big type, one camera per screen, to show an operator")
                if let pdfURL {
                    Menu {
                        ShareLink(item: pdfURL) { Label("Share PDF…", systemImage: "square.and.arrow.up") }
                        ExportDriveMenuSection(groups: [(title: "Camera brief", items: [
                            ExportDriveItem(id: "brief", title: "Camera brief PDF", files: { [pdfURL] })
                        ])])
                    } label: { Label("Export PDF", systemImage: "square.and.arrow.up") }
                }
                Menu {
                    Button { add() } label: { Label("Add camera", systemImage: "plus") }
                    Button { showShots = true } label: { Label("Shot keys…", systemImage: "keyboard") }
                } label: { Label("Add camera", systemImage: "plus") }
                    primaryAction: { add() }
            }
        }
        .sheet(item: $editing) { cam in
            CameraEditSheet(camera: cam, isNew: isNew, takenNumbers: Set(brief.cameras.filter { $0.id != cam.id }.map(\.number)),
                            onSave: { save($0) }, onDelete: { delete($0) })
        }
        .sheet(isPresented: $showShots) { CueShotKeysSheet() }
        .sheet(isPresented: $showShotLibrary) { ShotLibrarySheet() }
        .fullScreenCover(item: Binding(get: { reading.map(ReadStart.init) }, set: { reading = $0?.index })) { start in
            CameraBriefReader(cameras: brief.cameras, showName: showName, start: start.index)
        }
        .task(id: brief) { pdfURL = try? CameraBriefPDF.makeURL(brief: brief, showName: showName) }
        .exportDriveSupport()
        .onAppear { ExportDrive.shared.refresh() }
        #if DEBUG
        .task {
            let a = ProcessInfo.processInfo.arguments
            guard let i = a.firstIndex(of: "-cameras"), i + 1 < a.count else { return }
            try? await Task.sleep(for: .milliseconds(700))
            switch a[i + 1] {
            case "brief": reading = 0
            case "edit": isNew = false; editing = brief.cameras.first
            case "shots": showShotLibrary = true
            case "directions": isNew = false; editing = brief.cameras.first
            default: break
            }
        }
        #endif
    }

    private struct ReadStart: Identifiable { let index: Int; var id: Int { index } }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                ForEach(Array(brief.cameras.enumerated()), id: \.element.id) { i, cam in
                    Button { isNew = false; editing = cam } label: { CameraCard(camera: cam) }
                        .buttonStyle(.plain)
                        .contextMenu { cardMenu(cam, at: i) }
                }
            }
            .padding(16)
        }
    }

    private var list: some View {
        List {
            ForEach(brief.cameras) { cam in
                Button { isNew = false; editing = cam } label: { CameraRow(camera: cam) }
                    .listRowBackground(Theme.surface)
            }
            .onMove { from, to in store.update(id) { $0.cameras.move(fromOffsets: from, toOffset: to) } }
            .onDelete { offsets in store.update(id) { $0.cameras.remove(atOffsets: offsets) } }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private func cardMenu(_ cam: BriefCamera, at i: Int) -> some View {
        Button { isNew = false; editing = cam } label: { Label("Edit", systemImage: "pencil") }
        Button { reading = i } label: { Label("Show brief", systemImage: "rectangle.portrait") }
        if i > 0 {
            Button { store.update(id) { $0.cameras.swapAt(i, i - 1) } } label: { Label("Move earlier", systemImage: "arrow.left") }
        }
        if i + 1 < brief.cameras.count {
            Button { store.update(id) { $0.cameras.swapAt(i, i + 1) } } label: { Label("Move later", systemImage: "arrow.right") }
        }
        Button(role: .destructive) { delete(cam) } label: { Label("Remove camera", systemImage: "trash") }
    }

    private func add() {
        isNew = true
        editing = BriefCamera(number: brief.nextNumber)
    }

    private func save(_ cam: BriefCamera) {
        store.update(id) { b in
            if let i = b.cameras.firstIndex(where: { $0.id == cam.id }) { b.cameras[i] = cam } else { b.cameras.append(cam) }
        }
    }

    private func delete(_ cam: BriefCamera) { store.update(id) { $0.cameras.removeAll { $0.id == cam.id } } }
}

// MARK: - Card and row

/// A camera card: number and name large, subject, the mission at a readable size, details quiet.
struct CameraCard: View {
    var camera: BriefCamera

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(camera.colorHex.flatMap { Color(hexString: $0) } ?? Theme.hairline)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(camera.number)").font(Theme.numeric(28, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Text(camera.callName).font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                if !camera.subject.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(camera.subject).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
                Text(missionText).font(.system(size: 20, weight: .regular)).lineSpacing(5)
                    .foregroundStyle(camera.mission.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !camera.detailLine.isEmpty {
                    Text(camera.detailLine).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(minHeight: 200, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge).strokeBorder(Theme.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit camera")
    }

    private var missionText: String {
        let m = camera.mission.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? "No mission yet" : m
    }
}

/// iPhone row.
struct CameraRow: View {
    var camera: BriefCamera
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(camera.colorHex.flatMap { Color(hexString: $0) } ?? Theme.hairline)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(camera.number)").font(Theme.numeric(17, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Text(camera.callName).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    if !camera.subject.isEmpty {
                        Text(camera.subject).font(Theme.label).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Text(camera.mission.isEmpty ? "No mission yet" : camera.mission)
                    .font(.system(size: 15)).lineSpacing(2)
                    .foregroundStyle(camera.mission.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(4)
                if !camera.detailLine.isEmpty {
                    Text(camera.detailLine).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Edit

struct CameraEditSheet: View {
    @State var camera: BriefCamera
    var isNew: Bool
    var takenNumbers: Set<Int>
    var onSave: (BriefCamera) -> Void
    var onDelete: (BriefCamera) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picking: CameraDirectionPicker.Mode?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $camera.number, in: 1...99) {
                        HStack {
                            Text("Number")
                            Spacer()
                            Text("\(camera.number)").font(Theme.numeric(15)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    field("Call name", BriefCamera.defaultName(camera.number), $camera.name)
                    field("Subject", "Who it follows", $camera.subject)
                } header: { Text("Camera") } footer: {
                    if takenNumbers.contains(camera.number) {
                        Text("Another camera already has number \(camera.number).").foregroundStyle(Theme.standby)
                    } else {
                        Text("The name is what the caller says, and what the camera key types into a call. Blank calls it \(BriefCamera.defaultName(camera.number)).")
                    }
                }
                .listRowBackground(Theme.surface)
                Section {
                    TextField("What this camera is for, who it follows, how tight", text: $camera.mission, axis: .vertical)
                        .lineLimit(4...12)
                        .font(.system(size: 17))
                    HStack(spacing: 20) {
                        Button { picking = .directions } label: { Label("Add directions…", systemImage: "text.badge.plus") }
                        Button { picking = .keywords } label: { Label("Keywords…", systemImage: "character.book.closed") }
                    }
                    .buttonStyle(.borderless)
                } header: { Text("Mission") } footer: {
                    Text("Ready-made directions fill in the subject. Keywords are the standard shot, angle and move names.")
                }
                .listRowBackground(Theme.surface)
                Section {
                    Picker("Type", selection: $camera.kind) {
                        ForEach(CameraKind.allCases) { Text($0.label).tag($0) }
                    }
                    field("Position", "FOH riser, Pit…", $camera.position)
                    field("Operator", "Optional", $camera.operatorName)
                    field("Lens", "Optional", $camera.lens)
                    HStack(spacing: 12) {
                        Text("Colour")
                        Spacer()
                        Button { camera.colorHex = nil } label: {
                            Circle().strokeBorder(Theme.textTertiary, lineWidth: 1).frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(camera.colorHex == nil ? Theme.textPrimary : .clear, lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain).accessibilityLabel("No colour")
                        ForEach(CuePointColor.allCases) { c in
                            Button { camera.colorHex = c.rawValue } label: {
                                Circle().fill(Color(hexString: c.rawValue) ?? .white).frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(camera.colorHex == c.rawValue ? Theme.textPrimary : .clear, lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c.label)
                        }
                    }
                } header: { Text("Details") }
                .listRowBackground(Theme.surface)
                if !isNew {
                    Section {
                        Button("Remove camera", role: .destructive) { onDelete(camera); dismiss() }
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .sheet(item: $picking) { mode in
                CameraDirectionPicker(subject: camera.subject, mode: mode) { ins in
                    switch ins {
                    case .line(let l): camera.mission = CameraDirections.append(l, to: camera.mission)
                    case .keyword(let k): camera.mission = CameraDirections.appendKeyword(k, to: camera.mission)
                    }
                }
            }
            #if DEBUG
            .task {
                guard ProcessInfo.processInfo.arguments.contains("directions") else { return }
                try? await Task.sleep(for: .milliseconds(600)); picking = .directions
            }
            #endif
            .navigationTitle(isNew ? "New camera" : camera.callName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(isNew ? "Add" : "Done") { onSave(camera); dismiss() } }
            }
        }
    }
}

extension CameraEditSheet {
    /// A labelled row: the label stays visible once the field has a value.
    func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(prompt, text: text).multilineTextAlignment(.trailing).autocorrectionDisabled()
        }
    }
}

// MARK: - Brief read mode

/// Big type, one camera per screen, swipe between them: hand the iPad to an operator.
struct CameraBriefReader: View {
    var cameras: [BriefCamera]
    var showName: String
    @State var start: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        let pad = hSize == .regular
        VStack(spacing: 0) {
            HStack {
                Button("Close") { dismiss() }.font(Theme.label)
                Spacer()
                Text(showName).font(Theme.label).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(start + 1) of \(cameras.count)").font(Theme.numeric(15, weight: .regular)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 20).frame(height: 52)
            TabView(selection: $start) {
                ForEach(Array(cameras.enumerated()), id: \.element.id) { i, cam in
                    page(cam, pad: pad).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func page(_ cam: BriefCamera, pad: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: pad ? 24 : 16) {
                HStack(alignment: .firstTextBaseline, spacing: pad ? 24 : 14) {
                    Text("\(cam.number)").font(Theme.numeric(pad ? 96 : 60, weight: .semibold))
                        .foregroundStyle(cam.colorHex.flatMap { Color(hexString: $0) } ?? Theme.textSecondary)
                    Text(cam.callName).font(.system(size: pad ? 64 : 40, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(2).minimumScaleFactor(0.6)
                }
                if !cam.subject.isEmpty {
                    Text(cam.subject).font(.system(size: pad ? 34 : 24, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text(cam.mission.isEmpty ? "No mission yet" : cam.mission)
                    .font(.system(size: pad ? 40 : 28, weight: .regular)).lineSpacing(pad ? 12 : 8)
                    .foregroundStyle(cam.mission.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !cam.detailLine.isEmpty {
                    Text(cam.detailLine).font(.system(size: pad ? 22 : 17)).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, pad ? 64 : 24).padding(.vertical, pad ? 40 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shot keys

/// Edit the shot keys under the camera keys (Push in, Wide…).
struct CueShotKeysSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var newShot = ""
    @State private var pickingKeywords = false
    private var store: CueCameraPresetStore { .shared }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New shot", text: $newShot).submitLabel(.done).onSubmit(addShot)
                        Button("Add", action: addShot).disabled(newShot.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .listRowBackground(Theme.surface)
                    ForEach(store.presets.shots, id: \.self) { Text($0).listRowBackground(Theme.surface) }
                        .onDelete { store.removeShots(at: $0) }
                        .onMove { store.moveShots(from: $0, to: $1) }
                } footer: {
                    Text("A shot is added to the current call: Camera 3, then Push in, makes “Camera 3, push in”.")
                }
                Section {
                    Button("Add from the keyword list…") { pickingKeywords = true }.listRowBackground(Theme.surface)
                    Button("Restore the original shots") { store.resetShots() }.listRowBackground(Theme.surface)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .sheet(isPresented: $pickingKeywords) {
                CameraDirectionPicker(mode: .keywords, keywordsOnly: true, title: "Add shot keys") { ins in
                    if case .keyword(let k) = ins { store.addShot(k) }
                }
            }
            .navigationTitle("Shot keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func addShot() { store.addShot(newShot); newShot = "" }
}

/// The Cameras page as a sheet (from the caller's keys).
struct CamerasSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            CamerasPage()
                .navigationTitle("Cameras")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationSizing(.page)
    }
}

extension View {
    /// DEBUG `-cameras phone`: lay the page out at iPhone width (compact) for a screenshot on the
    /// iPad simulator. No effect otherwise.
    @ViewBuilder func debugPhoneFrame() -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("phone"), ProcessInfo.processInfo.arguments.contains("-cameras") {
            NavigationStack {
                self.navigationTitle("Cameras").navigationBarTitleDisplayMode(.inline)
            }
            .environment(\.horizontalSizeClass, .compact)
            .frame(width: 393, height: 852)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.hairline, lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else { self }
        #else
        self
        #endif
    }
}
