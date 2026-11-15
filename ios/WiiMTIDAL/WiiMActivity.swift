import ActivityKit
import AppIntents
import Foundation

struct WiiMActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var speaker: String
        var isPlaying: Bool
        var status: String
        var updatedAt: Date
    }

    let sessionID: String
    let host: String
    let port: Int
}

enum WiiMLockScreenAction: String, AppEnum {
    case pause, resume, previous, next, refresh

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "WiiM control"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .pause: "Pause", .resume: "Play", .previous: "Previous", .next: "Next", .refresh: "Refresh"
    ]
}

// LiveActivityIntent runs in the containing app, including when it is backgrounded.
// The extension only needs the declaration to encode its buttons' actions.
struct WiiMPlaybackIntent: LiveActivityIntent, AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Control WiiM"
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @Parameter(title: "Session") var sessionID: String
    @Parameter(title: "Control") var action: WiiMLockScreenAction

    init() {}
    init(sessionID: String, action: WiiMLockScreenAction) {
        self.sessionID = sessionID
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        try await LockScreenPlayer.shared.perform(action, sessionID: sessionID)
        #endif
        return .result()
    }
}
