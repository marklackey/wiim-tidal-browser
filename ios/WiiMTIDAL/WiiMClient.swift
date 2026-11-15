import Foundation
import Security
import os

struct WiiMAddress: Equatable {
    static let defaultQueuePort = 49152

    let host: String
    let queuePort: Int
    let queuePath: String

    init?(host: String, queuePort: String, queuePath: String = "/upnp/control/PlayQueue1") {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let bytes = parts.compactMap { UInt8($0) }
        guard parts.count == 4, bytes.count == 4,
              bytes.map(String.init).joined(separator: ".") == host else { return nil }

        switch (bytes[0], bytes[1]) {
        case (10, _), (172, 16...31), (192, 168), (169, 254): break
        default: return nil
        }

        let portText = queuePort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(portText), (1...65535).contains(port) else { return nil }
        guard queuePath.hasPrefix("/"), !queuePath.hasPrefix("//"),
              !queuePath.contains("?"), !queuePath.contains("#") else { return nil }
        self.host = host
        self.queuePort = port
        self.queuePath = queuePath
    }

    var queueURL: URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = queuePort
        components.path = queuePath
        return components.url!
    }

    func commandURL(_ command: String) -> URL {
        var url = URLComponents()
        url.scheme = "https"
        url.host = host
        url.path = "/httpapi.asp"
        url.queryItems = [URLQueryItem(name: "command", value: command)]
        return url.url!
    }
}

struct TIDALTrack: Codable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let number: Int?
    let art: URL?
    var albumID: Int? = nil

    init?(_ input: String, title: String? = nil, artist: String = "", album: String = "",
          number: Int? = nil, art: URL? = nil, albumID: Int? = nil) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let url = URLComponents(string: text), url.scheme?.lowercased() == "https",
           let host = url.host?.lowercased(), ["tidal.com", "www.tidal.com", "listen.tidal.com"].contains(host),
           url.user == nil, url.password == nil, url.port == nil {
            let path = url.path.split(separator: "/")
            guard path.count >= 2, path[path.count - 2] == "track", let last = path.last else { return nil }
            candidate = String(last)
        } else {
            candidate = text
        }
        guard candidate.utf8.allSatisfy({ (48...57).contains($0) }),
              let id = UInt64(candidate), id > 0 else { return nil }
        self.id = String(id)
        self.title = title ?? "TIDAL track \(id)"
        self.artist = artist
        self.album = album
        self.number = number
        self.art = art
        self.albumID = albumID
    }
}

struct NowPlaying: Equatable {
    let title: String?
    let artist: String?
    let album: String?
    var status: String?
    var volume: Int?
    var trackID: String? = nil
    var art: URL? = nil
    var position: Double? = nil
    var duration: Double? = nil
    var sampledAt = Date()
    var bitrate: String? = nil
    var bitrateUnit: String? = nil

    var isPlaying: Bool { ["play", "playing"].contains(status?.lowercased() ?? "") }
    var isLoading: Bool { ["load", "loading", "buffering"].contains(status?.lowercased() ?? "") }
    var playbackLabel: String {
        switch status?.lowercased() {
        case "play", "playing": return "Playing"
        case "pause", "paused": return "Paused"
        case "stop", "stopped": return "Stopped"
        case "load", "loading", "buffering": return "Loading"
        default: return "Ready"
        }
    }

    func elapsed(at date: Date) -> Double {
        let elapsed = max(0, (position ?? 0) + (isPlaying ? max(0, date.timeIntervalSince(sampledAt)) : 0))
        return min(elapsed, duration ?? elapsed)
    }
}

enum PlayerCommand: Equatable {
    case pause, resume, toggle, previous, next, seek(Int), volume(Int)

    var value: String {
        switch self {
        case .pause: return "pause"
        case .resume: return "resume"
        case .toggle: return "onepause"
        case .previous: return "prev"
        case .next: return "next"
        case .seek(let seconds): return "seek:\(max(0, seconds))"
        case .volume(let volume): return "vol:\(min(100, max(0, volume)))"
        }
    }
}

protocol WiiMTransport: AnyObject {
    var address: WiiMAddress { get }
    func nowPlaying() async throws -> NowPlaying
    func control(_ command: PlayerCommand) async throws
    func play(_ tracks: [TIDALTrack]) async throws
}

enum WiiMError: LocalizedError {
    case http(Int)
    case invalidResponse
    case noPlaybackInfo
    case queueRejected
    case queueSize
    case controlRejected

    var errorDescription: String? {
        switch self {
        case .http(let status): return "WiiM returned HTTP \(status)."
        case .invalidResponse: return "WiiM returned an unexpected response."
        case .noPlaybackInfo: return "WiiM returned no playback status. Try starting a track in WiiM Home and reconnecting."
        case .queueRejected: return "WiiM rejected the queue. Check the track ID and the TIDAL login in WiiM Home."
        case .queueSize: return "The WiiM queue accepts 1 to 100 tracks."
        case .controlRejected: return "WiiM couldn’t complete the playback command. Please try again."
        }
    }
}

final class WiiMClient: WiiMTransport {
    static let maxQueueSize = 100
    private static let queueService = "urn:schemas-wiimu-com:service:PlayQueue:1"

    let address: WiiMAddress
    private let session: URLSession

