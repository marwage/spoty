import Foundation
import os

private let log = Logger(subsystem: "com.marcelwagenlander.spoty", category: "playback")

// MARK: - Wire models
//
// These mirror the Spotify Web API playback object, which `get key playback` returns
// verbatim. It already carries everything a now-playing UI needs — including three
// artwork resolutions — so no separate Web API call is required.

struct Device: Decodable, Identifiable, Equatable {
    let id: String?
    let name: String
    let isActive: Bool
    let volumePercent: Int?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case isActive = "is_active"
        case volumePercent = "volume_percent"
    }
}

struct Artwork: Decodable, Equatable {
    let url: String
    let width: Int?
    let height: Int?
}

struct Album: Decodable, Equatable {
    let id: String?
    let name: String
    let images: [Artwork]
}

struct Artist: Decodable, Equatable {
    let id: String?
    let name: String
}

struct PlayableItem: Decodable, Equatable {
    let id: String?
    let name: String
    let durationMs: Int?
    let artists: [Artist]?
    let album: Album?

    enum CodingKeys: String, CodingKey {
        case id, name, artists, album
        case durationMs = "duration_ms"
    }
}

struct PlaybackSnapshot: Decodable, Equatable {
    let device: Device?
    let isPlaying: Bool
    let progressMs: Int?
    let shuffleState: Bool?
    let repeatState: String?
    let item: PlayableItem?
    let currentlyPlayingType: String?

    enum CodingKeys: String, CodingKey {
        case device, item
        case isPlaying = "is_playing"
        case progressMs = "progress_ms"
        case shuffleState = "shuffle_state"
        case repeatState = "repeat_state"
        case currentlyPlayingType = "currently_playing_type"
    }

    var artistNames: String {
        (item?.artists ?? []).map(\.name).joined(separator: ", ")
    }

    /// Middle resolution (300px) where available — right for a menu bar thumbnail and a
    /// notification attachment, without pulling the 640px original every track change.
    var artworkURL: URL? {
        guard let images = item?.album?.images, !images.isEmpty else { return nil }
        let chosen = images.first { $0.width == 300 } ?? images.last
        return chosen.flatMap { URL(string: $0.url) }
    }
}

// MARK: - State hub

/// Polls the control socket and publishes the result. Everything that renders playback
/// — the menu bar, Now Playing, notifications — reads from here rather than talking to
/// the socket itself.
@MainActor
@Observable
final class PlaybackState {
    private(set) var snapshot: PlaybackSnapshot?
    private(set) var lastError: String?
    private(set) var isReachable = false

    /// Whether to transfer Spotify playback to this Mac on startup. Off means the app
    /// observes and controls whatever device is already active, without stealing it.
    var claimPlayback = true

    /// Fired after every poll, for consumers that push rather than render — Now Playing
    /// and notifications.
    var onSnapshotChange: (() -> Void)?

    /// Fired when the control socket has been silent long enough that the child is
    /// presumed to have failed its socket bind.
    var onSocketUnreachable: (() -> Void)?

    private static let maxClaimAttempts = 8

    private let client: ControlClient
    private var pollTask: Task<Void, Never>?
    private var hasClaimedDevice = false
    private var claimAttempts = 0
    private var unreachablePolls = 0
    private var recoveryAttempts = 0

    /// ~20s of silence at the 2s poll interval. Long enough to cover a normal cold start,
    /// which takes about five seconds.
    private static let unreachableThreshold = 10
    private static let maxRecoveryAttempts = 3

    /// Measured against a live child: play/pause shows up in the cached playback within
    /// 300ms, a track change within 1.5s. Three seconds is therefore a wide margin before
    /// concluding a command was dropped — and the cost of being wrong is one extra skip.
    private static let confirmWindow = Duration.seconds(3)
    private static let confirmPollInterval = Duration.milliseconds(300)
    private static let maxCommandAttempts = 3
    private static let retryBackoff = Duration.milliseconds(700)

    private var commandTask: Task<Void, Never>?

    /// Two seconds is deliberate. Now Playing gets a playback *rate* so macOS interpolates
    /// the scrubber between polls, and this account already sees frequent 429s — every
    /// playback command makes spotify_player fire five extra Web API calls of its own.
    private let pollInterval = Duration.seconds(2)

    init(client: ControlClient = ControlClient()) {
        self.client = client
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(2))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func refresh(countsTowardRecovery: Bool = true) async {
        do {
            snapshot = try await client.playback()
            lastError = nil
            if !isReachable {
                log.info("control socket reachable on port \(PlayerProcess.controlPort)")
            }
            isReachable = true
            unreachablePolls = 0
            await claimLocalDeviceIfNeeded()
        } catch ControlClient.ControlError.timedOut {
            // Expected while the child is still starting up; sustained silence means it
            // came up without a socket and needs replacing.
            isReachable = false
            // Only the steady 2s poll counts towards recovery. Confirmation polls run in
            // bursts and would reach the threshold in seconds rather than the intended ~20s.
            if countsTowardRecovery {
                unreachablePolls += 1
                if unreachablePolls >= Self.unreachableThreshold,
                   recoveryAttempts < Self.maxRecoveryAttempts {
                    recoveryAttempts += 1
                    unreachablePolls = 0
                    log.warning("control socket silent; restarting child (attempt \(self.recoveryAttempts))")
                    onSocketUnreachable?()
                }
            }
        } catch {
            isReachable = true
            lastError = error.localizedDescription
            log.warning("playback poll failed: \(error.localizedDescription)")
        }
        onSnapshotChange?()
    }

