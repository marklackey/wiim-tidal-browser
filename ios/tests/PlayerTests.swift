import XCTest
@testable import WiiMTIDAL

private final class MockPlayer: WiiMTransport {
    let address: WiiMAddress
    var status = NowPlaying(title: "First track", artist: "Artist", album: "Album", status: "play", volume: 25,
                            trackID: "123", position: 30, duration: 240)
    var commands: [PlayerCommand] = []
    var queued: [String] = []
    var failControl = false
    var failStatus = false
    var failQueue = false
    var deferredRead: CheckedContinuation<NowPlaying, Error>?
    var deferNextRead = false

    init(_ host: String = "192.168.1.20") { address = WiiMAddress(host: host, queuePort: "49152")! }
    func nowPlaying() async throws -> NowPlaying {
        if deferNextRead {
            deferNextRead = false
            return try await withCheckedThrowingContinuation { deferredRead = $0 }
        }
        if failStatus { throw URLError(.notConnectedToInternet) }
        return status
    }
    func control(_ command: PlayerCommand) async throws {
        if failControl { throw WiiMError.controlRejected }
        commands.append(command)
        switch command {
        case .pause: status.status = "pause"
        case .resume: status.status = "play"
        case .seek(let value): status.position = Double(value)
        case .volume(let value): status.volume = value
        default: break
        }
    }
    func play(_ tracks: [TIDALTrack]) async throws {
        if failQueue { throw WiiMError.queueRejected }
        queued = tracks.map(\.id)
    }
}

final class PlayerTests: XCTestCase {
    @MainActor private func model(_ mock: MockPlayer) -> PlayerModel {
        let defaults = UserDefaults(suiteName: "PlayerTests.\(UUID())")!
        defaults.set(mock.address.host, forKey: "wiimHost")
        return PlayerModel(defaults: defaults, makeClient: { _ in mock })
    }

