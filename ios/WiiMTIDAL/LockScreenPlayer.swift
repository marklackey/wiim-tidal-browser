import ActivityKit
import Foundation
import Observation
import UIKit

struct LockScreenUpdate: Equatable {
    let nowPlaying: NowPlaying?
    let address: WiiMAddress?
    let enabled: Bool
    let foreground: Bool
}

@MainActor @Observable
final class LockScreenPlayer {
    static let shared = LockScreenPlayer()
    private(set) var message: String?
    @ObservationIgnored private var current: Activity<WiiMActivity>?
    @ObservationIgnored private var dismissed = false
    @ObservationIgnored private var performing = false

    static func state(for player: PlayerModel) -> WiiMActivity.ContentState {
        .init(title: String(player.title.prefix(160)), artist: String(player.artist.prefix(160)),
              speaker: String(player.deviceName.prefix(80)), isPlaying: player.isPlaying,
              status: player.errorMessage != nil ? "Couldn’t update WiiM · tap refresh"
                : player.connection == .connected ? player.nowPlaying?.playbackLabel ?? "Ready"
                : "WiiM unavailable · tap refresh",
              updatedAt: player.nowPlaying?.sampledAt ?? Date())
    }

    func sync(_ player: PlayerModel, allowStart: Bool) async {
        let enabled = UserDefaults.standard.object(forKey: "lockScreenPlayerEnabled") as? Bool ?? true
        if !enabled {
            dismissed = false
            await endAll()
            message = nil
            return
        }
        if current?.activityState == .dismissed { dismissed = true; current = nil }
        if current?.activityState == .ended { current = nil }
        guard let address = player.address else { await endAll(); return }
        for activity in Activity<WiiMActivity>.activities
            where activity.attributes.host != address.host || activity.attributes.port != address.queuePort {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard !Task.isCancelled, player.address == address,
              UserDefaults.standard.object(forKey: "lockScreenPlayerEnabled") as? Bool ?? true else { return }
        if current?.attributes.host != address.host || current?.attributes.port != address.queuePort {
            current = nil
        }
        current = current ?? Activity<WiiMActivity>.activities.first {
            $0.attributes.host == address.host && $0.attributes.port == address.queuePort
                && $0.activityState != .ended && $0.activityState != .dismissed
        }
        guard let now = player.nowPlaying else { return }
        if ["stop", "stopped"].contains(now.status?.lowercased() ?? "") {
            await endAll()
            return
        }
        let remaining = now.isPlaying ? max(1, (now.duration ?? 60) - now.elapsed(at: Date())) : 60
        let content = ActivityContent(state: Self.state(for: player), staleDate: Date().addingTimeInterval(min(60, remaining)))
        if let current {
            await current.update(content)
        } else if allowStart && player.isPlaying && !dismissed {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                message = "Allow Live Activities in iOS Settings to show the lock-screen player."
                return
            }
            do {
                current = try Activity.request(attributes: WiiMActivity(sessionID: UUID().uuidString,
                    host: address.host, port: address.queuePort), content: content, pushType: nil)
                message = nil
            } catch {
                message = "The lock-screen player couldn’t start. Reopen the app and try again."
            }
        }
    }

    func perform(_ action: WiiMLockScreenAction, sessionID: String) async throws {
        guard !performing else { throw LockScreenError.busy }
        let player = PlayerModel.shared
        guard (UserDefaults.standard.object(forKey: "lockScreenPlayerEnabled") as? Bool ?? true),
              let activity = Activity<WiiMActivity>.activities.first(where: { $0.attributes.sessionID == sessionID }),
              let address = player.address,
              activity.attributes.host == address.host, activity.attributes.port == address.queuePort else {
            throw LockScreenError.changedSpeaker
        }
        performing = true
        defer { performing = false }
        do {
            try await Self.control(action, player: player)
            await sync(player, allowStart: false)
        } catch {
            await sync(player, allowStart: false)
            throw error
        }
    }

    static func control(_ action: WiiMLockScreenAction, player: PlayerModel) async throws {
        guard player.operation == nil, player.pendingQueue == nil else { throw LockScreenError.busy }
        // Fetch authoritative state after suspension before issuing any command.
        player.errorMessage = nil
        await player.refresh()
        guard player.canControl else { throw LockScreenError.unavailable }
        switch action {
        case .pause: await player.control(.pause)
        case .resume: await player.control(.resume)
        case .previous: await player.control(.previous)
        case .next: await player.control(.next)
        case .refresh: break
        }
        if player.errorMessage != nil { throw LockScreenError.unavailable }
    }

    private func endAll() async {
        for activity in Activity<WiiMActivity>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
        current = nil
    }
}

private enum LockScreenError: LocalizedError {
    case busy, unavailable, changedSpeaker
    var errorDescription: String? {
        switch self {
        case .busy: return "WiiM is processing another command. Try again in a moment."
        case .unavailable: return "Couldn’t reach WiiM. Check Wi-Fi, then tap refresh."
        case .changedSpeaker: return "The selected speaker changed. Open WiiM TIDAL to reconnect."
        }
    }
}
