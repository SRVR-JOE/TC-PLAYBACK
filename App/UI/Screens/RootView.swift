import SwiftUI
import SwiftData

// Owned by the APP SHELL agent.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.dark.rawValue
    @AppStorage(SettingsKey.keepAwake) private var keepAwake = true
    @AppStorage(SettingsKey.autoDetectTimecode) private var autoDetect = true
    @AppStorage(SettingsKey.readExternalInput) private var readInput = false
    @AppStorage(SettingsKey.theme) private var theme = AppTheme.graphite.rawValue
    @AppStorage(SettingsKey.showLock) private var showLock = false
    @State private var bootstrapped = false

    private var scheme: ColorScheme? {
        if theme == AppTheme.light.rawValue { return .light }
        return appearance == AppearanceMode.system.rawValue ? nil : .dark
    }

    var body: some View {
        rootContent
        .id(theme)
        .tint(Theme.textPrimary)
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .top) { BannerView().padding(.top, 6) }
        .background(KeyCommands())
        .preferredColorScheme(scheme)
        .fileImporter(isPresented: $shell.showImporter, allowedContentTypes: TrackImporter.contentTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): shell.importAudio(urls, context: context)
            case .failure(let error): shell.banner = ShellBanner(kind: .error, text: "Import failed: \(error.localizedDescription)")
            }
        }
        .sheet(isPresented: $shell.showSettings) { SettingsView().preferredColorScheme(scheme) }
        .sheet(isPresented: $shell.showPlaylists) { PlaylistsView().preferredColorScheme(scheme) }
        .sheet(isPresented: $shell.showChecklist) { PreShowChecklist().preferredColorScheme(scheme) }
        .fullScreenCover(isPresented: $shell.showPads) { ToolSheet(title: "Pads") { PadsSlot() }.preferredColorScheme(scheme) }
        .fullScreenCover(isPresented: $shell.showOutputTest) { ToolSheet(title: "Output test") { OutputTestSlot() }.preferredColorScheme(scheme) }
        .fullScreenCover(isPresented: $shell.showCuePoints) { ToolSheet(title: "Cue points") { CuePointsView() }.preferredColorScheme(scheme) }
        .fullScreenCover(isPresented: $shell.showInputAnalyzer) { ToolSheet(title: "Input analyzer") { InputAnalyzerView() }.preferredColorScheme(scheme) }
        .fullScreenCover(isPresented: $shell.showScope) { ToolSheet(title: "Scope") { ScopePage() }.preferredColorScheme(scheme) }
        .fullScreenCover(isPresented: $shell.showFullClock) { FullScreenClock() }
        .fullScreenCover(isPresented: $shell.showShowMode) { PhoneShowMode().preferredColorScheme(.dark) }
        .onChange(of: theme, initial: true) { _, t in AppTheme.active = AppTheme(rawValue: t) ?? .graphite }
        .onOpenURL { shell.handleOpenURL($0, context: context) }
        .onChange(of: shell.engine.transport) { _, _ in updateIdleTimer() }
        .onChange(of: keepAwake) { _, _ in updateIdleTimer() }
        .onChange(of: showLock) { _, v in shell.engine.remoteTransportLocked = v }
        .onChange(of: shell.engine.lastError) { _, err in
            if let err { shell.banner = ShellBanner(kind: .error, text: err) }
        }
        .task { bootstrap() }
    }

    @ViewBuilder private var rootContent: some View {
        let content = Group {
            if UIDevice.current.userInterfaceIdiom == .pad { PadRoot() } else { PhoneRoot() }
        }
        #if DEBUG
        DemoRotator { content }
        #else
        content
        #endif
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && shell.engine.transport == .playing
    }

    private func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        shell.engine.autoDetectTimecode = autoDetect
        shell.engine.readExternalInput = readInput
        #if DEBUG
        if UIDemo.isOn { UIDemo.seed(context: context); return }
        #endif
        DemoContent.seedIfNeeded(context: context)
        ShowController.shared.restore(context: context)
        if let p = ShowController.shared.playlist { shell.open(p) }
        if shell.playlist == nil { openLastPlaylist() }
        shell.engine.onRemoteNext = { ShowController.shared.next() }
        shell.engine.onRemotePrevious = { ShowController.shared.previous() }
        shell.engine.remoteTransportLocked = showLock
        #if DEBUG
        // -inputAnalyzer: open the Input analyzer on launch (QA only; listens, never plays).
        if ProcessInfo.processInfo.arguments.contains("-inputAnalyzer") { shell.showInputAnalyzer = true }
        // -scope: open the Scope page on launch (QA only; listens, never plays).
        if ProcessInfo.processInfo.arguments.contains("-scope") { shell.showScope = true }
        if ProcessInfo.processInfo.arguments.contains("-cuePoints") { shell.showCuePoints = true }
        // -importShow <path>: open a show/audio file from disk as if it came from Files (QA only).
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-importShow"), i + 1 < ProcessInfo.processInfo.arguments.count {
            shell.handleOpenURL(URL(fileURLWithPath: ProcessInfo.processInfo.arguments[i + 1]), context: context)
        }
        // -autoGo: fire the standby cue after the demo tracks are ready (screenshots/QA only).
        if ProcessInfo.processInfo.arguments.contains("-autoGo") {
            Task { @MainActor in
                for _ in 0..<40 where !(shell.standbyCue?.track.map { FileManager.default.fileExists(atPath: $0.fileURL.path) } ?? false) {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                try? await Task.sleep(for: .seconds(1))
                shell.go()
            }
        }
        #endif
    }

    private func openLastPlaylist() {
        let all = (try? context.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        let saved = UserDefaults.standard.string(forKey: SettingsKey.currentPlaylistID)
        if let p = all.first(where: { $0.id.uuidString == saved }) ?? all.first {
            shell.open(p)
        } else {
            let p = PlaylistEditor.createPlaylist(named: "Show", context: context)
            shell.ensureInserted(p, context: context)
            shell.open(p)
        }
    }
}

