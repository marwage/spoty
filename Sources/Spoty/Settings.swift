import Foundation

@MainActor
@Observable
final class Settings {
    private enum Key {
        static let followOutputDevice = "followOutputDevice"
        static let claimPlayback = "claimPlayback"
        static let showMenuBarItem = "showMenuBarItem"
        static let notifyOnTrackChange = "notifyOnTrackChange"
    }

    /// Off by default: the menu bar is shared real estate, so opt in rather than out.
    var showMenuBarItem: Bool {
        didSet { UserDefaults.standard.set(showMenuBarItem, forKey: Key.showMenuBarItem) }
    }

    /// Off by default. Enabling it is what triggers the macOS permission prompt, so the
    /// app never asks for notification access it has not been told to use.
    var notifyOnTrackChange: Bool {
        didSet { UserDefaults.standard.set(notifyOnTrackChange, forKey: Key.notifyOnTrackChange) }
    }

    /// Restart the integrated client when the system output device changes, so audio
    /// follows AirPods and display speakers instead of staying on the old device.
    var followOutputDevice: Bool {
        didSet { UserDefaults.standard.set(followOutputDevice, forKey: Key.followOutputDevice) }
    }

    /// Transfer Spotify playback to this Mac on launch.
    var claimPlayback: Bool {
        didSet { UserDefaults.standard.set(claimPlayback, forKey: Key.claimPlayback) }
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.followOutputDevice: true,
            Key.claimPlayback: true,
            Key.showMenuBarItem: false,
            Key.notifyOnTrackChange: false,
        ])
        followOutputDevice = defaults.bool(forKey: Key.followOutputDevice)
        claimPlayback = defaults.bool(forKey: Key.claimPlayback)
        showMenuBarItem = defaults.bool(forKey: Key.showMenuBarItem)
        notifyOnTrackChange = defaults.bool(forKey: Key.notifyOnTrackChange)
    }
}
