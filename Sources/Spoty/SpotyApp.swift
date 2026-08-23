import AppKit
import SwiftUI

@main
struct SpotyApp: App {
    @State private var process = PlayerProcess()
    @State private var playback = PlaybackState()
    @State private var settings = Settings()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Spoty", id: "main") {
            ContentView(process: process)
                .frame(minWidth: 640, minHeight: 400)
                .onAppear {
                    appDelegate.process = process
                    appDelegate.activateIntegrations(
                        playback: playback, process: process, settings: settings
                    )
                    playback.claimPlayback = settings.claimPlayback
                    playback.startPolling()
                }
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // The menu bar item is off by default, so its own toggle has to live
            // somewhere always reachable.
            CommandMenu("Player") {
                SettingsToggles(settings: settings)
            }
        }

        MenuBarExtra(isInserted: menuBarVisible) {
            MenuBarRoot(playback: playback, settings: settings)
        } label: {
            MenuBarLabel(playback: playback)
        }
    }

    private var menuBarVisible: Binding<Bool> {
        Binding(
            get: { settings.showMenuBarItem },
            set: { settings.showMenuBarItem = $0 }
        )
    }
}

/// Separate view so it can reach `openWindow`, which is not available in App scope.
private struct MenuBarRoot: View {
    let playback: PlaybackState
    let settings: Settings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarContent(playback: playback, settings: settings) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
    }
}

struct ContentView: View {
    let process: PlayerProcess

    var body: some View {
        Group {
            if case .failed(let message) = process.state {
                FailureView(message: message)
            } else {
                TerminalPane(process: process)
                    // Every edge but the top: ignoring the top too draws the terminal
                    // under the title bar, which silently swallows its first two rows —
                    // the playback block's border and the track line.
                    .ignoresSafeArea(edges: [.horizontal, .bottom])
            }
        }
        .background(.black)
    }
}

private struct FailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Cannot start Spoty")
                .font(.headline)
            Text(message)
                .font(.system(.callout, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var process: PlayerProcess?
    @MainActor private var nowPlaying: NowPlayingBridge?
    @MainActor private var notifications: NotificationBridge?
    @MainActor private var audioWatcher: AudioDeviceWatcher?

    @MainActor
    func activateIntegrations(
        playback: PlaybackState,
        process: PlayerProcess,
        settings: Settings
    ) {
        guard nowPlaying == nil else { return }

        let bridge = NowPlayingBridge(state: playback)
        bridge.activate()
        nowPlaying = bridge

        let notifier = NotificationBridge(state: playback, settings: settings)
        notifications = notifier

        playback.onSnapshotChange = { [weak bridge, weak notifier] in
            bridge?.update()
            notifier?.update()
        }
        playback.onSocketUnreachable = { [weak process] in
            process?.restartChild(reason: "control socket unreachable")
        }

        let watcher = AudioDeviceWatcher {
            Task { @MainActor in
                guard settings.followOutputDevice else { return }
                process.restartAudioEngine()
            }
        }
        watcher.start()
        audioWatcher = watcher
    }

    /// The menu bar extra keeps playback reachable with the window closed, so closing the
    /// window should not quit the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        process?.quit()
    }
}