// MARK: - iPad

private struct PadRoot: View {
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.layoutMode) private var layoutRaw = LayoutMode.console.rawValue
    @AppStorage(SettingsKey.showLock) private var showLock = false
    @State private var columns: NavigationSplitViewVisibility = .all

    private var layout: LayoutMode { LayoutMode(rawValue: layoutRaw) ?? .console }

    var body: some View {
        GeometryReader { geo in
            content
                .onChange(of: geo.size.width > geo.size.height, initial: true) { _, landscape in
                    // Portrait: the sidebar would overlay the detail, so start detail-only
                    // (sidebar button still reveals it). Landscape: both columns side by side.
                    columns = landscape ? .all : .detailOnly
                }
        }
    }

    @ViewBuilder private var content: some View {
        if layout.showsSidebar {
            NavigationSplitView(columnVisibility: $columns) {
                CueListView()
                    .navigationTitle(shell.playlist?.name ?? "Cues")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarTitleMenu { PlaylistMenuItems() }
                    .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
                    .toolbarBackground(Theme.surface, for: .navigationBar)
            } detail: {
                detail
                    .inspector(isPresented: $shell.showInspector) { inspectorContent }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            // Clock, Mixer and Show carry their own cue display: no sidebar.
            NavigationStack {
                detail
                    .navigationTitle(shell.playlist?.name ?? "")
                    .toolbarTitleMenu { PlaylistMenuItems() }
            }
            .sheet(isPresented: $shell.showInspector) {
                if let cue = shell.inspectorCue { CueInspector(cue: cue).presentationDetents([.large]) }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch layout {
        case .show:
            ShowModeView(onExit: { layoutRaw = LayoutMode.console.rawValue })
                .toolbar(.hidden, for: .navigationBar)
                .statusBarHidden()
                .environment(\.colorScheme, .dark)
        default:
            ShowScreen(layout: layout == .clock ? .clock : (layout == .mixer ? .mixer : .console))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { LayoutSwitcher(layoutRaw: $layoutRaw) }
                    ShowToolbar()
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.background, for: .navigationBar)
        }
    }

    @ViewBuilder private var inspectorContent: some View {
        Group {
            if let cue = shell.inspectorCue { CueInspector(cue: cue) } else { Color.clear }
        }
        .inspectorColumnWidth(min: 320, ideal: 360, max: 440)
    }
}

/// Toolbar view switcher: Console · Clock · Mixer · Show.
struct LayoutSwitcher: View {
    @Binding var layoutRaw: String
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false
    private var layout: LayoutMode { LayoutMode(rawValue: layoutRaw) ?? .console }
    var body: some View {
        Menu {
            Picker("Layout", selection: Binding(get: { layout }, set: { select($0) })) {
                ForEach(LayoutMode.allCases) { m in
                    Label(m.label, systemImage: m.symbol).tag(m)
                }
            }
            Divider()
            Button { shell.showPads = true } label: { Label("Pads", systemImage: "square.grid.3x3") }
            Button { shell.showOutputTest = true } label: { Label("Output test", systemImage: "speaker.wave.2") }
            Button { shell.showCuePoints = true } label: { Label("Cue points", systemImage: "flag") }
            Button { shell.showScope = true } label: { Label("Scope", systemImage: "waveform.path.ecg") }
        } label: {
            Label(layout.label, systemImage: layout.symbol)
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.medium))
        }
        .accessibilityLabel("Layout, \(layout.label)")
    }
    private func select(_ m: LayoutMode) {
        withAnimation(.easeOut(duration: 0.2)) { layoutRaw = m.rawValue }
    }
}

