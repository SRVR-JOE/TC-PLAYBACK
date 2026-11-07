import SwiftUI
import AVFoundation
import PhotosUI
import TCKit

/// AVPlayerLayer in SwiftUI, aspect fit on black.
struct CueVideoPlayerView: UIViewRepresentable {
    var player: AVPlayer?

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        v.isAccessibilityElement = true
        v.accessibilityLabel = "Video"
        return v
    }

    func updateUIView(_ v: PlayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

/// The video monitor on the Cue points screen. Shows nothing until a video is added (from the
/// Video menu); then a header with the file, its offset and Line up, and the picture, which
/// follows the track's playhead.
struct CueVideoPanel: View {
    enum Layout { case wide, strip }

    let track: Track
    var clock: CuePointClock
    var layout: Layout = .strip

    private var video: CueVideoController { CueVideoController.shared }
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        Group {
            if let p = video.importProgress {
                importBar(p)
            } else if video.trackID == track.id, let link = video.link {
                panel(link)
            }
        }
        .onAppear { video.panelAppeared(); video.attach(trackID: track.id) }
        .onDisappear { video.panelDisappeared() }
        .onChange(of: track.id) { _, id in video.attach(trackID: id) }
        .sheet(isPresented: Binding(get: { video.showingSync && video.trackID == track.id },
                                    set: { video.showingSync = $0 })) {
            CueVideoSyncSheet(track: track, clock: clock)
        }
    }

    private func panel(_ link: CueVideoLink) -> some View {
        VStack(spacing: 0) {
            header(link)
            if !video.collapsed {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                picture
                    .frame(maxWidth: .infinity)
                    .frame(height: layout == .strip ? 160 : nil)
                    .frame(maxHeight: layout == .wide ? .infinity : nil)
                if layout == .wide { resizeHandle }
            }
        }
        .frame(height: layout == .wide && !video.collapsed ? min(max(video.panelHeight, 140), 560) : nil)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge).strokeBorder(Theme.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
    }

    private func header(_ link: CueVideoLink) -> some View {
        HStack(spacing: 10) {
            Button { video.collapsed.toggle() } label: {
                Image(systemName: video.collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(video.collapsed ? "Show video" : "Hide video")
            Image(systemName: "film").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            Text(link.title).font(Theme.label).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 0) {
                Text("Offset").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                Text(CueVideoOffsetFormat.seconds(link.offset)).font(Theme.numeric(13)).foregroundStyle(Theme.textPrimary)
            }
            .accessibilityElement(children: .combine)
            Button { video.soundOn.toggle() } label: {
                Image(systemName: video.soundOn ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(video.soundOn ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(video.soundOn ? "Video sound on" : "Video sound off")
            Button { video.showingSync = true } label: {
                Text("Line up").font(Theme.label.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens auto sync, nudge and line-up tools")
        }
        .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 3)
    }

    private var picture: some View {
        ZStack {
            CueVideoPlayerView(player: video.player)
            if video.outOfRange {
                ZStack {
                    Theme.surfaceSunken
                    Text("No video at this time").font(Theme.label).foregroundStyle(Theme.textTertiary)
                }
            }
            if video.mode == .free {
                VStack {
                    Spacer()
                    HStack {
                        Text("Video moves on its own while you line up").font(Theme.caption)
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                        Spacer()
                    }
                    .padding(8)
                }
            }
        }
    }

    private var resizeHandle: some View {
        Rectangle().fill(Theme.surface)
            .frame(height: 10)
            .overlay(Capsule().fill(Theme.hairline).frame(width: 36, height: 3))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let base = dragStartHeight ?? video.panelHeight
                    if dragStartHeight == nil { dragStartHeight = base }
                    video.panelHeight = min(max(base + v.translation.height, 140), 560)
                }
                .onEnded { _ in dragStartHeight = nil })
            .accessibilityLabel("Resize video")
    }

    private func importBar(_ p: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "film").foregroundStyle(Theme.textSecondary)
            Text("Copying video").font(Theme.label).foregroundStyle(Theme.textPrimary)
            ProgressView(value: p).tint(Theme.textSecondary)
            Text("\(Int((p * 100).rounded())) %").font(Theme.numeric(12)).foregroundStyle(Theme.textSecondary)
                .frame(width: 44, alignment: .trailing)
            Button("Cancel") { video.cancelImport() }.font(Theme.label)
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Toolbar menu: add, replace or remove the track's video, sound and film-strip switches.
struct CueVideoMenu: View {
    let track: Track

    private var video: CueVideoController { CueVideoController.shared }
    @State private var pickPhoto = false
    @State private var pickFile = false
    @State private var photoItem: PhotosPickerItem?
    @State private var confirmRemove = false

    var body: some View {
        let has = video.trackID == track.id && video.link != nil
        Menu {
            if has {
                Button { video.showingSync = true } label: { Label("Line up video", systemImage: "arrow.left.and.right") }
                Toggle(isOn: Binding(get: { video.soundOn }, set: { video.soundOn = $0 })) {
                    Label("Video sound", systemImage: "speaker.wave.2")
                }
                Toggle(isOn: Binding(get: { video.showFilmstrip }, set: { video.showFilmstrip = $0 })) {
                    Label("Film strip on timeline", systemImage: "film.stack")
                }
                Section("Replace video") {
                    Button { pickPhoto = true } label: { Label("From Photos", systemImage: "photo.on.rectangle") }
                    Button { pickFile = true } label: { Label("From Files", systemImage: "folder") }
                }
                Button(role: .destructive) { confirmRemove = true } label: { Label("Remove video", systemImage: "trash") }
            } else {
                Section("Add a recording to watch while marking") {
                    Button { pickPhoto = true } label: { Label("From Photos", systemImage: "photo.on.rectangle") }
                    Button { pickFile = true } label: { Label("From Files", systemImage: "folder") }
                }
            }
        } label: {
            Label("Video", systemImage: has ? "film.fill" : "film")
        }
        .disabled(video.importProgress != nil)
        .onAppear { video.attach(trackID: track.id) }
        .photosPicker(isPresented: $pickPhoto, selection: $photoItem, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            video.attach(trackID: track.id)
            video.importPhoto(item, for: track.id)
            photoItem = nil
        }
        .fileImporter(isPresented: $pickFile, allowedContentTypes: CueVideoImport.fileTypes) { result in
            if case .success(let url) = result {
                video.attach(trackID: track.id)
                video.importFile(url, for: track.id)
            }
        }
        .confirmationDialog("Remove the video from this track?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove video", role: .destructive) { video.removeVideo() }
        } message: {
            Text("Your marks stay. The copy of the video in TC Playback is deleted.")
        }
        .alert("Video", isPresented: Binding(get: { video.importError != nil }, set: { if !$0 { video.importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(video.importError ?? "") }
    }
}