    /// spotify_player only auto-claims playback when it finds no active Connect device.
    /// If the user has a phone or another desktop active, our device sits idle and audio
    /// plays there instead, so claim it once on startup.
    private func claimLocalDeviceIfNeeded() async {
        guard claimPlayback, !hasClaimedDevice, claimAttempts < Self.maxClaimAttempts else { return }
        claimAttempts += 1
        do {
            let devices = try await client.devices()
            guard let mine = devices.first(where: { $0.name == PlayerProcess.deviceName }) else {
                log.warning("device '\(PlayerProcess.deviceName)' not registered yet")
                return
            }
            if !mine.isActive {
                log.info("claiming playback for '\(PlayerProcess.deviceName)'")
                try await client.connect(to: PlayerProcess.deviceName)
            }
            hasClaimedDevice = true
        } catch {
            // Transient failures here are common — the shared client_id 429s regularly —
            // so leave hasClaimedDevice false and let the next poll retry, bounded by
            // claimAttempts so a persistent failure cannot hammer the Web API.
            log.warning("could not claim local device: \(error.localizedDescription)")
        }
    }

    // MARK: - Commands
    //
    // Transport commands are confirmed rather than trusted. spotify_player's socket
    // handler spawns the player request and answers `Ok` before it has run, so a command
    // Spotify then rejects — a 429 during a burst, a dropped connection — comes back to
    // us as a success and vanishes without trace. That is what makes the media keys look
    // like they work only sometimes. The only way to know a command landed is to watch
    // the playback afterwards, which is cheap: the child serves `Get Playback` from its
    // own cached state without touching the Web API.

    func playPause() { setPlaying(!(snapshot?.isPlaying ?? false)) }

    /// Idempotent, unlike `PlayPause`, so a retry cannot toggle back off a command that
    /// did land after all.
    func setPlaying(_ playing: Bool) {
        dispatch(playing ? "Play" : "Pause") { $0?.isPlaying == playing }
    }

    func next() {
        let from = snapshot?.item?.id
        dispatch("Next") { $0?.item?.id != from }
    }

    func previous() {
        let from = snapshot?.item?.id
        dispatch("Previous") { $0?.item?.id != from }
    }

    func toggleShuffle() {
        let from = snapshot?.shuffleState
        dispatch("Shuffle") { $0?.shuffleState != from }
    }

    func cycleRepeat() {
        let from = snapshot?.repeatState
        dispatch("Repeat") { $0?.repeatState != from }
    }

    /// Liking is not reflected in the playback snapshot, so unlike the transport commands
    /// it cannot be confirmed.
    func like() { send { try await $0.like() } }

    /// Now Playing hands us an absolute target; the socket wants a relative offset.
    ///
    /// Also unconfirmed: scrubbing produces a stream of these and progress advances on its
    /// own, so there is no stable "did it land" to test against.
    func seek(toMilliseconds target: Int) {
        let current = snapshot?.progressMs ?? 0
        send { try await $0.seek(offsetMilliseconds: target - current) }
    }

    /// Issues a transport command and retries until the playback shows it took effect.
    ///
    /// `landed` is evaluated against each fresh snapshot and answers "is the effect
    /// visible yet", so it has to be written against state captured *before* the command
    /// goes out.
    private func dispatch(
        _ command: String,
        landed: @escaping @Sendable (PlaybackSnapshot?) -> Bool
    ) {
        // One transport command in flight at a time. Mashing a media key that looks dead
        // otherwise queues several, and each one that does land makes spotify_player fire
        // five more Web API calls of its own — which is what provokes the rate limiting
        // to begin with.
        commandTask?.cancel()
        commandTask = Task { [weak self] in
            await self?.runConfirmed(command, landed: landed)
        }
    }

    private func runConfirmed(
        _ command: String,
        landed: @Sendable (PlaybackSnapshot?) -> Bool
    ) async {
        for attempt in 1...Self.maxCommandAttempts {
            do {
                try await client.simple(command)
            } catch {
                lastError = error.localizedDescription
                log.warning("\(command) could not be sent: \(error.localizedDescription)")
                return
            }

            if await confirm(landed) {
                if attempt > 1 {
                    log.info("\(command) landed on attempt \(attempt)")
                }
                return
            }
            if Task.isCancelled { return }

            guard attempt < Self.maxCommandAttempts else { break }
            log.warning("\(command) was accepted but had no effect; retrying")
            try? await Task.sleep(for: Self.retryBackoff)
            if Task.isCancelled { return }
        }

        lastError = "Spotify dropped \(command) — most likely rate limited."
        log.warning("\(command) dropped after \(Self.maxCommandAttempts) attempts")
    }

    /// Polls the cached playback until the command's effect appears, or the window runs out.
    private func confirm(_ landed: @Sendable (PlaybackSnapshot?) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + Self.confirmWindow
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.confirmPollInterval)
            if Task.isCancelled { return false }
            await refresh(countsTowardRecovery: false)
            if landed(snapshot) { return true }
        }
        return false
    }

    /// For commands whose effect the playback snapshot cannot show.
    private func send(_ body: @escaping @Sendable (ControlClient) async throws -> Void) {
        Task { [client] in
            do {
                try await body(client)
                await refresh(countsTowardRecovery: false)
            } catch {
                lastError = error.localizedDescription
                log.warning("command failed: \(error.localizedDescription)")
            }
        }
    }
}
