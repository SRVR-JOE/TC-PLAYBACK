import SwiftUI
import TCKit

/// TC Pads: a bank of timecode presets fired like hot cues.
struct TCPadsView: View {
    @State private var controller = PadController()
    @State private var editing = false
    @State private var sheet: SheetItem?
    @State private var pendingFire: TCPad?
    @State private var showFillDialog = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmDeleteBank = false
    @AppStorage("padsPhoneColumns") private var phoneColumns = 3
    @Environment(\.horizontalSizeClass) private var hSize

    struct SheetItem: Identifiable {
        let pad: TCPad
        let isNew: Bool
        var id: UUID { pad.id }
    }

    private var isPad: Bool { hSize == .regular }

    var body: some View {
        VStack(spacing: 0) {
            PadsClockPanel(controller: controller, compact: !isPad)
                .padding(.horizontal, Theme.pad)
                .padding(.top, Theme.pad)
            bankBar
                .padding(.horizontal, Theme.pad)
                .padding(.vertical, 10)
            Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
            grid
        }
        .background(Theme.background.ignoresSafeArea())
        .background { hardwareKeys }
        .sensoryFeedback(.impact(weight: .medium), trigger: controller.fireCount)
        .onAppear(perform: debugLaunchHook)
        .sheet(item: $sheet) { item in
            PadEditSheet(pad: item.pad, bank: controller.bank, isNew: item.isNew,
                         onSave: { controller.upsert($0) },
                         onDelete: { controller.delete(item.pad.id) },
                         onDuplicate: { controller.duplicate(item.pad.id) })
        }
        .alert("A cue is playing. Stop it and fire this pad?", isPresented: Binding(
            get: { pendingFire != nil }, set: { if !$0 { pendingFire = nil } })) {
            Button("Stop and fire", role: .destructive) {
                if let p = pendingFire { controller.engine.stop(); controller.fire(p) }
                pendingFire = nil
            }
            Button("Cancel", role: .cancel) { pendingFire = nil }
        }
        .confirmationDialog("Hours 1–10", isPresented: $showFillDialog, titleVisibility: .visible) {
            Button("Replace pads in bank \(controller.bank.name)", role: .destructive) { controller.quickFillHours(.replace) }
            Button("Add to bank \(controller.bank.name)") { controller.quickFillHours(.append) }
        } message: {
            Text("Creates ten pads, 01:00:00:00 to 10:00:00:00.")
        }
        .alert("Rename bank", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let n = renameText.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { controller.updateBank { $0.name = String(n.prefix(12)) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete bank \(controller.bank.name)?", isPresented: $confirmDeleteBank) {
            Button("Delete", role: .destructive) { controller.deleteCurrentBank() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its \(controller.bank.pads.count) pads will be removed.")
        }
        .alert("Timecode", isPresented: Binding(get: { controller.errorMessage != nil },
                                                set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(controller.errorMessage ?? "") }
    }

    // MARK: Bank bar

    private var bankBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(controller.library.banks) { b in
                        let selected = b.id == controller.bank.id
                        Button { controller.selectBank(b.id) } label: {
                            Text(b.name)
                                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                                .frame(minWidth: 38, minHeight: 32)
                                .padding(.horizontal, 4)
                                .background(selected ? Theme.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: Theme.corner))
                                .overlay(RoundedRectangle(cornerRadius: Theme.corner)
                                    .strokeBorder(selected ? Theme.hairline : .clear, lineWidth: 1))
                        }
                        .buttonStyle(KeyPressStyle())
                        .accessibilityLabel("Bank \(b.name)")
                    }
                    if controller.library.banks.count < PadLibrary.maxBanks {
                        Button { controller.addBank() } label: {
                            Image(systemName: "plus").font(.system(size: 14, weight: .light))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 34, height: 32)
                        }
                        .buttonStyle(KeyPressStyle())
                        .accessibilityLabel("Add bank")
                    }
                }
            }
            Spacer(minLength: 4)
            rateMenu
            if isPad { preRollMenu }
            moreMenu
            Button(editing ? "Done" : "Edit") {
                withAnimation(.easeOut(duration: 0.15)) { editing.toggle() }
            }
            .font(.system(size: 15, weight: editing ? .semibold : .regular))
            .foregroundStyle(Theme.accent)
            .padding(.leading, 4)
        }
    }

    private var rateMenu: some View {
        Menu {
            Picker("Bank frame rate", selection: Binding(get: { controller.bank.rate },
                                                         set: { r in controller.updateBank { $0.rate = r } })) {
                ForEach(FrameRate.allCases) { Text(PadsFormat.rate($0)).tag($0) }
            }
        } label: {
            barLabel(PadsFormat.rate(controller.bank.rate), mono: true)
        }
    }

    private var preRollMenu: some View {
        Menu {
            Picker("Pre-roll", selection: Binding(get: { controller.bank.preRollSeconds },
                                                  set: { s in controller.updateBank { $0.preRollSeconds = s } })) {
                ForEach(PadsPreRoll.options, id: \.self) { s in Text(s == 0 ? "Off" : "\(Int(s)) s").tag(s) }
            }
        } label: {
            let s = controller.bank.preRollSeconds
            barLabel(s == 0 ? "Pre-roll off" : "Pre-roll \(Int(s)) s", mono: false)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { showFillDialog = true } label: { Label("Hours 1–10", systemImage: "list.number") }
            Button {
                sheet = SheetItem(pad: controller.newPad(), isNew: true)
            } label: { Label("New pad", systemImage: "plus.square") }
            if !isPad {
                Picker("Pre-roll", selection: Binding(get: { controller.bank.preRollSeconds },
                                                      set: { s in controller.updateBank { $0.preRollSeconds = s } })) {
                    ForEach(PadsPreRoll.options, id: \.self) { s in Text(s == 0 ? "Pre-roll off" : "Pre-roll \(Int(s)) s").tag(s) }
                }
                Picker("Columns", selection: $phoneColumns) {
                    Text("2 columns").tag(2)
                    Text("3 columns").tag(3)
                }
            }
            Divider()
            Button { renameText = controller.bank.name; renaming = true } label: { Label("Rename bank", systemImage: "pencil") }
            if controller.library.banks.count > 1 {
                Button(role: .destructive) { confirmDeleteBank = true } label: { Label("Delete bank", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 34, height: 32)
        }
        .accessibilityLabel("Bank options")
    }

    private func barLabel(_ text: String, mono: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text).font(mono ? Theme.numeric(13) : Theme.label)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .regular))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    // MARK: Grid

    private var grid: some View {
        GeometryReader { geo in
            let cols = isPad ? 4 : max(2, min(3, phoneColumns))
            let spacing: CGFloat = isPad ? 10 : 8
            let rows: CGFloat = isPad ? 4 : 4
            let fitHeight = (geo.size.height - Theme.pad * 2 - spacing * (rows - 1)) / rows
            let height = isPad ? max(96, fitHeight) : max(92, min(118, fitHeight))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: cols), spacing: spacing) {
                    ForEach(Array(controller.bank.pads.enumerated()), id: \.element.id) { idx, pad in
                        padCell(pad, index: idx, height: height)
                    }
                    if editing || controller.bank.pads.isEmpty {
                        addTile(height: height)
                    }
                }
                .padding(Theme.pad)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder
    private func padCell(_ pad: TCPad, index: Int, height: CGFloat) -> some View {
        let active = controller.activePadID == pad.id && controller.isOurs
        let tile = PadTile(pad: pad, bank: controller.bank, index: index, isActive: active,
                           isPaused: active && controller.isPaused, editing: editing, controller: controller,
                           large: height > 150)
            .frame(height: height)
        if editing {
            tile
                .onTapGesture { sheet = SheetItem(pad: pad, isNew: false) }
                .draggable(pad.id.uuidString) {
                    PadTile(pad: pad, bank: controller.bank, index: index, isActive: false, isPaused: false,
                            editing: true, controller: controller)
                        .frame(width: 160, height: height)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let s = items.first, let id = UUID(uuidString: s) else { return false }
                    withAnimation(.easeOut(duration: 0.15)) { controller.move(id, onto: pad.id) }
                    return true
                }
                .contextMenu { padMenu(pad) }
        } else {
            Button { fire(pad) } label: { tile }
                .buttonStyle(PadPressStyle())
                .contextMenu {
                    Button { sheet = SheetItem(pad: pad, isNew: false) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                    padMenu(pad)
                }
                .accessibilityLabel("\(pad.label), \(pad.startTimecode(in: controller.bank).description)")
                .accessibilityHint("Starts timecode")
        }
    }

    @ViewBuilder
    private func padMenu(_ pad: TCPad) -> some View {
        Button { controller.duplicate(pad.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button(role: .destructive) { controller.delete(pad.id) } label: { Label("Delete", systemImage: "trash") }
    }

    private func addTile(height: CGFloat) -> some View {
        Button { sheet = SheetItem(pad: controller.newPad(), isNew: true) } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 22, weight: .light))
                Text("Add pad").font(Theme.label)
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge)
                .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .buttonStyle(KeyPressStyle())
    }

    private func fire(_ pad: TCPad) {
        if controller.showCueIsPlaying { pendingFire = pad } else { controller.fire(pad) }
    }

    /// DEBUG only: `-padsFire N` fires pad N on launch, `-padsEdit` opens edit mode (screenshots).
    private func debugLaunchHook() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-padsFire"), i + 1 < args.count, let n = Int(args[i + 1]),
           n >= 1, n <= controller.bank.pads.count {
            controller.fire(controller.bank.pads[n - 1])
        }
        if args.contains("-padsEdit") { editing = true }
        if args.contains("-padsSheet"), let p = controller.bank.pads.first { sheet = SheetItem(pad: p, isNew: false) }
        #endif
    }

    // MARK: Hardware keys 1–9, Esc

    private var hardwareKeys: some View {
        ZStack {
            ForEach(0..<9, id: \.self) { i in
                Button("") {
                    let pads = controller.bank.pads
                    if i < pads.count { fire(pads[i]) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
            }
            Button("") { controller.stop() }.keyboardShortcut(.escape, modifiers: [])
        }
        .disabled(sheet != nil || editing)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// Pad press: slight darken while held, no bounce.
struct PadPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.06 : 0)
    }
}

