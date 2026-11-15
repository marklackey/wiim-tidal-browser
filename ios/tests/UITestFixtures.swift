// Injected only into a disposable test copy by prepare_project.py. Never shipped.
import Foundation
import UIKit

final class UITestFixtures {
    static var enabled: Bool { ProcessInfo.processInfo.environment["WIIM_UI_TEST"] != nil }
    static var mode: String { ProcessInfo.processInfo.environment["WIIM_UI_TEST"] ?? "" }
    static let lock = NSLock()
    static var playing = true
    static var position = 30
    static var volume = 25
    static var trackID = 123
    static var reads = 0
    static var approved = false
    static var loginChecks = 0
    static var artwork: URL?
    static var longAlbum: Bool { mode.hasPrefix("longAlbum") }

    static func configure() {
        guard enabled else { return }
        let defaults = UserDefaults.standard
        defaults.set("192.168.254.253", forKey: "wiimHost")
        defaults.set("49152", forKey: "wiimQueuePort")
        defaults.removeObject(forKey: "wiimDeviceID")
        defaults.removeObject(forKey: "wiimRecents")
        defaults.removeObject(forKey: "wiimHistory")
        defaults.removeObject(forKey: "wiimSubmittedQueue")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600))
        let image = renderer.image { context in
            UIColor(red: 0.12, green: 0.22, blue: 0.24, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            for i in 0..<14 {
                UIColor(red: 0.25 + Double(i) * 0.03, green: 0.47 + Double(i) * 0.02, blue: 0.46, alpha: 1).setStroke()
                let path = UIBezierPath(ovalIn: CGRect(x: -150 + i * 22, y: 110 + i * 16, width: 680, height: 460))
                path.lineWidth = 12
                path.stroke()
            }
            ("EVENING\nLINES" as NSString).draw(at: CGPoint(x: 42, y: 35), withAttributes: [.font: UIFont.systemFont(ofSize: 50, weight: .black), .foregroundColor: UIColor.white])
            ("MIRA VALE" as NSString).draw(at: CGPoint(x: 42, y: 525), withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: UIColor.white])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-art.png")
        try? image.pngData()?.write(to: url)
        artwork = url
        let track = TIDALTrack("123", title: "Evening Lines", artist: "Mira Vale", album: "Evening Lines", art: url, albumID: 10)!
        let queue = SubmittedQueue(host: "192.168.254.253", port: 49152, title: "Evening Lines", tracks: [track])
        defaults.set(try? JSONEncoder().encode(queue), forKey: "wiimSubmittedQueue")
    }

    static func album(_ id: Int = 10) -> [String: Any] {
        ["id": id, "name": id == 10 ? "Evening Lines" : "Early Light", "artist": "Mira Vale", "year": id == 10 ? 2024 : 2020,
         "releaseDate": id == 10 ? "2024-04-01" : "2020-02-01", "quality": id == 10 ? "Hi-Res Lossless" : "LOSSLESS",
         "art": artwork?.absoluteString ?? "", "tags": id == 10 ? ["HIRES_LOSSLESS"] : ["LOSSLESS"]]
    }
    static func track(_ id: Int = 123) -> [String: Any] {
        ["id": id, "title": id == 123 ? "Evening Lines" : "Second track", "artist": "Mira Vale", "album": "Evening Lines",
         "album_id": 10, "number": id == 123 ? 1 : 2, "quality": "Hi-Res Lossless", "year": 2024]
    }
    static func catalog(_ action: String, _ parameters: [String: Any]) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let value: Any
        switch action {
        case "status": value = ["connected": mode != "login" || approved, "resolutionAvailable": longAlbum]
        case "begin_device_login": value = ["id": "test-attempt", "url": "https://link.tidal.com/test"]
        case "check_device_login": loginChecks += 1; approved = loginChecks > 1; value = ["connected": approved]
        case "begin_login": value = ["url": "https://login.tidal.com/test"]
        case "finish_login": value = ["connected": true, "resolutionAvailable": true]
        case "disconnect": value = ["connected": false, "resolutionAvailable": false]
        case "search": value = ["albums": [album()], "artistAlbums": [album(11)], "tracks": [track(), track(124)]]
        case "album":
            let tracks = longAlbum ? (1...12).map { number -> [String: Any] in
                var item = track(122 + number)
                item["number"] = number
                item["title"] = number == 12 ? "The Final Song (After the Lights Go Out)" : "Album track \(number)"
                return item
            } : [track(), track(124)]
            value = ["album": album(), "tracks": tracks]
        case "track": value = track(parameters["id"] as? Int ?? 123)
        case "resolution": value = ["bits": 24, "hz": 96000]
        case "queue_tracks":
            value = (parameters["ids"] as? [String] ?? []).map { id in
                ["id": id, "title": id == "123" ? "Evening Lines" : "Second track", "artist": "Mira Vale",
                 "album": "Evening Lines", "art": artwork?.absoluteString ?? "", "number": 1] as [String: Any]
            }
        default: value = ["device": NSNull()]
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
}

final class UITestHTTP: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "192.168.254.253" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        UITestFixtures.lock.lock()
        let command = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
        var reply = "OK"
        var failure = false
        switch command {
        case "getPlayerStatusEx", "getPlayerStatus":
            UITestFixtures.reads += 1
            failure = UITestFixtures.mode == "reconnect" && UITestFixtures.reads == 1
            reply = "{\"status\":\"\(UITestFixtures.playing ? "play" : "pause")\",\"vol\":\(UITestFixtures.volume),\"curpos\":\(UITestFixtures.position * 1000),\"totlen\":240000}"
        case "getMetaInfo":
            let info: [String: Any] = ["metaData": ["title": UITestFixtures.trackID == 123 ? "Evening Lines" : "Second track",
                "artist": "Mira Vale", "album": "Evening Lines", "trackId": String(UITestFixtures.trackID),
                "albumArtURI": "", "bitRate": "2845", "bitrateUnit": "kbps"]]
            reply = String(data: try! JSONSerialization.data(withJSONObject: info), encoding: .utf8)!
        case "setPlayerCmd:pause": UITestFixtures.playing = false
        case "setPlayerCmd:resume": UITestFixtures.playing = true
        case "setPlayerCmd:next": UITestFixtures.trackID = 124
        case "setPlayerCmd:prev": UITestFixtures.trackID = 123
        case let value where value.hasPrefix("setPlayerCmd:vol:"): UITestFixtures.volume = Int(value.split(separator: ":").last!)!
        case let value where value.hasPrefix("setPlayerCmd:seek:"): UITestFixtures.position = Int(value.split(separator: ":").last!)!
        case "":
            reply = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:CreateQueueResponse xmlns:u=\"urn:schemas-wiimu-com:service:PlayQueue:1\"/></s:Body></s:Envelope>"
            UITestFixtures.playing = true
        default: break
        }
        UITestFixtures.lock.unlock()
        if failure { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
