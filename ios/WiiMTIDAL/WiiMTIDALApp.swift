import SwiftUI

@main
struct WiiMTIDALApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

private struct ContentView: View {
    private enum Tab: String { case player, catalog, settings }
    @AppStorage("selectedTab") private var tab = Tab.catalog
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = PlayerModel.shared
    @AppStorage("lockScreenPlayerEnabled") private var lockScreenEnabled = true
    @State private var discovery = WiiMDiscovery()

    private var foregroundAddress: WiiMAddress? { scenePhase == .active ? player.address : nil }

    var body: some View {
        TabView(selection: $tab) {
            // Reserve layout space outside the navigation stack so pushed lists
            // get the same usable height as Browse, including their final row.
            VStack(spacing: 0) {
                CatalogView(player: player, openSettings: { tab = .settings })
                if player.address != nil {
                    MiniPlayer(player: player) { tab = .player }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
                .tabItem { Label("Browse", systemImage: "magnifyingglass") }
                .tag(Tab.catalog)
            PlayerView(player: player, openSettings: { tab = .settings }, browse: { tab = .catalog })
                .tabItem { Label("Player", systemImage: "play.circle.fill") }
                .tag(Tab.player)
            PlayerSettingsView(player: player, discovery: discovery, openCatalog: { tab = .catalog })
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(MusicStyle.accent)
        .onOpenURL { url in
            if url.scheme == "wiimtidal", url.host == "player" { tab = .player }
        }
        .task(id: LockScreenUpdate(nowPlaying: player.nowPlaying, address: player.address,
                                  enabled: lockScreenEnabled, foreground: scenePhase == .active)) {
            await LockScreenPlayer.shared.sync(player, allowStart: scenePhase == .active)
        }
        .sheet(item: $player.pendingQueue) { request in
            QueueCountdown(request: request) {
                guard scenePhase == .active else { return }
                Task { await player.start(request) }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active { player.pendingQueue = nil }
        }
        .task(id: foregroundAddress) {
            if let foregroundAddress { await player.maintainConnection(to: foregroundAddress) }
        }
        .task(id: scenePhase) {
            if scenePhase == .active {
                if let status = try? await TIDALCatalogClient.status() {
                    player.catalogConnected = status.connected
                    player.resolutionAvailable = status.resolutionAvailable
                }
                if player.deviceID != nil { await discovery.scan() }
            } else { discovery.stop() }
        }
        .onChange(of: discovery.devices) {
            if let device = discovery.devices.first(where: { $0.id == player.deviceID }) {
                Task { await player.rediscovered(device) }
            }
        }
        .alert("Playback couldn’t be updated", isPresented: Binding(
            get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { player.errorMessage = nil }
        } message: {
            Text(player.errorMessage ?? "")
        }
    }
}

private struct QueueCountdown: View {
    let request: PendingQueue
    let start: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var progress = 0.0

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                MusicArtwork(url: request.tracks.first?.art).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Starting playback").font(.headline)
                    Text(request.recent.title).font(.subheadline).lineLimit(2)
                }
            }
            Text("This replaces the current WiiM queue.").font(.subheadline).foregroundStyle(.secondary)
            if voiceOver {
                Button("Play now", action: start).buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                ProgressView(value: progress).tint(MusicStyle.accent)
            }
            Button("Cancel", role: .cancel) { dismiss() }
                .buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity)
        }
        .padding(24)
        }
        .task {
            guard !voiceOver else { return }
            withAnimation(reduceMotion ? nil : .linear(duration: 2)) { progress = 1 }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard !Task.isCancelled else { return }
            start()
        }
    }
}
