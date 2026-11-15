import Foundation
import Observation

struct PendingQueue: Identifiable {
    let id = UUID()
    let address: WiiMAddress
    let recent: RecentPlayback
    let tracks: [TIDALTrack]
}

struct SubmittedQueue: Codable {
    let host: String
    let port: Int
    let title: String
    let tracks: [TIDALTrack]
}

@MainActor @Observable
final class PlayerModel {
    static let shared = PlayerModel()
    enum Connection { case unconfigured, connecting, connected, reconnecting }

    private(set) var address: WiiMAddress?
    private(set) var deviceID: String?
    private(set) var deviceName = "WiiM"
    private(set) var connection: Connection = .unconfigured
    private(set) var nowPlaying: NowPlaying?
    private(set) var recents: [RecentPlayback] = []
    private(set) var submittedQueue: SubmittedQueue?
    private(set) var history: [ListeningHistory] = []
    var catalogConnected = false
    var resolutionAvailable = false
    private(set) var operation: String?
    var pendingQueue: PendingQueue?
    var errorMessage: String?
    var notice: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeClient: (WiiMAddress) -> any WiiMTransport
    @ObservationIgnored private var client: (any WiiMTransport)?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var latestRefresh = UUID()

    init(defaults: UserDefaults = .standard,
         makeClient: @escaping (WiiMAddress) -> any WiiMTransport = { WiiMClient(address: $0) }) {
        self.defaults = defaults
        self.makeClient = makeClient
        address = WiiMAddress(host: defaults.string(forKey: "wiimHost") ?? "",
                              queuePort: defaults.string(forKey: "wiimQueuePort") ?? "49152",
                              queuePath: defaults.string(forKey: "wiimQueuePath") ?? "/upnp/control/PlayQueue1")
        deviceID = defaults.string(forKey: "wiimDeviceID")
        deviceName = defaults.string(forKey: "wiimDeviceName") ?? "WiiM"
        connection = address == nil ? .unconfigured : .connecting
        recents = defaults.data(forKey: "wiimRecents").flatMap {
            try? JSONDecoder().decode([RecentPlayback].self, from: $0)
        } ?? []
        history = defaults.data(forKey: "wiimHistory").flatMap {
            try? JSONDecoder().decode([ListeningHistory].self, from: $0)
        } ?? []
        submittedQueue = defaults.data(forKey: "wiimSubmittedQueue").flatMap {
            try? JSONDecoder().decode(SubmittedQueue.self, from: $0)
        }
        if submittedQueue?.host != address?.host || submittedQueue?.port != address?.queuePort {
            submittedQueue = nil
        }
    }

    var canQueue: Bool { address != nil && operation == nil && pendingQueue == nil }
    var canControl: Bool { connection == .connected && nowPlaying != nil && operation == nil && pendingQueue == nil }
    var isPlaying: Bool { nowPlaying?.isPlaying == true }
    var connectionLabel: String {
        switch connection {
        case .unconfigured: return "Set up your WiiM"
        case .connecting: return "Connecting to WiiM…"
        case .connected: return "Connected to \(deviceName)"
        case .reconnecting: return "Reconnecting to WiiM…"
        }
    }
    var matchingTrack: TIDALTrack? {
        guard let id = nowPlaying?.trackID else { return nil }
        return submittedQueue?.tracks.first { $0.id == id }
    }
    var title: String { nowPlaying?.title ?? matchingTrack?.title ?? "Ready when you are" }
    var artist: String { nowPlaying?.artist ?? matchingTrack?.artist ?? "Choose something to play on WiiM" }
    var artwork: URL? { nowPlaying?.art ?? matchingTrack?.art }

    func select(_ address: WiiMAddress, deviceID: String? = nil, name: String = "WiiM") async {
        guard operation == nil else { return }
        revision += 1
        pendingQueue = nil
        errorMessage = nil
        notice = nil
        if self.address != address {
            nowPlaying = nil
            submittedQueue = nil
            defaults.removeObject(forKey: "wiimSubmittedQueue")
        }
        self.address = address
        self.deviceID = deviceID
        deviceName = name
        defaults.set(address.host, forKey: "wiimHost")
        defaults.set(String(address.queuePort), forKey: "wiimQueuePort")
        defaults.set(address.queuePath, forKey: "wiimQueuePath")
        defaults.set(deviceID, forKey: "wiimDeviceID")
        defaults.set(name, forKey: "wiimDeviceName")
        client = makeClient(address)
        connection = .connecting
        await refresh()
    }

    func rediscovered(_ device: DiscoveredWiiM) async {
        guard operation == nil, device.id == deviceID, let address = device.address,
              self.address != address else { return }
        await select(address, deviceID: device.id, name: device.name)
    }

    /// The owning view cancels this task in the background and restarts it on activation.
    func maintainConnection(to address: WiiMAddress) async {
        while !Task.isCancelled, self.address == address {
            if operation == nil && pendingQueue == nil { await refresh() }
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
        }
    }

