import PhotosUI
import SwiftUI

// MARK: - Framing diagram

/// A drawn 16:9 frame showing how much of a person a shot holds: a quiet figure on a sunken
/// background with faint thirds lines. Used when a shot has no photo.
struct ShotFramingDiagram: View {
    var framing: ShotFraming

    /// The world window a shot sees: centre x, top y and height in metres (a 1.8 m person, feet
    /// at 0). Width follows from 16:9.
    struct Window { var cx: CGFloat; var top: CGFloat; var height: CGFloat }

    static func window(_ f: ShotFraming) -> Window? {
        switch f {
        case .ecu: Window(cx: 0, top: 1.71, height: 0.15)
        case .cu: Window(cx: 0, top: 1.80, height: 0.42)
        case .mcu: Window(cx: 0, top: 1.84, height: 0.64)
        case .ms: Window(cx: 0, top: 1.88, height: 0.98)
        case .cowboy: Window(cx: 0, top: 1.94, height: 1.36)
        case .wide: Window(cx: 0, top: 2.18, height: 2.45)
        case .extremeWide: Window(cx: 0, top: 6.2, height: 9.4)
        case .twoShot: Window(cx: 0, top: 1.92, height: 1.05)
        case .group: Window(cx: 0, top: 1.98, height: 1.4)
        case .lowAngle: Window(cx: 0, top: 2.05, height: 1.75)
        case .highAngle: Window(cx: 0, top: 1.95, height: 1.75)
        case .ots, .crowd, .none: nil
        }
    }

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.surfaceSunken))
            switch framing {
            case .ots: drawOTS(ctx, size)
            case .crowd: drawCrowd(ctx, size, rows: 4)
            case .none:
                let r = CGRect(x: size.width / 2 - 14, y: size.height / 2 - 11, width: 28, height: 22)
                ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(Theme.textTertiary), lineWidth: 1.5)
            default:
                if let w = Self.window(framing) { drawWorld(ctx, size, w) }
            }
            // Thirds
            var g = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3, y = size.height * CGFloat(i) / 3
                g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: size.height))
                g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(g, with: .color(Theme.textTertiary.opacity(0.22)), lineWidth: 0.5)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .accessibilityLabel("\(framing.label) framing")
    }

    // A world point → view point. `k` leans the figure: > 0 looks up (low angle), < 0 looks down.
    private func projector(_ w: Window, _ size: CGSize, k: CGFloat) -> (CGFloat, CGFloat) -> CGPoint {
        let s = size.height / w.height
        let width = w.height * 16 / 9
        return { x, y in
            let lean = 1 + k * (1.0 - y)
            return CGPoint(x: ((x - w.cx) * lean + width / 2) * s, y: (w.top - y) * s)
        }
    }

    private func drawWorld(_ ctx: GraphicsContext, _ size: CGSize, _ w: Window) {
        let k: CGFloat = framing == .lowAngle ? 0.32 : framing == .highAngle ? -0.28 : 0
        let p = projector(w, size, k: k)
        let s = size.height / w.height
        let ink = Theme.textSecondary
        if framing == .extremeWide {
            // Truss, stage deck, crowd.
            ctx.fill(Path(CGRect(x: p(-7, 5.4).x, y: p(0, 5.4).y, width: p(7, 0).x - p(-7, 0).x, height: 0.14 * s)), with: .color(Theme.textTertiary.opacity(0.7)))
            let deck = CGRect(x: p(-6.5, 0).x, y: p(0, 0).y, width: p(6.5, 0).x - p(-6.5, 0).x, height: 1.2 * s)
            ctx.fill(Path(deck), with: .color(Theme.textTertiary.opacity(0.35)))
            for x in stride(from: -4.5, through: 4.5, by: 1.8) { figure(ctx, p, s, x: x, raised: false, ink: ink.opacity(x == 0 ? 1 : 0.55)) }
            drawCrowd(ctx, size, rows: 2, fromY: deck.maxY + 2)
            return
        }
        if framing == .highAngle {
            // Floor line behind, high in frame.
            var floor = Path(); floor.move(to: p(-4, 0.6)); floor.addLine(to: p(4, 0.6))
            ctx.stroke(floor, with: .color(Theme.textTertiary.opacity(0.5)), lineWidth: 1)
        }
        let xs: [CGFloat] = framing == .twoShot ? [-0.34, 0.34] : framing == .group ? [-0.62, 0, 0.62] : [0]
        for x in xs { figure(ctx, p, s, x: x, raised: framing == .cowboy, ink: ink) }
    }

    /// A simple standing person: head, torso, arms, legs.
    private func figure(_ ctx: GraphicsContext, _ p: (CGFloat, CGFloat) -> CGPoint, _ s: CGFloat, x: CGFloat, raised: Bool, ink: Color) {
        let headC = p(x, 1.62), headR = 0.115 * s
        ctx.fill(Path(ellipseIn: CGRect(x: headC.x - headR, y: headC.y - headR, width: headR * 2, height: headR * 2.1)), with: .color(ink))
        var torso = Path()
        torso.move(to: p(x - 0.05, 1.52)); torso.addLine(to: p(x + 0.05, 1.52))
        torso.addQuadCurve(to: p(x + 0.23, 1.40), control: p(x + 0.21, 1.48))
        torso.addLine(to: p(x + 0.17, 0.92)); torso.addLine(to: p(x - 0.17, 0.92))
        torso.addLine(to: p(x - 0.23, 1.40))
        torso.addQuadCurve(to: p(x - 0.05, 1.52), control: p(x - 0.21, 1.48))
        torso.closeSubpath()
        ctx.fill(torso, with: .color(ink))
        let limb = StrokeStyle(lineWidth: 0.085 * s, lineCap: .round)
        var arms = Path()
        if raised {
            arms.move(to: p(x - 0.2, 1.42)); arms.addLine(to: p(x - 0.36, 2.02))
            arms.move(to: p(x + 0.2, 1.42)); arms.addLine(to: p(x + 0.36, 2.02))
        } else {
            arms.move(to: p(x - 0.22, 1.40)); arms.addLine(to: p(x - 0.27, 0.92))
            arms.move(to: p(x + 0.22, 1.40)); arms.addLine(to: p(x + 0.20, 1.15)); arms.addLine(to: p(x + 0.05, 1.52))
        }
        ctx.stroke(arms, with: .color(ink), style: limb)
        var legs = Path()
        legs.move(to: p(x - 0.09, 0.95)); legs.addLine(to: p(x - 0.12, 0.04))
        legs.move(to: p(x + 0.09, 0.95)); legs.addLine(to: p(x + 0.12, 0.04))
        ctx.stroke(legs, with: .color(ink), style: StrokeStyle(lineWidth: 0.11 * s, lineCap: .round))
        // Mic in the hand at the mouth, and eyes for the tight shots.
        if !raised {
            let mic = p(x + 0.05, 1.53), r = 0.025 * s
            ctx.fill(Path(ellipseIn: CGRect(x: mic.x - r, y: mic.y - r, width: r * 2, height: r * 2)), with: .color(Theme.textPrimary))
        }
        if framing == .ecu || framing == .cu || framing == .mcu {
            for dx in [-0.042, 0.042] {
                let e = p(x + dx, 1.645), r = 0.013 * s
                ctx.fill(Path(ellipseIn: CGRect(x: e.x - r, y: e.y - r * 0.8, width: r * 2, height: r * 1.6)), with: .color(Theme.surfaceSunken))
            }
        }
    }

    private func drawCrowd(_ ctx: GraphicsContext, _ size: CGSize, rows: Int, fromY: CGFloat? = nil) {
        let top = fromY ?? size.height * 0.35
        let rowH = (size.height - top) / CGFloat(rows)
        for row in 0..<rows {
            let r = rowH * (0.28 + 0.06 * CGFloat(row))
            let y = top + rowH * (CGFloat(row) + 0.55)
            let step = r * 2.3
            let offset = row.isMultiple(of: 2) ? 0 : step / 2
            var x = -offset
            var i = 0
            while x < size.width + r {
                let shade = Theme.textTertiary.opacity(0.45 + 0.15 * Double(row))
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(shade))
                ctx.fill(Path(roundedRect: CGRect(x: x - r * 1.3, y: y + r * 0.8, width: r * 2.6, height: rowH), cornerRadius: r * 0.6), with: .color(shade))
                if (i + row) % 3 == 0 {
                    var arm = Path(); arm.move(to: CGPoint(x: x + r * 0.9, y: y + r)); arm.addLine(to: CGPoint(x: x + r * 1.5, y: y - r * 2.2))
                    ctx.stroke(arm, with: .color(shade), style: StrokeStyle(lineWidth: r * 0.45, lineCap: .round))
                }
                x += step; i += 1
            }
        }
    }

    private func drawOTS(_ ctx: GraphicsContext, _ size: CGSize) {
        // Stage light at the back, the crowd, and the artist's head and shoulder big in the left foreground.
        drawCrowd(ctx, size, rows: 3, fromY: size.height * 0.30)
        let h = size.height
        var body = Path()
        body.move(to: CGPoint(x: -h * 0.1, y: h))
        body.addLine(to: CGPoint(x: -h * 0.1, y: h * 0.62))
        body.addQuadCurve(to: CGPoint(x: h * 0.62, y: h * 0.70), control: CGPoint(x: h * 0.35, y: h * 0.52))
        body.addQuadCurve(to: CGPoint(x: h * 0.78, y: h), control: CGPoint(x: h * 0.76, y: h * 0.78))
        body.closeSubpath()
        ctx.fill(body, with: .color(Theme.textSecondary))
        ctx.fill(Path(ellipseIn: CGRect(x: h * 0.06, y: h * 0.18, width: h * 0.42, height: h * 0.50)), with: .color(Theme.textSecondary))
    }
}

