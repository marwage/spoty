import AppKit
import Foundation
import os

private let log = Logger(subsystem: "com.marcelwagenlander.spoty", category: "artwork")

/// Downloads and memoises album art.
///
/// The art is fetched from the URL in the playback payload rather than read from
/// `~/.cache/spotify-player/image/`. That on-disk cache has a deterministic name —
/// `{album}-{artist}-cover-{albumId prefix}.jpg` — but it is only written by a full
/// spotify_player instance, is gated on a config flag, and is never refreshed once
/// written, so it is not a dependable source.
actor ArtworkCache {
    private var cache: [URL: NSImage] = [:]
    private let limit = 32

    func image(for url: URL) async -> NSImage? {
        if let cached = cache[url] { return cached }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else {
                log.warning("artwork fetch returned no usable image: \(url.lastPathComponent)")
                return nil
            }
            if cache.count >= limit { cache.removeAll() }
            cache[url] = image
            return image
        } catch {
            log.warning("artwork fetch failed: \(error.localizedDescription)")
            return nil
        }
    }
}