    @MainActor func testPauseChangesToPlayAndResumesSameQueue() async {
        let mock = MockPlayer()
        let model = model(mock)
        await model.refresh()
        XCTAssertTrue(model.isPlaying)
        await model.togglePlayback()
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.nowPlaying?.playbackLabel, "Paused")
        await model.togglePlayback()
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(mock.commands, [.pause, .resume])
        XCTAssertTrue(mock.queued.isEmpty)
    }

    @MainActor func testLockScreenReconnectsAndControlsWithoutReplacingQueue() async throws {
        let mock = MockPlayer()
        let model = model(mock)
        // A cold background launch begins without a connected UI.
        try await LockScreenPlayer.control(.pause, player: model)
        XCTAssertFalse(model.isPlaying)
        try await LockScreenPlayer.control(.pause, player: model)
        XCTAssertFalse(model.isPlaying, "A stale Pause button must never resume playback.")
        try await LockScreenPlayer.control(.resume, player: model)
        XCTAssertTrue(model.isPlaying)
        model.errorMessage = "Previous connection failed"
        try await LockScreenPlayer.control(.refresh, player: model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(mock.commands, [.pause, .pause, .resume])
        XCTAssertTrue(mock.queued.isEmpty)
    }

    @MainActor func testLockScreenDoesNotSendCommandsWhenUnavailableOrQueuePending() async {
        let mock = MockPlayer()
        let model = model(mock)
        mock.failStatus = true
        do { try await LockScreenPlayer.control(.next, player: model); XCTFail("Must fail when offline") }
        catch {}
        XCTAssertTrue(mock.commands.isEmpty)
        mock.failStatus = false
        await model.refresh()
        let track = TIDALTrack("123")!
        model.confirm(.track(track), tracks: [track])
        do { try await LockScreenPlayer.control(.pause, player: model); XCTFail("Must not interrupt queue confirmation") }
        catch {}
        XCTAssertTrue(mock.commands.isEmpty)
        XCTAssertNotNil(model.pendingQueue)
    }

    @MainActor func testLockScreenReportsRejectedCommandWithoutFalsePlaybackState() async {
        let mock = MockPlayer()
        let model = model(mock)
        mock.failControl = true
        do { try await LockScreenPlayer.control(.pause, player: model); XCTFail("Must report failure") }
        catch {}
        let state = LockScreenPlayer.state(for: model)
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.title, "First track")
        XCTAssertTrue(state.status.contains("tap refresh"))
    }

    @MainActor func testFailedCommandKeepsStateAndReportsFailure() async {
        let mock = MockPlayer()
        let model = model(mock)
        await model.refresh()
        mock.failControl = true
        await model.togglePlayback()
        XCTAssertTrue(model.isPlaying)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.canControl)
    }

    @MainActor func testStalePollCannotUndoPause() async {
        let mock = MockPlayer()
        let model = model(mock)
        await model.refresh()
        mock.deferNextRead = true
        let poll = Task { await model.refresh() }
        while mock.deferredRead == nil { await Task.yield() }
        let old = mock.status
        await model.togglePlayback()
        mock.deferredRead?.resume(returning: old)
        await poll.value
        XCTAssertEqual(model.nowPlaying?.status, "pause")
    }

    @MainActor func testOutageFreezesProgressAndRecovers() async {
        let mock = MockPlayer()
        let model = model(mock)
        await model.refresh()
        mock.failStatus = true
        await model.refresh()
        XCTAssertEqual(model.connection, .reconnecting)
        XCTAssertFalse(model.canControl)
        XCTAssertTrue(model.canQueue)
        XCTAssertFalse(model.isPlaying)
        let frozen = model.nowPlaying!.elapsed(at: .now)
        XCTAssertEqual(model.nowPlaying!.elapsed(at: Date().addingTimeInterval(5)), frozen)
        mock.failStatus = false
        await model.refresh()
        XCTAssertEqual(model.connection, .connected)
        XCTAssertTrue(model.canControl)
    }

    @MainActor func testSeekVolumeAndSkipUseTransportCommands() async {
        let mock = MockPlayer()
        let model = model(mock)
        await model.refresh()
        for command: PlayerCommand in [.seek(120), .volume(33), .previous, .next] { await model.control(command) }
        XCTAssertEqual(mock.commands, [.seek(120), .volume(33), .previous, .next])
        XCTAssertEqual(model.nowPlaying?.position, 120)
        XCTAssertEqual(model.nowPlaying?.volume, 33)
    }

    @MainActor func testHistoryIsWrittenOnlyAfterQueueAcceptanceAndKeepsRepeats() async {
        let mock = MockPlayer()
        let model = model(mock)
        let track = TIDALTrack("123", title: "Song")!
        mock.failQueue = true
        model.confirm(.track(track), tracks: [track])
        await model.start(model.pendingQueue!)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertTrue(model.recents.isEmpty)
        mock.failQueue = false
        for _ in 0..<2 {
            model.confirm(.track(track), tracks: [track, track])
            await model.start(model.pendingQueue!)
        }
        XCTAssertEqual(mock.queued, ["123", "123"])
        XCTAssertEqual(model.history.count, 2)
        XCTAssertEqual(model.recents.count, 1)
    }

    @MainActor func testCancelledCountdownCannotStartQueue() async {
        let mock = MockPlayer()
        let model = model(mock)
        let track = TIDALTrack("123")!
        model.confirm(.track(track), tracks: [track])
        let pending = model.pendingQueue!
        model.pendingQueue = nil
        await model.start(pending)
        XCTAssertTrue(mock.queued.isEmpty)
    }

    @MainActor func testOldDeviceResponseCannotReplaceNewSelection() async {
        let old = MockPlayer()
        let new = MockPlayer("192.168.1.21")
        new.status = NowPlaying(title: "New device", artist: nil, album: nil, status: "pause", volume: 10)
        let model = PlayerModel(defaults: UserDefaults(suiteName: "PlayerTests.\(UUID())")!,
                                makeClient: { $0 == old.address ? old : new })
        await model.select(old.address)
        old.deferNextRead = true
        let poll = Task { await model.refresh() }
        while old.deferredRead == nil { await Task.yield() }
        await model.select(new.address)
        old.deferredRead?.resume(returning: old.status)
        await poll.value
        XCTAssertEqual(model.title, "New device")
    }

    func testElapsedTimeAndQualityNormalization() {
        let date = Date()
        var now = NowPlaying(title: nil, artist: nil, album: nil, status: "play", volume: nil,
                             position: 239, duration: 240, sampledAt: date)
        XCTAssertEqual(now.elapsed(at: date.addingTimeInterval(8)), 240)
        now.status = "pause"
        XCTAssertEqual(now.elapsed(at: date.addingTimeInterval(8)), 239)
        XCTAssertEqual(catalogQualityTier("LOSSLESS", tags: ["HIRES_LOSSLESS"]), 0)
        XCTAssertEqual(catalogQualityTier("LOSSLESS"), 1)
        XCTAssertEqual(catalogQualityTier("HIGH"), 2)
    }

    func testDiscoveryRejectsForeignControlURLs() {
        let device = DiscoveredWiiM(id: "uuid:test", name: "WiiM", host: "192.168.1.20",
                                   url: URL(string: "http://192.168.1.21:49152/upnp/control/PlayQueue1")!)
        XCTAssertNil(device.address)
        XCTAssertNil(WiiMAddress(host: "127.0.0.1", queuePort: "49152"))
        XCTAssertNil(WiiMAddress(host: "192.168.1.20", queuePort: "0"))
    }
}

