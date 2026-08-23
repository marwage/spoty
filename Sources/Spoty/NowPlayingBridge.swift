import AppKit
import MediaPlayer
import os

private let log = Logger(subsystem: "com.marcelwagenlander.spoty", category: "nowplaying")

/// Publishes playback to Control Centre and the lock screen, and routes hardware media
/// keys and AirPods gestures back to the control socket.
///
/// This is the reason the app exists. spotify_player's own macOS media control goes
/// through souvlaki, which needs a window it does not have as a CLI, so it opens an
/// invisible winit window that steals focus on startup and leaves a ghost in the Dock.
/// A bundled app gets a real NSApplication run loop and does this properly.
@MainActor
final class NowPlayingBridge {
    private let state: PlaybackState
    private let artwork: ArtworkCache
    private var lastTrackID: String?
    private var lastIsPlaying: Bool?
    private var artworkTask: Task<Void, Never>?

    init(state: PlaybackState, artwork: ArtworkCache = ArtworkCache()) {
        self.state = state
        self.artwork = artwork
    }

    func activate() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.state.playPause(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.state.playPause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.state.playPause(); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.state.next(); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.state.previous(); return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.state.seek(toMilliseconds: Int(event.positionTime * 1000))
            return .success
        }

        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand,
                        center.changePlaybackPositionCommand] {
            command.isEnabled = true
        }
        log.info("remote command center activated")
    }

    /// Called after every poll. Metadata is only rewritten when the track or play/pause
    /// state actually changes; between those, the playback *rate* lets macOS interpolate
    /// the scrubber itself, so a 2-second poll still looks smooth.
    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let snapshot = state.snapshot, let item = snapshot.item else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            lastTrackID = nil
            lastIsPlaying = nil
            return
        }

        let trackChanged = item.id != lastTrackID
        let stateChanged = snapshot.isPlaying != lastIsPlaying

        var info = center.nowPlayingInfo ?? [:]
        if trackChanged {
            info[MPMediaItemPropertyTitle] = item.name
            info[MPMediaItemPropertyArtist] = snapshot.artistNames
            info[MPMediaItemPropertyAlbumTitle] = item.album?.name ?? ""
            info[MPMediaItemPropertyPlaybackDuration] = (item.durationMs ?? 0) / 1000
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
            info[MPMediaItemPropertyArtwork] = nil
            loadArtwork(for: snapshot)
        }

        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = (snapshot.progressMs ?? 0) / 1000
        info[MPNowPlayingInfoPropertyPlaybackRate] = snapshot.isPlaying ? 1.0 : 0.0
        center.nowPlayingInfo = info
        center.playbackState = snapshot.isPlaying ? .playing : .paused

        if trackChanged || stateChanged {
            log.debug("now playing: \(item.name) playing=\(snapshot.isPlaying)")
        }
        lastTrackID = item.id
        lastIsPlaying = snapshot.isPlaying
    }

    private func loadArtwork(for snapshot: PlaybackSnapshot) {
        artworkTask?.cancel()
        guard let url = snapshot.artworkURL else { return }
        let trackID = snapshot.item?.id
        artworkTask = Task { [weak self, artwork] in
            guard let image = await artwork.image(for: url) else { return }
            guard let self, !Task.isCancelled else { return }
            // The track may have moved on while the download was in flight.
            guard self.lastTrackID == trackID else { return }
            let center = MPNowPlayingInfoCenter.default()
            var info = center.nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(from: image)
            center.nowPlayingInfo = info
        }
    }

    /// MediaPlayer calls the artwork request handler on its own dispatch queue. Built
    /// inside this @MainActor type the closure would inherit MainActor isolation, and the
    /// resulting executor check traps the whole process with SIGTRAP, so it is deliberately
    /// constructed from a nonisolated context.
    private nonisolated static func makeArtwork(from image: NSImage) -> MPMediaItemArtwork {
        let box = ImageBox(image: image)
        return MPMediaItemArtwork(boundsSize: image.size) { _ in box.image }
    }
}

/// NSImage is not Sendable, but the artwork handler only reads it for drawing.
private struct ImageBox: @unchecked Sendable {
    let image: NSImage
}
