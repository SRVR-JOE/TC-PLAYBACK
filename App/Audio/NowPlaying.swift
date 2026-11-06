import Foundation
import MediaPlayer

/// Lock screen / Control Centre integration.
extension PlaybackEngine {
    func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in
            guard let self, self.source != .none else { return .noActionableNowPlayingItem }
            self.play(); return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.source != .none else { return .noActionableNowPlayingItem }
            self.togglePlayPause(); return .success
        }
        cc.stopCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.remoteTransportLocked { return .commandFailed }
            self.stop(); return .success
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            if self.remoteTransportLocked { return .commandFailed }
            self.seek(to: e.positionTime); return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            guard let hook = self?.onRemoteNext else { return .noSuchContent }
            hook(); return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            guard let hook = self?.onRemotePrevious else { return .noSuchContent }
            hook(); return .success
        }
        for c in [cc.playCommand, cc.pauseCommand, cc.togglePlayPauseCommand, cc.stopCommand,
                  cc.changePlaybackPositionCommand, cc.nextTrackCommand, cc.previousTrackCommand] {
            c.isEnabled = true
        }
    }

    func updateNowPlaying() {
        guard remoteCommandsInstalled else { return }
        let center = MPNowPlayingInfoCenter.default()
        let title: String
        switch source {
        case .none:
            center.nowPlayingInfo = nil
            return
        case .file(let url):
            title = nowPlayingTitle ?? url.deletingPathExtension().lastPathComponent
        case .generator(let cfg):
            title = nowPlayingTitle ?? "Timecode from \(cfg.start)"
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "TC Playback",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: transport == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        center.nowPlayingInfo = info
    }
}