/// One pad.
struct PadTile: View {
    let pad: TCPad
    let bank: PadBank
    let index: Int
    let isActive: Bool
    let isPaused: Bool
    let editing: Bool
    let controller: PadController
    var large = false

    var body: some View {
        let rate = pad.rate(in: bank)
        let preRoll = pad.preRoll(in: bank)
        HStack(spacing: 0) {
            Rectangle().fill(pad.color == .none ? Color.clear : pad.color.color).frame(width: 4)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(pad.label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if editing {
                        Image(systemName: "line.3.horizontal").font(.system(size: 13, weight: .light))
                            .foregroundStyle(Theme.textTertiary)
                    } else if index < 9 {
                        Text("\(index + 1)").font(Theme.numeric(11)).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 2)
                readout
                Spacer(minLength: 2)
                HStack(spacing: 6) {
                    Text(PadsFormat.rate(rate)).font(Theme.numeric(11))
                    Text(sideLabel).font(Theme.caption)
                    if preRoll > 0 { Text("−\(Int(preRoll)) s").font(Theme.numeric(11)) }
                    if let d = pad.duration { Text(PadsFormat.duration(d)).font(Theme.numeric(11)) }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(pad.rateOverride != nil ? Theme.textSecondary : Theme.textTertiary)
                .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isActive ? Theme.surfaceRaised : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerLarge)
                .strokeBorder(isActive ? (isPaused ? Theme.standby : Theme.go) : Theme.hairline,
                              lineWidth: isActive ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
    }

    @ViewBuilder
    private var readout: some View {
        if isActive {
            TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                tcText(controller.liveTimecode ?? pad.startTimecode(in: bank), color: Theme.textPrimary)
            }
        } else {
            tcText(pad.startTimecode(in: bank), color: Theme.textSecondary)
        }
    }

    private func tcText(_ tc: Timecode, color: Color) -> some View {
        Text(tc.description)
            .font(Theme.numeric(large ? 32 : 22, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private var sideLabel: String {
        switch pad.side { case .left: "Left"; case .right: "Right"; case .both: "Both" }
    }
}

enum PadsFormat {
    /// "30 fps", "29.97 DF".
    static func rate(_ r: FrameRate) -> String { r.label.contains(" ") ? r.label : r.label + " fps" }

    static func duration(_ d: TimeInterval) -> String {
        let s = Int(d.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
