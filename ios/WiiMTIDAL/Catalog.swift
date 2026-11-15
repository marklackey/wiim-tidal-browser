import Foundation

struct CatalogAlbum: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let artist: String
    let year: Int?
    let version: String?
    let quality: String
    let art: URL?
    var releaseDate: String? = nil
    var tags: [String]? = nil

    var qualityTier: Int { catalogQualityTier(quality, tags: tags ?? []) }
    var url: URL { URL(string: "https://tidal.com/browse/album/\(id)")! }
}

struct CatalogTrack: Decodable, Identifiable {
    let id: Int
    let title: String
    let artist: String
    let album: String
    let albumID: Int
    let number: Int?
    let quality: String
    var releaseDate: String? = nil
    var year: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, number, quality, releaseDate, year
        case albumID = "album_id"
    }

    func queueTrack(art: URL? = nil) -> TIDALTrack? {
        TIDALTrack(String(id), title: title, artist: artist, album: album, number: number, art: art, albumID: albumID)
    }
    var qualityTier: Int { catalogQualityTier(quality) }
}

struct CatalogResults: Decodable {
    let albums: [CatalogAlbum]
    let artistAlbums: [CatalogAlbum]
    let tracks: [CatalogTrack]
}

struct CatalogAlbumDetail: Decodable {
    let album: CatalogAlbum
    let tracks: [CatalogTrack]

    var queue: [TIDALTrack]? {
        let tracksToPlay = tracks.compactMap { $0.queueTrack(art: album.art) }
        return tracksToPlay.count == tracks.count && !tracksToPlay.isEmpty ? tracksToPlay : nil
    }
}

struct CatalogResolution: Decodable {
    let bits: Int
    let hz: Int

    var label: String {
        "\(bits)-bit / \((Double(hz) / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz"
    }
}

enum CatalogKind: String, CaseIterable, Identifiable {
    case album, track, artist

    var id: Self { self }
    var title: String { rawValue.capitalized + "s" }
}

func catalogQualityTier(_ quality: String, tags: [String] = []) -> Int {
    let labels = ([quality] + tags).map { $0.uppercased().filter { $0.isLetter || $0.isNumber } }
    if labels.contains(where: { ["HIRES", "HIRESLOSSLESS"].contains($0) }) { return 0 }
    if labels.contains("LOSSLESS") { return 1 }
    if labels.contains(where: { ["HIGH", "LOW", "AAC", "MP3"].contains($0) }) { return 2 }
    return 3
}

struct ListeningHistory: Codable, Identifiable {
    let id: UUID
    let playedAt: Date
    let item: RecentPlayback
}

enum RecentPlayback: Codable, Identifiable {
    case album(CatalogAlbum)
    case track(TIDALTrack)

    var id: String {
        switch self {
        case .album(let album): return "album:\(album.id)"
        case .track(let track): return "track:\(track.id)"
        }
    }

    var title: String {
        switch self {
        case .album(let album): return album.name
        case .track(let track): return track.title
        }
    }

    var artist: String {
        switch self {
        case .album(let album): return album.artist
        case .track(let track): return track.artist
        }
    }

    var art: URL? {
        switch self {
        case .album(let album): return album.art
        case .track(let track): return track.art
        }
    }

    var albumID: Int? {
        switch self {
        case .album(let album): return album.id
        case .track(let track): return track.albumID
        }
    }
}

enum TIDALCatalogClient {
    private struct DeviceProbe: Decodable { let device: DiscoveredWiiM? }
    struct Status: Decodable {
        let connected: Bool
        let resolutionAvailable: Bool
    }

    struct DeviceLogin: Decodable {
        let id: String
        let url: URL
    }

    private struct DeviceLoginStatus: Decodable { let connected: Bool }
    private struct LoginLink: Decodable { let url: URL }
    private struct Failure: Decodable, LocalizedError {
        let error: String
        var errorDescription: String? { error }
    }

    private static let worker = DispatchQueue(label: "org.wiimtidal.catalog", qos: .userInitiated)
    @MainActor private static var resolutions: [String: CatalogResolution] = [:]
    @MainActor private static var resolutionRequests: [String: Task<CatalogResolution, Error>] = [:]

    static func status() async throws -> Status {
        try await call("status", as: Status.self)
    }

    static func probeDevice(host: String, port: Int) async throws -> DiscoveredWiiM? {
        try await call("probe_device", ["host": host, "port": port], as: DeviceProbe.self).device
    }

    static func beginDeviceLogin() async throws -> DeviceLogin {
        try await call("begin_device_login", as: DeviceLogin.self)
    }

    static func checkDeviceLogin(_ id: String) async throws -> Bool {
        try await call("check_device_login", ["id": id], as: DeviceLoginStatus.self).connected
    }

    static func beginLogin() async throws -> URL {
        try await call("begin_login", as: LoginLink.self).url
    }

    @MainActor static func finishLogin(_ redirect: String) async throws -> Status {
        let status = try await call("finish_login", ["redirect": redirect], as: Status.self)
        resolutions = [:]
        return status
    }

    @MainActor static func disconnect() async throws {
        _ = try await call("disconnect", as: Status.self)
        resolutions = [:]
        resolutionRequests.values.forEach { $0.cancel() }
        resolutionRequests = [:]
    }

    static func search(_ query: String, kinds: Set<CatalogKind>) async throws -> CatalogResults {
        try await call("search", ["query": query, "types": kinds.map(\.rawValue).sorted()], as: CatalogResults.self)
    }

    static func album(_ id: Int) async throws -> CatalogAlbumDetail {
        try await call("album", ["id": id], as: CatalogAlbumDetail.self)
    }

    static func track(_ id: Int) async throws -> CatalogTrack {
        try await call("track", ["id": id], as: CatalogTrack.self)
    }

    static func queueTracks(_ ids: [String]) async throws -> [TIDALTrack] {
        try await call("queue_tracks", ["ids": ids], as: [TIDALTrack].self)
    }

    @MainActor static func resolution(_ id: Int, track: Bool) async throws -> CatalogResolution {
        let key = "\(track)-\(id)"
        if let cached = resolutions[key] { return cached }
        if let request = resolutionRequests[key] { return try await request.value }
        let request = Task {
            try await call("resolution", ["id": id, "track": track], as: CatalogResolution.self)
        }
        resolutionRequests[key] = request
        defer { resolutionRequests[key] = nil }
        let value = try await request.value
        resolutions[key] = value
        return value
    }

    private static func call<Result: Decodable>(_ action: String, _ parameters: [String: Any] = [:],
                                                as resultType: Result.Type) async throws -> Result {
        let request = try JSONSerialization.data(withJSONObject: parameters)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            worker.async {
                do {
                    let applicationSupport = try FileManager.default.url(for: .applicationSupportDirectory,
                        in: .userDomainMask, appropriateFor: nil, create: true)
                    var directory = applicationSupport.appending(path: "TIDAL", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try directory.setResourceValues(values)
                    guard let response = ReadTIDALCatalog(action, request, directory.path) else {
                        throw Failure(error: "The TIDAL catalog could not start.")
                    }
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        if let failure = try? decoder.decode(Failure.self, from: data) { throw failure }
        return try decoder.decode(resultType, from: data)
    }
}