// MARK: - Picture

/// A shot's picture: the operator's photo when there is one, otherwise the diagram.
struct ShotPicture: View {
    var shot: ShotReference
    var photo: UIImage? = nil

    var body: some View {
        let img = photo ?? ShotLibraryStore.shared.image(shot)
        Group {
            if let img {
                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(Image(uiImage: img).resizable().scaledToFill())
                    .clipped()
            } else {
                ShotFramingDiagram(framing: shot.framing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
    }
}

// MARK: - Page

/// The shot reference page: every shot's name, what it means, and a picture.
struct ShotLibraryPage: View {
    @State private var editing: ShotReference?
    @State private var isNew = false
    private var store: ShotLibraryStore { .shared }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                ForEach(store.shots) { shot in
                    Button { isNew = false; editing = shot } label: { ShotCard(shot: shot) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { isNew = false; editing = shot } label: { Label("Edit", systemImage: "pencil") }
                            Button { CueCameraPresetStore.shared.addShot(shot.name) } label: { Label("Add to shot keys", systemImage: "keyboard") }
                            Button(role: .destructive) { store.delete(shot) } label: { Label("Remove shot", systemImage: "trash") }
                        }
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .overlay {
            if store.shots.isEmpty {
                ContentUnavailableView {
                    Label("No shots", systemImage: "rectangle.dashed")
                } actions: {
                    Button("Restore the standard shots") { store.restoreDefaults() }.buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button { add() } label: { Label("Add shot", systemImage: "plus") }
                    Button { store.restoreDefaults() } label: { Label("Restore the standard shots", systemImage: "arrow.counterclockwise") }
                } label: { Label("Add shot", systemImage: "plus") } primaryAction: { add() }
            }
        }
        .sheet(item: $editing) { shot in ShotEditSheet(shot: shot, isNew: isNew) }
    }

    private func add() { isNew = true; editing = ShotReference(name: "", framing: .none) }
}

struct ShotCard: View {
    var shot: ShotReference
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShotPicture(shot: shot)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(shot.name.isEmpty ? "Untitled shot" : shot.name)
                    .font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if !shot.abbr.isEmpty {
                    Text(shot.abbr).font(Theme.numeric(15, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }
            }
            if !shot.description.isEmpty {
                Text(shot.description).font(.system(size: 15)).lineSpacing(2).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge).strokeBorder(Theme.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit shot")
    }
}

// MARK: - Edit

struct ShotEditSheet: View {
    @State var shot: ShotReference
    var isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pick: PhotosPickerItem?
    @State private var pendingPhoto: Data?
    @State private var pendingImage: UIImage?
    @State private var removePhoto = false
    @State private var error: String?
    @State private var addedKey = false
    private var store: ShotLibraryStore { .shared }

    private var hasPhoto: Bool { pendingImage != nil || (shot.imageFile != nil && !removePhoto) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Group {
                        if let pendingImage {
                            ShotPicture(shot: shot, photo: pendingImage)
                        } else if removePhoto {
                            ShotFramingDiagram(framing: shot.framing).clipShape(RoundedRectangle(cornerRadius: Theme.corner))
                        } else {
                            ShotPicture(shot: shot)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    PhotosPicker(selection: $pick, matching: .images) {
                        Label(hasPhoto ? "Replace photo…" : "Choose photo…", systemImage: "photo")
                    }
                    if hasPhoto {
                        Button(role: .destructive) { pendingPhoto = nil; pendingImage = nil; removePhoto = true } label: {
                            Label("Remove photo, use the diagram", systemImage: "xmark.circle")
                        }
                    }
                    Picker("Diagram", selection: $shot.framing) {
                        ForEach(ShotFraming.allCases) { Text($0.label).tag($0) }
                    }
                } header: { Text("Picture") } footer: {
                    Text(error ?? "A frame grab from this show is the best reference. Without one, the diagram shows the framing.")
                        .foregroundStyle(error == nil ? Theme.textTertiary : Theme.standby)
                }
                .listRowBackground(Theme.surface)
                Section {
                    LabeledContent("Name") { TextField("Medium close-up", text: $shot.name).multilineTextAlignment(.trailing) }
                    LabeledContent("Short name") {
                        TextField("MCU", text: $shot.abbr).multilineTextAlignment(.trailing).autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                    }
                    TextField("What the shot is and when to use it", text: $shot.description, axis: .vertical)
                        .lineLimit(3...10)
                } header: { Text("Shot") }
                .listRowBackground(Theme.surface)
                Section {
                    Button {
                        CueCameraPresetStore.shared.addShot(shot.name); addedKey = true
                    } label: {
                        Label(addedKey ? "Added to the shot keys" : "Add to shot keys", systemImage: addedKey ? "checkmark" : "keyboard")
                    }
                    .disabled(shot.name.trimmingCharacters(in: .whitespaces).isEmpty || addedKey)
                    if !isNew {
                        Button("Remove shot", role: .destructive) { store.delete(shot); dismiss() }
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(isNew ? "New shot" : (shot.name.isEmpty ? "Shot" : shot.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Done") { commit() }
                        .disabled(shot.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                Task {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                        pendingPhoto = d; pendingImage = img; removePhoto = false; error = nil
                    } else {
                        error = "Couldn’t read that photo."
                    }
                }
            }
        }
    }

    private func commit() {
        shot.name = shot.name.trimmingCharacters(in: .whitespaces)
        store.save(shot)
        do {
            if let pendingPhoto { try store.setPhoto(pendingPhoto, for: shot) }
            else if removePhoto { store.removePhoto(shot) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The shot reference as a sheet (from the Cameras page).
struct ShotLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ShotLibraryPage()
                .navigationTitle("Shots")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationSizing(.page)
    }
}

// MARK: - Direction picker

/// Ready-made direction lines and the keyword glossary. Tapping one adds it; the sheet stays
/// open so several can be added in a row.
struct CameraDirectionPicker: View {
    enum Mode: String, CaseIterable, Identifiable { case directions, keywords; var id: String { rawValue } }
    enum Insertion: Equatable { case line(String), keyword(String) }

    var subject: String = ""
    @State var mode: Mode = .directions
    /// Keywords only (the shot keys use it).
    var keywordsOnly = false
    var title = "Add directions"
    var onInsert: (Insertion) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var added: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                if !keywordsOnly {
                    Picker("Show", selection: $mode) {
                        Text("Directions").tag(Mode.directions)
                        Text("Keywords").tag(Mode.keywords)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if mode == .directions && !keywordsOnly { directions } else { keywords }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func matches(_ s: String...) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || s.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    @ViewBuilder private var directions: some View {
        ForEach(CameraDirection.Category.allCases) { c in
            let items = CameraDirections.directions(in: c).map { $0.text(subject: subject) }.filter { matches($0) }
            if !items.isEmpty {
                Section(c.label) {
                    ForEach(items, id: \.self) { line in
                        row(id: line, title: line, detail: nil) { onInsert(.line(line)) }
                    }
                }
                .listRowBackground(Theme.surface)
            }
        }
    }

    @ViewBuilder private var keywords: some View {
        ForEach(CameraTerm.Category.allCases) { c in
            let items = CameraDirections.terms(in: c).filter { matches($0.term, $0.abbr, $0.meaning) }
            if !items.isEmpty {
                Section(c.label) {
                    ForEach(items) { t in
                        row(id: t.term, title: t.display, detail: t.meaning) { onInsert(.keyword(t.term)) }
                    }
                }
                .listRowBackground(Theme.surface)
            }
        }
    }

    private func row(id: String, title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button {
            action(); added.insert(id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(Theme.textPrimary)
                    if let detail { Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary) }
                }
                Spacer(minLength: 8)
                Image(systemName: added.contains(id) ? "checkmark" : "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(added.contains(id) ? Theme.go : Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(added.contains(id) ? "Added" : "Adds it")
    }
}