/// iPhone Show mode: Layout D in portrait, the landscape clock view in landscape.
private struct PhoneShowMode: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var vSize
    var body: some View {
        Group {
            if vSize == .compact {
                ShowScreen(layout: .phoneLandscape)
                    .background(Color.black)
                    .overlay(alignment: .topTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textTertiary).frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Leave Show mode")
                    }
            } else {
                ShowModeView(onExit: { dismiss() })
            }
        }
        .statusBarHidden()
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - iPhone

private struct PhoneRoot: View {
    @Bindable private var shell = ShellModel.shared
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        if vSize == .compact {
            ShowScreen(layout: .phoneLandscape)
                .ignoresSafeArea(.container, edges: .bottom)
                .statusBarHidden()
        } else {
            NavigationStack {
                VStack(spacing: 0) {
                    pageStrip
                    Group {
                        switch shell.phonePage {
                        case .show: ShowScreen(layout: .phonePortrait)
                        case .cues:
                            CueListView()
                                .safeAreaInset(edge: .bottom, spacing: 0) {
                                    TransportBar(layout: .compact)
                                        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
                                        .background(Theme.surface)
                                        .hairline(.top)
                                }
                        case .pads: PadsSlot().frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .more: PhoneMoreList()
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .background(Theme.background)
                .navigationTitle(shell.playlist?.name ?? "TC Playback")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarTitleMenu { PlaylistMenuItems() }
                .toolbar { ShowToolbar(compact: true) }
                .toolbarBackground(Theme.background, for: .navigationBar)
            }
            .inspector(isPresented: $shell.showInspector) {
                if let cue = shell.inspectorCue { CueInspector(cue: cue) }
            }
        }
    }

    private var pageStrip: some View {
        HStack(spacing: 0) {
            ForEach(ShellModel.PhonePage.allCases) { page in
                let on = shell.phonePage == page
                Button { shell.phonePage = page; Haptics.tick() } label: {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Text(page.label)
                            .font(.system(.subheadline, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                        Spacer(minLength: 0)
                        Rectangle().fill(on ? Theme.textPrimary : .clear).frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 36)
        .hairline(.bottom)
    }
}

/// iPhone "More" page: Playlists, Output test, Settings and show tools.
private struct PhoneMoreList: View {
    @Bindable private var shell = ShellModel.shared
    @State private var outputTest = false
    @State private var scope = false
    @State private var cuePoints = false
    var body: some View {
        List {
            Section {
                row("Playlists", "list.bullet") { shell.showPlaylists = true }
                row("Output test", "speaker.wave.2") { outputTest = true }
                row("Cue points", "flag") { cuePoints = true }
                row("Scope", "waveform.path.ecg") { scope = true }
                row("Settings", "gearshape") { shell.showSettings = true }
            }
            Section {
                row("Show mode", "play.rectangle") { shell.showShowMode = true }
                row("Pre-show check", "checklist") { shell.showChecklist = true }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationDestination(isPresented: $outputTest) {
            OutputTestSlot()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .navigationTitle("Output test")
        }
        .navigationDestination(isPresented: $cuePoints) {
            CuePointsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .navigationBarTitleDisplayMode(.inline)
        }
        .navigationDestination(isPresented: $scope) {
            ScopePage()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .navigationTitle("Scope")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
    private func row(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.textSecondary).frame(width: 22)
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface)
    }
}

// MARK: - Toolbar

/// Playlist switcher (title menu).
struct PlaylistMenuItems: View {
    @Query(sort: \Playlist.sortIndex) private var playlists: [Playlist]
    @Bindable private var shell = ShellModel.shared
    var body: some View {
        ForEach(playlists) { p in
            Button { shell.open(p) } label: {
                if p.id == shell.playlist?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
            }
        }
        Divider()
        Button { shell.showPlaylists = true } label: { Label("Manage playlists…", systemImage: "list.bullet") }
    }
}

struct ShowToolbar: ToolbarContent {
    var compact = false
    @Environment(\.modelContext) private var context
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false

    var body: some ToolbarContent {
        if compact {
            ToolbarItem(placement: .topBarLeading) {
                Button { shell.showShowMode = true } label: { Image(systemName: "play.rectangle") }
                    .accessibilityLabel("Show mode")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button { shell.showImporter = true } label: { Label("Import audio…", systemImage: "square.and.arrow.down") }
                Button { shell.addGeneratorCue(context: context) } label: { Label("Add generator cue", systemImage: "clock") }
            } label: { Image(systemName: "plus") }
            .disabled(showLock)
            .accessibilityLabel("Add")

            if !compact {
                Button { shell.showChecklist = true } label: { Image(systemName: "checklist") }
                    .accessibilityLabel("Pre-show check")
            }

            Button {
                showLock.toggle()
                Haptics.tick()
            } label: {
                if showLock {
                    Label("Locked", systemImage: "lock.fill").labelStyle(.titleAndIcon)
                        .foregroundStyle(Theme.standby)
                } else {
                    Image(systemName: "lock.open")
                }
            }
            .accessibilityLabel(showLock ? "Show Lock on" : "Show Lock off")

            if !compact {
                Button { shell.showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
    }
}

// MARK: - Banner

private struct BannerView: View {
    @Bindable private var shell = ShellModel.shared
    var body: some View {
        if let b = shell.banner {
            HStack(spacing: 10) {
                switch b.kind {
                case .progress: ProgressView().controlSize(.small)
                case .info: IndicatorLamp(color: Theme.go, isOn: true, size: 7)
                case .warning: IndicatorLamp(color: Theme.standby, isOn: true, size: 7)
                case .error: IndicatorLamp(color: Theme.stop, isOn: true, size: 7)
                }
                Text(b.text).font(Theme.label).foregroundStyle(Theme.textPrimary).lineLimit(2)
                if b.kind != .progress {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if b.kind == .error, shell.engine.lastError != nil { shell.engine.lastError = nil }
                            shell.banner = nil
                        }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(b.kind == .error ? Theme.stop.opacity(0.6) : Theme.hairline, lineWidth: 1))
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)
            .transition(.opacity)
        }
    }
}
