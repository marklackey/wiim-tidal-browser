import SwiftUI

// Semantic backgrounds support both appearances and increased contrast.
enum MusicStyle {
    static let accent = Color(red: 0.05, green: 0.47, blue: 0.36)
    static let background = Color(uiColor: .systemGroupedBackground)
}

struct MusicArtwork: View {
    let url: URL?
    var cornerRadius: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(LinearGradient(colors: [Color.teal.opacity(0.28), Color.indigo.opacity(0.18)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                GeometryReader { geometry in
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "music.note")
                            .font(.system(size: max(20, geometry.size.width * 0.26), weight: .light))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .accessibilityHidden(true)
    }
}

struct ConnectionBadge: View {
    let player: PlayerModel

    var body: some View {
        Label(player.connectionLabel, systemImage: player.connection == .connected ? "hifispeaker.fill" : "wifi")
            .font(.caption.weight(.medium))
            .foregroundStyle(player.connection == .connected ? MusicStyle.accent : .secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(MusicStyle.accent.opacity(0.08), in: Capsule())
    }
}

struct PlayerView: View {
    let player: PlayerModel
    let openSettings: () -> Void
    let browse: () -> Void
    @State private var showingQueue = false
    @State private var showingAlbum = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    Button(action: openSettings) { ConnectionBadge(player: player) }.buttonStyle(.plain)
                    MusicArtwork(url: player.artwork, cornerRadius: 18)
                        .aspectRatio(1, contentMode: .fit).frame(maxWidth: min(310, max(180, geometry.size.height * 0.34)))
                        .shadow(color: .black.opacity(0.12), radius: 20, y: 12)
                        .padding(.bottom, 4)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(player.title).font(.title2.bold()).textSelection(.enabled)
                            .accessibilityIdentifier("player.title")
                        HStack(alignment: .firstTextBaseline) {
                            Text(player.artist).font(.title3).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if player.connection == .connected, let now = player.nowPlaying {
                                Text(now.playbackLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let album = player.nowPlaying?.album, !album.isEmpty {
                            Text(album).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if player.resolutionAvailable, let id = player.nowPlaying?.trackID.flatMap(Int.init), id > 0 {
                            ResolutionRow(id: id, track: true).id(id)
                        }
                        if let rate = player.nowPlaying?.bitrate, let value = Double(rate), value > 0 {
                            Text("WiiM bitrate · \(rate)\(player.nowPlaying?.bitrateUnit.map { " " + $0 } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if player.nowPlaying != nil {
                            Text("Bitrate not reported by WiiM").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if player.nowPlaying != nil {
                        PlaybackProgress(player: player)
                        HStack(spacing: 40) {
                            transportButton("Previous track", icon: "backward.end.fill", command: .previous)
                            PlayPauseButton(player: player, prominent: true)
                            transportButton("Next track", icon: "forward.end.fill", command: .next)
                        }
                        .frame(maxWidth: .infinity)
                        if player.nowPlaying?.volume != nil { PlayerVolume(player: player).padding(.top, 4) }
                        HStack {
                            Button { showingAlbum = true } label: {
                                Label("Album tracks", systemImage: "opticaldisc").font(.subheadline.weight(.medium))
                            }
                            .disabled(!player.catalogConnected || player.nowPlaying?.trackID == nil)
                            Spacer()
                            Button { showingQueue = true } label: {
                                Label("Queue", systemImage: "list.bullet")
                                    .font(.subheadline.weight(.semibold)).padding(.vertical, 10)
                            }
                            .disabled(player.submittedQueue == nil)
                        }
                    } else {
                        Text(player.address == nil ? "Connect your WiiM to listen on your speakers." : "Browse TIDAL or start music in WiiM Home.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button(action: player.address == nil ? openSettings : browse) {
                            Label(player.address == nil ? "Set up WiiM" : "Find your music",
                                  systemImage: player.address == nil ? "hifispeaker" : "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    if player.connection == .reconnecting {
                        Label("We’ll reconnect automatically. Check that your iPhone and WiiM are on the same Wi-Fi.", systemImage: "wifi.exclamationmark")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 16)
                .frame(maxWidth: 480).frame(maxWidth: .infinity)
            }
            .background(MusicStyle.background)
            .navigationTitle("Now Playing").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: openSettings) { Label("Player settings", systemImage: "ellipsis.circle") }
                }
            }
            .refreshable { await player.refresh() }
            .sheet(isPresented: $showingQueue) { SubmittedQueueView(player: player) }
            .navigationDestination(isPresented: $showingAlbum) { CurrentAlbumView(player: player) }
            }
        }
    }

    private func transportButton(_ label: String, icon: String, command: PlayerCommand) -> some View {
        Button { Task { await player.control(command) } } label: {
            Image(systemName: icon).font(.system(size: 26, weight: .semibold)).frame(width: 48, height: 48)
        }
        .tint(.primary).disabled(!player.canControl)
        .accessibilityLabel(label)
        .keyboardShortcut(command == .previous ? .leftArrow : .rightArrow, modifiers: [])
    }
}

struct PlayPauseButton: View {
    let player: PlayerModel
    var prominent = false

    var body: some View {
        Button { Task { await player.togglePlayback() } } label: {
            ZStack {
                if prominent { Circle().fill(MusicStyle.accent) }
                if player.nowPlaying?.isLoading == true || player.operation != nil {
                    ProgressView().tint(prominent ? .white : .primary)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: prominent ? 30 : 22, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }
            .foregroundStyle(prominent ? .white : .primary)
            .frame(width: prominent ? 76 : 48, height: prominent ? 76 : 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!player.canControl || player.nowPlaying?.isLoading == true)
        .opacity(player.canControl ? 1 : 0.5)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier(prominent ? "player.playPause" : "miniPlayer.playPause")
        .keyboardShortcut(.space, modifiers: [])
    }
}

struct MiniPlayer: View {
    let player: PlayerModel
    let expand: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: expand) {
                HStack(spacing: 12) {
                    MusicArtwork(url: player.artwork).frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.nowPlaying == nil ? "Your WiiM" : player.title)
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(player.connection == .connected ? player.artist : player.connectionLabel)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityHint("Opens Now Playing")
            PlayPauseButton(player: player)
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.06), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }
}

private struct PlaybackProgress: View {
    let player: PlayerModel
    @State private var scrubPosition: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = player.nowPlaying?.duration ?? 0
            let position = min(duration, scrubPosition ?? player.nowPlaying?.elapsed(at: context.date) ?? 0)
            VStack(spacing: 2) {
                Slider(value: Binding(get: { position }, set: { scrubPosition = $0 }), in: 0...max(1, duration)) { editing in
                    if !editing, let position = scrubPosition {
                        Task {
                            await player.control(.seek(Int(position)))
                            scrubPosition = nil
                        }
                    }
                }
                .disabled(!player.canControl || duration <= 0 || player.nowPlaying?.position == nil)
                .accessibilityLabel("Track position")
                .accessibilityValue("\(playbackTime(position)) of \(playbackTime(duration))")
                .accessibilityIdentifier("player.progress")
                HStack {
                    Text(duration > 0 ? playbackTime(position) : "—:—")
                    Spacer()
                    Text(duration > 0 ? "−" + playbackTime(max(0, duration - position)) : "—:—")
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .onChange(of: player.nowPlaying?.trackID) { scrubPosition = nil }
        .onChange(of: player.connection) { scrubPosition = nil }
    }
}

private struct PlayerVolume: View {
    let player: PlayerModel
    @State private var draft: Double?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: Binding(get: { draft ?? Double(player.nowPlaying?.volume ?? 0) }, set: { draft = $0 }), in: 0...100, step: 1) { editing in
                if !editing, let draft {
                    Task {
                        await player.control(.volume(Int(draft)))
                        self.draft = nil
                    }
                }
            }
            .disabled(!player.canControl)
            .accessibilityLabel("WiiM volume")
            .accessibilityValue("\(Int(draft ?? Double(player.nowPlaying?.volume ?? 0))) percent")
            .accessibilityIdentifier("player.volume")
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .font(.subheadline)
        .onChange(of: player.connection) { draft = nil }
    }
}

private struct SubmittedQueueView: View {
    let player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let queue = player.submittedQueue {
                    Section {
                        ForEach(Array(queue.tracks.enumerated()), id: \.offset) { index, track in
                            HStack(spacing: 12) {
                                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
                                MusicArtwork(url: track.art).frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.title).font(.subheadline.weight(.medium))
                                    Text(track.artist).font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 3)
                        }
                    } header: { Text(queue.title) } footer: {
                        Text("Last queue sent from this iPhone. Changes made in WiiM Home or another app may differ.")
                    }
                }
            }
            .navigationTitle("Sent to WiiM").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct PlayerSettingsView: View {
    let player: PlayerModel
    let discovery: WiiMDiscovery
    let openCatalog: () -> Void
    @State private var host = ""
    @State private var port = "49152"
    @State private var trackInput = ""
    @AppStorage("lockScreenPlayerEnabled") private var lockScreenEnabled = true
    @FocusState private var editing: Bool
    @Environment(\.openURL) private var openURL

    private var address: WiiMAddress? {
        WiiMAddress(host: host, queuePort: port,
                    queuePath: host == player.address?.host && Int(port) == player.address?.queuePort
                        ? player.address!.queuePath : "/upnp/control/PlayQueue1")
    }
    private var track: TIDALTrack? { TIDALTrack(trackInput) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ConnectionBadge(player: player).listRowBackground(Color.clear)
                }
                Section {
                    Label(player.catalogConnected ? "TIDAL connected" : "Connect your TIDAL account",
                          systemImage: player.catalogConnected ? "checkmark.circle.fill" : "person.crop.circle")
                    Button(player.catalogConnected ? "Manage TIDAL in Browse" : "Connect TIDAL", action: openCatalog)
                } header: { Text("Music account") } footer: {
                    Text("Approve sign-in on TIDAL and return to the app. Optional Hi-Res sign-in adds bit depth and sample rate.")
                }
                Section {
                    Button {
                        editing = false
                        Task { await discovery.scan() }
                    } label: {
                        Label("Discover WiiM", systemImage: "dot.radiowaves.left.and.right")
                    }.disabled(discovery.searching)
                    if discovery.searching { ProgressView("Looking for speakers…") }
                    ForEach(discovery.devices) { device in
                        Button {
                            guard let address = device.address else { return }
                            host = address.host
                            port = String(address.queuePort)
                            Task { await player.select(address, deviceID: device.id, name: device.name) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name).foregroundStyle(.primary)
                                    Text(device.host).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if player.deviceID == device.id { Image(systemName: "checkmark.circle.fill") }
                            }
                        }.disabled(player.operation != nil)
                    }
                    if let message = discovery.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Nearby speakers") }
                Section {
                    TextField("WiiM IP address", text: $host)
                        .keyboardType(.decimalPad).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().focused($editing)
                        .accessibilityIdentifier("settings.host")
                    DisclosureGroup("Advanced") {
                        LabeledContent("Queue port") {
                            TextField("49152", text: $port).keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing).focused($editing)
                        }
                    }
                    Button(address == player.address ? "Reconnect" : "Connect") {
                        guard let address else { return }
                        editing = false
                        Task {
                            await player.select(address, deviceID: address == player.address ? player.deviceID : nil,
                                                name: address == player.address ? player.deviceName : "WiiM")
                        }
                    }
                    .disabled(address == nil || player.operation != nil)
                } header: { Text("Your speaker") } footer: {
                    Text(host.isEmpty || address != nil
                         ? "Find the IP address in WiiM Home → Device settings → Network. Your iPhone and WiiM must be on the same Wi-Fi."
                         : "Enter a private IPv4 address and a queue port between 1 and 65535.")
                }
                Section {
                    Label("Reconnects when you return", systemImage: "arrow.triangle.2.circlepath")
                    Text("While the app is open, it keeps checking your WiiM and recovers after a connection loss.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Open iOS app settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } header: { Text("Connection") }
                Section {
                    Toggle("Lock Screen player", isOn: $lockScreenEnabled)
                    if let message = LockScreenPlayer.shared.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Lock Screen") } footer: {
                    Text("Shows playback controls while music is playing. iOS may ask for Face ID. Tap refresh to update track details while the app is in the background.")
                }
                Section {
                    TextField("TIDAL track link or ID", text: $trackInput)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($editing)
                    Button {
                        if let track {
                            editing = false
                            player.confirm(.track(track), tracks: [track])
                        }
                    } label: { Label("Play on WiiM", systemImage: "play.fill") }
                    .disabled(track == nil || !player.canQueue)
                } header: { Text("Play a link") } footer: {
                    Text("WiiM uses the TIDAL account signed in through WiiM Home. Connect TIDAL in Browse to search for music.")
                }
            }
            .navigationTitle("Settings")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = false } }
            }
            .onAppear {
                host = player.address?.host ?? ""
                port = String(player.address?.queuePort ?? WiiMAddress.defaultQueuePort)
            }
        }
    }
}

private func playbackTime(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    return "\(total / 60):" + String(format: "%02d", total % 60)
}

private struct CurrentAlbumView: View {
    let player: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var albumID: Int?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
            Group {
                if let albumID { AlbumView(id: albumID, player: player).id(albumID) }
                else if let error {
                    ContentUnavailableView {
                        Label("Album unavailable", systemImage: "opticaldisc")
                    } description: { Text(error) } actions: { Button("Retry") { retry += 1 } }
                } else { ProgressView("Loading current album…") }
            }
            .navigationTitle("Album tracks").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: "\(player.nowPlaying?.trackID ?? "")-\(retry)") {
                albumID = nil
                error = nil
                guard let id = player.nowPlaying?.trackID.flatMap(Int.init), id > 0 else {
                    error = "WiiM hasn’t reported a TIDAL track."; return
                }
                do {
                    let track = try await TIDALCatalogClient.track(id)
                    try Task.checkCancellation()
                    if track.albumID > 0 { albumID = track.albumID }
                    else { error = "This track has no album details." }
                } catch is CancellationError {}
                catch { self.error = error.localizedDescription }
            }
    }
}
