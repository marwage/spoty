import Foundation

/// Speaks `spotify_player`'s UDP control protocol directly.
///
/// Shelling out to the CLI is not a viable alternative: when no instance owns the socket
/// the CLI spawns a headless one that serves exactly one request, then exits — roughly
/// 350ms and a live Web API call per command. Our child owns the socket for the life of
/// the app, so requests here are served from its cached state.
actor ControlClient {
    enum ControlError: Error, LocalizedError {
        case timedOut
        case remote(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .timedOut: "spotify_player did not respond"
            case .remote(let message): message
            case .malformed(let detail): "Malformed response: \(detail)"
            }
        }
    }

    private let port: UInt16
    private let timeout: TimeInterval

    init(port: UInt16 = PlayerProcess.controlPort, timeout: TimeInterval = 4) {
        self.port = port
        self.timeout = timeout
    }

    // MARK: - Commands

    func playback() async throws -> PlaybackSnapshot? {
        let payload = try await send(["Get": ["Key": "Playback"]])
        guard payload != Data("null".utf8), !payload.isEmpty else { return nil }
        return try JSONDecoder().decode(PlaybackSnapshot.self, from: payload)
    }

    func devices() async throws -> [Device] {
        let payload = try await send(["Get": ["Key": "Devices"]])
        guard !payload.isEmpty, payload != Data("null".utf8) else { return [] }
        return try JSONDecoder().decode([Device].self, from: payload)
    }

    /// Transfers Spotify playback to a Connect device by name. Without this the app's own
    /// device stays idle and commands act on whatever device is currently active — a
    /// phone, another desktop — so no audio comes out of this Mac.
    func connect(to deviceName: String) async throws {
        _ = try await send(["Connect": ["Name": deviceName]])
    }

    func simple(_ command: String) async throws {
        _ = try await send(["Playback": command])
    }

    /// `Seek` takes a *relative* offset in milliseconds, not an absolute position.
    func seek(offsetMilliseconds: Int) async throws {
        _ = try await send(["Playback": ["Seek": offsetMilliseconds]])
    }

    func setVolume(percent: Int) async throws {
        _ = try await send(["Playback": ["Volume": ["percent": percent, "is_offset": false]]])
    }

    func like(unlike: Bool = false) async throws {
        _ = try await send(["Like": ["unlike": unlike]])
    }

    func startLikedTracks(limit: Int = 50, random: Bool = true) async throws {
        _ = try await send(["Playback": ["StartLikedTracks": ["limit": limit, "random": random]]])
    }

    // MARK: - Wire protocol

    /// Sends one request and returns the decoded inner payload.
    ///
    /// The envelope is the surprising part: `Response` is `Ok(Vec<u8>)`/`Err(Vec<u8>)` with
    /// a plain serde derive, and serde_json has no special case for `Vec<u8>` — so the
    /// payload arrives as a JSON *array of integers*, not as JSON. Decoding is two-stage.
    private func send(_ request: Any) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: request)
        let raw = try await roundTrip(body)

        guard let envelope = try JSONSerialization.jsonObject(with: raw) as? [String: [Int]] else {
            throw ControlError.malformed(String(decoding: raw.prefix(200), as: UTF8.self))
        }
        if let bytes = envelope["Err"] {
            throw ControlError.remote(String(decoding: Data(bytes.map { UInt8($0 & 0xFF) }), as: UTF8.self))
        }
        guard let bytes = envelope["Ok"] else {
            throw ControlError.malformed("no Ok/Err key")
        }
        return Data(bytes.map { UInt8($0 & 0xFF) })
    }

    /// One request, then datagrams reassembled until a zero-length one ends the stream.
    /// A request spotify_player cannot deserialize is answered with total silence, so the
    /// timeout is what keeps this from hanging forever.
    private func roundTrip(_ body: Data) async throws -> Data {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw ControlError.malformed("socket() failed") }
        defer { close(fd) }

        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let sent = body.withUnsafeBytes { buffer in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buffer.baseAddress, buffer.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent >= 0 else { throw ControlError.malformed("sendto() failed: \(errno)") }

        var assembled = Data()
        var chunk = [UInt8](repeating: 0, count: 65535)
        while true {
            let received = recv(fd, &chunk, chunk.count, 0)
            if received < 0 { throw ControlError.timedOut }
            if received == 0 { break }
            assembled.append(contentsOf: chunk[0..<received])
        }
        return assembled
    }
}
