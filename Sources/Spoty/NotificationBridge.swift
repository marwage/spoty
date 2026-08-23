import AppKit
import Foundation
import UserNotifications
import os

private let log = Logger(subsystem: "com.marcelwagenlander.spoty", category: "notify")

/// Posts a banner on track change, with real album art.
///
/// spotify_player's own notifications are disabled via `-o enable_notify=false` because
/// on macOS they route through mac_notification_sys, which uses only title, subtitle,
/// message and sound — the icon and timeout it sets are silently dropped, and the banner
/// is attributed to whichever bundle the terminal happens to be.
@MainActor
final class NotificationBridge {
    private let state: PlaybackState
    private let settings: Settings
    private let artwork: ArtworkCache
    private var lastTrackID: String?
    private var isAuthorized = false
    private var hasRequestedAuthorization = false
    private var hasSeenFirstTrack = false

    init(state: PlaybackState, settings: Settings, artwork: ArtworkCache = ArtworkCache()) {
        self.state = state
        self.settings = settings
        self.artwork = artwork
    }

    /// Asked for only once the user has actually enabled notifications, so launching the
    /// app with the feature off never raises a permission prompt.
    private func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            Task { @MainActor [weak self] in
                self?.isAuthorized = granted
                if let error {
                    log.warning("notification authorization failed: \(error.localizedDescription)")
                } else {
                    log.info("notification authorization granted=\(granted)")
                }
            }
        }
    }

    func update() {
        guard settings.notifyOnTrackChange else { return }
        requestAuthorizationIfNeeded()
        guard let item = state.snapshot?.item, let trackID = item.id else { return }
        guard trackID != lastTrackID else { return }
        lastTrackID = trackID

        // Don't fire for whatever happened to be loaded when the app started.
        guard hasSeenFirstTrack else {
            hasSeenFirstTrack = true
            return
        }
        guard isAuthorized else { return }

        let title = item.name
        let body = state.snapshot?.artistNames ?? ""
        let subtitle = item.album?.name ?? ""
        let url = state.snapshot?.artworkURL

        Task { [artwork] in
            var attachment: UNNotificationAttachment?
            if let url {
                attachment = await Self.attachment(for: url, cache: artwork)
            }
            await Self.post(title: title, subtitle: subtitle, body: body, attachment: attachment)
        }
    }

    /// UNNotificationAttachment needs a file URL, so the downloaded art is written to a
    /// uniquely named temp file and handed over.
    private static func attachment(for url: URL, cache: ArtworkCache) async -> UNNotificationAttachment? {
        guard let image = await cache.image(for: url),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("art-\(UUID().uuidString).png")
        do {
            try png.write(to: file)
            return try UNNotificationAttachment(identifier: "artwork", url: file)
        } catch {
            log.warning("could not attach artwork: \(error.localizedDescription)")
            return nil
        }
    }

    private static func post(
        title: String,
        subtitle: String,
        body: String,
        attachment: UNNotificationAttachment?
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        if let attachment { content.attachments = [attachment] }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            log.warning("could not post notification: \(error.localizedDescription)")
        }
    }
}