    func refresh() async {
        guard let address, operation == nil else { return }
        let player = transport(for: address)
        let snapshot = revision
        let refreshID = UUID()
        latestRefresh = refreshID
        do {
            let status = try await player.nowPlaying()
            guard !Task.isCancelled, self.address == address, snapshot == revision, latestRefresh == refreshID else { return }
            nowPlaying = status
            connection = .connected
        } catch {
            guard !Task.isCancelled, self.address == address, snapshot == revision, latestRefresh == refreshID else { return }
            markUnavailable()
        }
    }

    func confirm(_ recent: RecentPlayback, tracks: [TIDALTrack]) {
        guard let address, canQueue, (1...WiiMClient.maxQueueSize).contains(tracks.count) else { return }
        errorMessage = nil
        pendingQueue = PendingQueue(address: address, recent: recent, tracks: tracks)
    }

    func start(_ request: PendingQueue) async {
        guard address == request.address, pendingQueue?.id == request.id, operation == nil else { return }
        pendingQueue = nil
        await perform("Starting playback…") { player in
            let tracks = self.catalogConnected
                ? try await TIDALCatalogClient.queueTracks(request.tracks.map(\.id)) : request.tracks
            guard tracks.count == request.tracks.count else { throw WiiMError.invalidResponse }
            try await player.play(tracks)
            self.submittedQueue = SubmittedQueue(host: request.address.host, port: request.address.queuePort,
                                                title: request.recent.title, tracks: tracks)
            self.recents = Array(([request.recent] + self.recents.filter { $0.id != request.recent.id }).prefix(100))
            self.history = Array(([ListeningHistory(id: UUID(), playedAt: Date(), item: request.recent)] + self.history).prefix(100))
            if let data = try? JSONEncoder().encode(self.recents) { self.defaults.set(data, forKey: "wiimRecents") }
            if let data = try? JSONEncoder().encode(self.history) { self.defaults.set(data, forKey: "wiimHistory") }
            if let data = try? JSONEncoder().encode(self.submittedQueue) { self.defaults.set(data, forKey: "wiimSubmittedQueue") }
            // Avoid showing the previous track while WiiM resolves the new queue.
            let first = tracks[0]
            self.nowPlaying = NowPlaying(title: first.title, artist: first.artist, album: first.album,
                                         status: "loading", volume: self.nowPlaying?.volume, trackID: first.id, art: first.art)
            self.notice = "Playing on WiiM"
            try await Task.sleep(for: .milliseconds(700))
        }
    }

    func togglePlayback() async {
        let command: PlayerCommand
        switch nowPlaying?.status?.lowercased() {
        case "play", "playing": command = .pause
        case "pause", "paused", "stop", "stopped": command = .resume
        default: command = .toggle
        }
        await control(command)
    }

    func control(_ command: PlayerCommand) async {
        guard canControl else { return }
        await perform("Updating playback…") { player in
            try await player.control(command)
            // Reflect acknowledged commands immediately, then reconcile with the device.
            if var now = self.nowPlaying {
                now.position = now.elapsed(at: Date())
                now.sampledAt = Date()
                switch command {
                case .pause: now.status = "pause"
                case .resume: now.status = "play"
                case .toggle: now.status = now.isPlaying ? "pause" : "play"
                case .seek(let seconds): now.position = Double(max(0, seconds))
                case .volume(let volume): now.volume = min(100, max(0, volume))
                case .previous, .next: break
                }
                self.nowPlaying = now
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    private func perform(_ label: String, action: (any WiiMTransport) async throws -> Void) async {
        guard let address, operation == nil else { return }
        revision += 1 // Invalidate a status poll that began before this command.
        operation = label
        errorMessage = nil
        notice = nil
        let player = transport(for: address)
        defer { operation = nil }
        do {
            try await action(player)
            do {
                let status = try await player.nowPlaying()
                nowPlaying = status
                connection = .connected
            } catch { markUnavailable() }
        } catch is CancellationError {
        } catch {
            if error is URLError { markUnavailable() }
            errorMessage = Self.message(for: error)
        }
    }

    private func transport(for address: WiiMAddress) -> any WiiMTransport {
        if let client, client.address == address { return client }
        let newClient = makeClient(address)
        client = newClient
        return newClient
    }

    private func markUnavailable() {
        // Retain artwork during a brief outage, but freeze progress and disable stale controls.
        if var now = nowPlaying {
            now.position = now.elapsed(at: Date())
            now.sampledAt = Date()
            now.status = nil
            nowPlaying = now
        }
        connection = .reconnecting
    }

    private static func message(for error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .appTransportSecurityRequiresSecureConnection:
                return "iOS blocked the local WiiM connection. Check Local Network access in Settings."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot:
                return "Couldn’t establish a secure connection to WiiM. Reconnect in Settings."
            default:
                return "Couldn’t reach WiiM. Check Wi-Fi and Local Network access in Settings. We’ll keep trying to reconnect."
            }
        }
        return error.localizedDescription
    }
}
