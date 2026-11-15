import ActivityKit
import SwiftUI
import WidgetKit

@main
struct WiiMWidgets: WidgetBundle {
    var body: some Widget { WiiMPlayerActivity() }
}

struct WiiMPlayerActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WiiMActivity.self) { context in
            WiiMLockScreenView(context: context)
                .padding(16)
                .activityBackgroundTint(Color(red: 0.07, green: 0.13, blue: 0.13))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "wiimtidal://player"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "hifispeaker.fill").foregroundStyle(.mint) }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        Text(context.state.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) { WiiMLockScreenControls(context: context) }
            } compactLeading: {
                Image(systemName: "hifispeaker.fill").foregroundStyle(.mint)
            } compactTrailing: {
                Image(systemName: context.isStale ? "arrow.clockwise" : context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(.mint)
            } minimal: {
                Image(systemName: "hifispeaker.fill").foregroundStyle(.mint)
            }
            .widgetURL(URL(string: "wiimtidal://player"))
            .keylineTint(.mint)
        }
    }
}

private struct WiiMLockScreenView: View {
    let context: ActivityViewContext<WiiMActivity>
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "hifispeaker.fill").font(.title2).foregroundStyle(.mint)
                    .frame(width: 48, height: 48).background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.title).font(.headline).lineLimit(2)
                    Text(context.state.artist).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            WiiMLockScreenControls(context: context)
            Text(context.isStale ? "Tap refresh for the current track" : "\(context.state.speaker) · \(context.state.status)")
                .font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
        }
        .foregroundStyle(.white)
    }
}

private struct WiiMLockScreenControls: View {
    let context: ActivityViewContext<WiiMActivity>
    var body: some View {
        HStack(spacing: 16) {
            control(.previous, label: "Previous track", image: "backward.end.fill")
            control(context.state.isPlaying ? .pause : .resume,
                    label: context.state.isPlaying ? "Pause WiiM" : "Play WiiM",
                    image: context.state.isPlaying ? "pause.fill" : "play.fill", prominent: true)
            control(.next, label: "Next track", image: "forward.end.fill")
            Spacer(minLength: 0)
            control(.refresh, label: "Refresh WiiM", image: "arrow.clockwise")
        }
        .buttonStyle(.plain)
    }

    private func control(_ action: WiiMLockScreenAction, label: String, image: String, prominent: Bool = false) -> some View {
        Button(intent: WiiMPlaybackIntent(sessionID: context.attributes.sessionID, action: action)) {
            Image(systemName: image).font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(prominent ? Color.black : Color.white)
                .background(prominent ? Color.mint : .white.opacity(0.08), in: Circle())
        }
        .accessibilityLabel(label)
    }
}