private final class MockHTTP: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            let result: (Int, Data)
            do { result = try Self.handler!(request); Self.lock.unlock() }
            catch { Self.lock.unlock(); throw error }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class TransportTests: XCTestCase {
    private func client() -> WiiMClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTTP.self]
        return WiiMClient(address: WiiMAddress(host: "192.168.1.20", queuePort: "49152")!, configuration: configuration)
    }

    func testStatusParsesMillisecondsArtworkAndBitrate() async throws {
        MockHTTP.handler = { request in
            let command = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
            let json = command == "getMetaInfo"
                ? #"{"metaData":{"title":"Music","artist":"Artist","trackId":"123","albumArtURI":"https://example.com/art.jpg","bitRate":"4567"}}"#
                : #"{"status":"pause","vol":"25","curpos":"90000","totlen":"240000"}"#
            return (200, Data(json.utf8))
        }
        let now = try await client().nowPlaying()
        XCTAssertEqual(now.position, 90)
        XCTAssertEqual(now.duration, 240)
        XCTAssertEqual(now.playbackLabel, "Paused")
        XCTAssertEqual(now.art?.scheme, "https")
        XCTAssertEqual(now.bitrate, "4567")
    }

    func testStatusFallbackWorksWithoutMetadataAndRejectsInvalidNumbers() async throws {
        MockHTTP.handler = { request in
            let command = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
            let reply = command == "getPlayerStatus" ? #"{"status":"play","vol":"120","curpos":"NaN","totlen":"-1"}"# : "unsupported"
            return (200, Data(reply.utf8))
        }
        let now = try await client().nowPlaying()
        XCTAssertTrue(now.isPlaying)
        XCTAssertNil(now.volume)
        XCTAssertNil(now.position)
        XCTAssertNil(now.duration)
    }

    func testResumeUsesDeviceResumeCommand() async throws {
        var command: String?
        MockHTTP.handler = { request in
            command = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
            return (200, Data("OK".utf8))
        }
        try await client().control(.resume)
        XCTAssertEqual(command, "setPlayerCmd:resume")
        XCTAssertEqual(PlayerCommand.volume(150).value, "vol:100")
        XCTAssertEqual(PlayerCommand.seek(-1).value, "seek:0")
    }
}
