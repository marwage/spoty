import Foundation
import SwiftTerm
import os

private let log = Logger(subsystem: "com.marcelwagenlander.spoty", category: "process")

/// Owns the `spotify_player` child: where its binary lives, the launch overrides that
/// hand macOS integration to this app, and what happens when it dies.
///
/// SwiftTerm 1.20's LocalProcessTerminalViewDelegate is not @MainActor-annotated, but it
/// dispatches on DispatchQueue.main by default, so @preconcurrency keeps this type
/// MainActor-isolated without the compiler refusing the conformance.
@MainActor
@Observable
final class PlayerProcess: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
    enum State: Equatable {
        case idle
        case running
        case restarting(attempt: Int)
        case failed(String)
    }

    /// A port of our own, so we never collide with a `spotify_player` the user is running
    /// in a terminal. A second instance whose client_port is taken starts up fine but its
    /// socket bind fails with only a log warning, leaving us driving the wrong instance.
    nonisolated static let controlPort: UInt16 = 8974
    nonisolated static let deviceName = "Spoty"

    private static let searchPaths = [
        "/opt/homebrew/bin/spotify_player",
        "/usr/local/bin/spotify_player",
        "/run/current-system/sw/bin/spotify_player",
    ]
    private static let maxRestartAttempts = 5

    private(set) var state: State = .idle
    private(set) var terminalTitle = "Spoty"

    private weak var terminal: LocalProcessTerminalView?
    private var restartAttempt = 0
    private var isQuitting = false
    private var isDeliberateRestart = false
    private var launchedAt: Date?

    /// Resolves the binary from the usual install prefixes, then from PATH.
    static func locateBinary() -> String? {
        let fm = FileManager.default
        if let known = searchPaths.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return known
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":")
            .map { String($0) + "/spotify_player" }
            .first { fm.isExecutableFile(atPath: $0) }
    }

    static var launchArguments: [String] {
        [
            "-o", "client_port=\(controlPort)",
            // Both are handled natively in this app instead. spotify_player's macOS
            // media control opens an invisible winit window that steals focus, and its
            // notifications drop the artwork and timeout on the floor.
            "-o", "enable_media_control=false",
            "-o", "enable_notify=false",
            "-o", "device.name=\(deviceName)",
        ]
    }

    func attach(to terminal: LocalProcessTerminalView) {
        self.terminal = terminal
        terminal.processDelegate = self
    }

    func startIfNeeded() {
        guard case .idle = state else { return }
        launch()
    }

    func quit() {
        isQuitting = true
        terminal?.terminate()
    }

    /// Makes librespot re-resolve the system default output device by triggering the TUI's
    /// own `RestartIntegratedClient` binding. There is no socket request for this, so the
    /// keystroke is the only lever.
    ///
    /// Caveat: if a TUI text field happens to have focus — the search prompt, say — this
    /// types a literal "R" instead, which is why it is behind a user-facing setting.
    func restartAudioEngine() {
        guard case .running = state, let terminal else { return }
        log.info("restarting integrated client after output device change")
        terminal.send(txt: "R")
    }

    /// Terminates the child so the normal restart path brings up a fresh one.
    ///
    /// Needed because a child whose `client_port` was already bound — by a stale instance,
    /// or one running in a terminal — starts up perfectly but its socket bind fails with
    /// nothing but a log warning, leaving it permanently unreachable.
    func restartChild(reason: String) {
        guard case .running = state, let terminal else { return }
        log.warning("restarting child: \(reason, privacy: .public)")

        // terminate() goes through childStopped(), which cancels the child monitor and
        // never calls processTerminated — a deliberate terminate is silent by design. So
        // the relaunch has to be driven from here rather than from the delegate.
        isDeliberateRestart = true
        terminal.terminate()
        state = .idle

        Task { @MainActor [weak self] in
            // Give the old process time to die and release its port.
            try? await Task.sleep(for: .seconds(2))
            guard let self, !self.isQuitting else { return }
            self.isDeliberateRestart = false
            guard case .idle = self.state else { return }
            self.launch()
        }
    }

    private func launch() {
        guard let terminal else {
            log.error("no terminal attached")
            return
        }
        guard let binary = Self.locateBinary() else {
            let message = "spotify_player was not found.\n\nInstall it with:\n  brew install spotify_player"
            log.error("spotify_player not found on PATH or in \(Self.searchPaths)")
            state = .failed(message)
            return
        }

        // SwiftTerm's default child environment is only TERM=xterm-256color and
        // deliberately omits PATH, so build it from the host environment instead.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"

        log.info("launching \(binary) \(Self.launchArguments.joined(separator: " "))")
        state = .running
        launchedAt = Date()
        terminal.startProcess(
            executable: binary,
            args: Self.launchArguments,
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: nil,
            currentDirectory: NSHomeDirectory()
        )
        terminal.window?.makeFirstResponder(terminal)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        log.debug("terminal resized to \(newCols)x\(newRows)")
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        terminalTitle = title.isEmpty ? "Spoty" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let code = exitCode.map(String.init) ?? "signal"
        guard !isQuitting else {
            log.info("spotify_player exited (\(code)) during shutdown")
            state = .idle
            return
        }
        // restartChild() already owns the relaunch; don't schedule a second one.
        guard !isDeliberateRestart else {
            state = .idle
            return
        }

        // A process that ran for a while and then died is a fresh incident, not part of a
        // crash loop, so it gets the full restart budget again.
        if let launchedAt, Date().timeIntervalSince(launchedAt) > 60 {
            restartAttempt = 0
        }

        guard restartAttempt < Self.maxRestartAttempts else {
            log.error("spotify_player exited (\(code)); giving up after \(Self.maxRestartAttempts) restarts")
            state = .failed("spotify_player kept exiting (last code: \(code)).")
            return
        }

        restartAttempt += 1
        let delay = min(pow(2.0, Double(restartAttempt - 1)), 30)
        log.warning("spotify_player exited (\(code)); restart \(self.restartAttempt) in \(delay)s")
        state = .restarting(attempt: restartAttempt)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.isQuitting else { return }
            self.state = .idle
            self.launch()
        }
    }
}
