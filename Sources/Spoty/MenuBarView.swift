import SwiftUI

/// The menu bar title: a compact now-playing line, so the app is useful with its window
/// closed. Kept short because the menu bar is shared real estate.
struct MenuBarLabel: View {
    let playback: PlaybackState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            if let name = playback.snapshot?.item?.name {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)
            }
        }
    }

    private var icon: String {
        guard let snapshot = playback.snapshot else { return "music.note" }
        return snapshot.isPlaying ? "play.fill" : "pause.fill"
    }
}

struct MenuBarContent: View {
    let playback: PlaybackState
    let settings: Settings
    let onShowWindow: () -> Void

    var body: some View {
        if let snapshot = playback.snapshot, let item = snapshot.item {
            Text(item.name)
            Text(snapshot.artistNames)
            if let album = item.album?.name, !album.isEmpty {
                Text(album)
            }
            Divider()
            Button(snapshot.isPlaying ? "Pause" : "Play") { playback.playPause() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Next") { playback.next() }
            Button("Previous") { playback.previous() }
            Divider()
            Button("Shuffle\(snapshot.shuffleState == true ? " ✓" : "")") {
                playback.toggleShuffle()
            }
            Button("Repeat\(repeatSuffix(snapshot.repeatState))") { playback.cycleRepeat() }
            Button("Like") { playback.like() }
        } else if playback.isReachable {
            Text("Nothing playing")
        } else {
            Text("Connecting…")
        }

        Divider()
        Button("Show Player", action: onShowWindow)
        SettingsToggles(settings: settings)
        Button("Quit Spoty") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func repeatSuffix(_ state: String?) -> String {
        switch state {
        case "track": " · track"
        case "context": " · all"
        default: ""
        }
    }
}

/// The app's settings, rendered as menu items. Shared by the menu bar extra and the
/// main menu, since the menu bar item is off by default and cannot be its own switch.
struct SettingsToggles: View {
    let settings: Settings

    var body: some View {
        Divider()
        Toggle("Menu Bar Item", isOn: bind(\.showMenuBarItem))
        Toggle("Track Change Notifications", isOn: bind(\.notifyOnTrackChange))
        Toggle("Follow Output Device", isOn: bind(\.followOutputDevice))
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0 }
        )
    }
}