    init(address: WiiMAddress, configuration: URLSessionConfiguration = .ephemeral) {
        self.address = address
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: WiiMSessionDelegate(host: address.host), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func nowPlaying() async throws -> NowPlaying {
        async let statusRequest = playerStatus()
        async let metadataRequest = try? commandObject("getMetaInfo")
        let status = try await statusRequest
        let sampledAt = Date()
        let info = await metadataRequest
        let metadata = info?["metaData"] as? [String: Any]
        let artwork = displayText(metadata?["albumArtURI"] ?? metadata?["albumArtUrl"]).flatMap(URL.init(string:))
        let position = displayText(status["curpos"]).flatMap(Double.init).flatMap { $0.isFinite && (0...604_800_000).contains($0) ? $0 / 1000 : nil }
        let duration = displayText(status["totlen"]).flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 && $0 <= 604_800_000 ? $0 / 1000 : nil }
        return NowPlaying(
            title: displayText(metadata?["title"]),
            artist: displayText(metadata?["artist"]),
            album: displayText(metadata?["album"]),
            status: displayText(status["status"]),
            volume: displayText(status["vol"]).flatMap(Int.init).flatMap { (0...100).contains($0) ? $0 : nil },
            trackID: displayText(metadata?["trackId"] ?? metadata?["track_id"]),
            art: ["http", "https"].contains(artwork?.scheme?.lowercased() ?? "") ? artwork : nil,
            position: position, duration: duration, sampledAt: sampledAt,
            bitrate: displayText(metadata?["bitRate"] ?? metadata?["bitrate"] ?? metadata?["bit_rate"]),
            bitrateUnit: displayText(metadata?["bitrateUnit"])
        )
    }

    func control(_ command: PlayerCommand) async throws {
        let data = try await sendCommand("setPlayerCmd:\(command.value)")
        let reply = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard reply.uppercased() == "OK" else { throw WiiMError.controlRejected }
    }

    func play(_ tracks: [TIDALTrack]) async throws {
        guard (1...Self.maxQueueSize).contains(tracks.count) else { throw WiiMError.queueSize }
        // The WiiM resolves audio using these IDs. DIDL-Lite supplies display metadata.
        let entries = tracks.enumerated().map { index, track in
            "<Track\(index + 1)><Id>\(xmlText(track.id))</Id><URL></URL>"
            + "<Metadata>\(xmlText(trackMetadata(track)))</Metadata><Source>Tidal</Source></Track\(index + 1)>"
        }.joined()
        let playlist = """
        <?xml version="1.0"?><PlayList><ListName>Hi-Res Browser</ListName><ListInfo>
          <QueueVersion>2.0</QueueVersion><SourceName>Tidal</SourceName><ContentType>songlist</ContentType>
          <TotalNumber>\(tracks.count)</TotalNumber><TrackNumber>\(tracks.count)</TrackNumber><LastPlayIndex>1</LastPlayIndex>
        </ListInfo><Tracks>\(entries)</Tracks></PlayList>
        """
        let soap = """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body><u:CreateQueue xmlns:u="\(Self.queueService)"><QueueContext>\(xmlText(playlist))</QueueContext></u:CreateQueue></s:Body>
        </s:Envelope>
        """
        var request = URLRequest(url: address.queueURL, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(Self.queueService)#CreateQueue\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(soap.utf8)
        let data = try await send(request)
        let reply = QueueReply()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = reply
        guard parser.parse() else { throw WiiMError.invalidResponse }
        if reply.hasFault { throw WiiMError.queueRejected }
        guard reply.hasResponse else { throw WiiMError.invalidResponse }
    }

    private func trackMetadata(_ track: TIDALTrack) -> String {
        let number = track.number.map { "<upnp:originalTrackNumber>\($0)</upnp:originalTrackNumber>" } ?? ""
        let artwork = track.art.map { "<upnp:albumArtURI>\(xmlText($0.absoluteString))</upnp:albumArtURI>" } ?? ""
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
          <item id="\(xmlText(track.id))" parentID="0" restricted="1">
            <dc:title>\(xmlText(track.title))</dc:title><dc:creator>\(xmlText(track.artist))</dc:creator>
            <upnp:artist>\(xmlText(track.artist))</upnp:artist><upnp:album>\(xmlText(track.album))</upnp:album>
            \(number)<upnp:class>object.item.audioItem.musicTrack</upnp:class>\(artwork)
          </item>
        </DIDL-Lite>
        """
    }

    private func playerStatus() async throws -> [String: Any] {
        for command in ["getPlayerStatusEx", "getPlayerStatus"] {
            do {
                let status = try await commandObject(command)
                if ["status", "vol", "curpos", "totlen"].contains(where: { displayText(status[$0]) != nil }) {
                    return status
                }
            } catch WiiMError.http(_) {
                continue
            } catch WiiMError.invalidResponse {
                continue
            }
        }
        throw WiiMError.noPlaybackInfo
    }

    private func commandObject(_ command: String) async throws -> [String: Any] {
        let data = try await sendCommand(command)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WiiMError.invalidResponse
        }
        return object
    }

    private func sendCommand(_ command: String) async throws -> Data {
        try await send(URLRequest(url: address.commandURL(command), timeoutInterval: 4))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw WiiMError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw WiiMError.http(response.statusCode) }
        return data
    }

    private func displayText(_ value: Any?) -> String? {
        let text = (value as? String ?? (value as? NSNumber)?.stringValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty, !["unknow", "unknown"].contains(text.lowercased()) else { return nil }
        return text
    }

    private func xmlText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private final class QueueReply: NSObject, XMLParserDelegate {
    var hasFault = false
    var hasResponse = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if elementName == "Fault" { hasFault = true }
        if elementName == "CreateQueueResponse" { hasResponse = true }
    }
}

private final class WiiMSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let host: String
    private let firstCertificate = OSAllocatedUnfairLock<Data?>(initialState: nil)

    init(host: String) {
        self.host = host
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        // WiiM uses a self-signed certificate. Accept it for the selected IP and pin it for this connection session.
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, space.host == host,
              let trust = space.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let data = SecCertificateCopyData(certificate) as Data
        let matches = firstCertificate.withLock { pinned in
            if let pinned { return pinned == data }
            pinned = data
            return true
        }
        if matches {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
