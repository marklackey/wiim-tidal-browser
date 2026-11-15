import SwiftUI

struct CatalogView: View {
    let player: PlayerModel
    let openSettings: () -> Void

    private var canPlay: Bool { player.canQueue }
    private var recents: [RecentPlayback] { player.recents }
    private func play(_ recent: RecentPlayback, _ tracks: [TIDALTrack]) { player.confirm(recent, tracks: tracks) }

    @Environment(\.openURL) private var openURL
    @State private var connected = false
    @State private var resolutionAvailable = false
    @State private var showingAccount = false
    @State private var deviceLogin: TIDALCatalogClient.DeviceLogin?
    @State private var loginURL: URL?
    @State private var redirect = ""
    @State private var query = ""
    @State private var kinds: Set<CatalogKind> = [.album, .artist]
    @State private var showingHistory = false
    @State private var filters = CatalogFilters()
    @State private var results: CatalogResults?
    @State private var busy: String?
    @State private var error: String?

    private var searchQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                if connected && !showingAccount {
                    searchForm
                } else {
                    loginForm
                }
                if let busy { ProgressView(busy).padding(.vertical, 8) }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(.red)
                }
                if player.address == nil {
                    Button(action: openSettings) {
                        Label("Set up your WiiM", systemImage: "hifispeaker")
                    }
                }
                if let results {
                    SearchResultsView(results: results, query: searchQuery, player: player, filters: filters)
                }
                if results == nil && !recents.isEmpty {
                    Section("Recently played") {
                        ForEach(recents) { recent in
                            switch recent {
                            case .album(let album):
                                albumLink(album).disabled(!connected)
                            case .track(let track):
                                Button { play(recent, [track]) } label: {
                                    HStack(spacing: 12) {
                                        MusicArtwork(url: track.art).frame(width: 56, height: 56)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(track.title).font(.headline).foregroundStyle(.primary)
                                            Text(track.artist).font(.subheadline).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "play.fill").font(.subheadline)
                                    }.padding(.vertical, 4)
                                }
                                .disabled(!canPlay)
                            }
                        }
                    }
                }
                if connected && results == nil && recents.isEmpty && busy == nil {
                    ContentUnavailableView("Find your next favorite", systemImage: "music.note",
                        description: Text("Search albums, tracks, and artists. Your recent listening will appear here."))
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Browse")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Albums, tracks, artists")
            .onSubmit(of: .search, search)
            .onChange(of: query) { if searchQuery.isEmpty { results = nil } }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingHistory = true } label: { Label("Listening history", systemImage: "clock.arrow.circlepath") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                if connected {
                    Menu {
                        if !showingAccount {
                            if resolutionAvailable {
                                Button("Sign in for browsing", action: beginDeviceLogin)
                                    .disabled(busy != nil)
                            } else {
                                Button("Enable Hi-Res details", action: beginHiResLogin)
                                    .disabled(busy != nil)
                            }
                        }
                        Button("Disconnect TIDAL", role: .destructive, action: disconnect)
                            .disabled(busy != nil)
                    } label: {
                        Label("TIDAL account", systemImage: "person.crop.circle")
                    }
                }
            }
            }
            .navigationDestination(isPresented: $showingHistory) { ListeningHistoryView(player: player) }
            .task {
                run("Checking TIDAL session…") { applyStatus(try await TIDALCatalogClient.status()) }
            }
            .task(id: deviceLogin?.id) {
                if let deviceLogin { await monitorDeviceLogin(deviceLogin) }
            }
        }
    }

    private var loginForm: some View {
        Section {
            if let deviceLogin {
                Link("Open TIDAL sign-in", destination: deviceLogin.url)
                ProgressView("Waiting for TIDAL approval…")
                Button("Back", action: closeLogin)
            } else if let loginURL {
                Link("Open TIDAL sign-in", destination: loginURL)
                PasteButton(payloadType: String.self) { values in redirect = values.first ?? "" }
                    .labelStyle(.titleAndIcon)
                TextField("TIDAL redirect URL", text: $redirect)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Finish login", action: finishLogin)
                    .disabled(redirect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Back", action: closeLogin)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "waveform").font(.largeTitle).foregroundStyle(MusicStyle.accent)
                    Text("Your music. Your speakers.").font(.title2.bold())
                    Text("Connect TIDAL to discover music and listen on your WiiM.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
                if !connected || resolutionAvailable {
                    Button("Connect TIDAL", action: beginDeviceLogin)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
                if !resolutionAvailable {
                    Button("Hi-Res sign-in", action: beginHiResLogin)
                }
                if showingAccount { Button("Back", action: closeLogin) }
            }
        } header: {
            Text("TIDAL account")
        } footer: {
            if deviceLogin != nil {
                Text("Approve the sign-in on TIDAL, then return here.")
            } else if loginURL != nil {
                Text("After signing in, copy the full URL of the final page from your browser and paste it here.")
            } else {
                Text("Hi-Res sign-in adds bit depth and sample rate.")
            }
        }
        .disabled(busy != nil)
    }

    private var searchForm: some View {
        Section {
            HStack(spacing: 8) {
                ForEach(CatalogKind.allCases) { kind in
                    Button {
                        if kinds.contains(kind) {
                            if kinds.count > 1 { kinds.remove(kind) }
                        } else { kinds.insert(kind) }
                        if !searchQuery.isEmpty { search() }
                    } label: {
                        Text(kind.title).font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .foregroundStyle(kinds.contains(kind) ? Color.white : Color.primary)
                            .background(kinds.contains(kind) ? MusicStyle.accent : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(kinds.contains(kind) ? .isSelected : [])
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
        .disabled(busy != nil)
    }

    private func albumLink(_ album: CatalogAlbum) -> some View {
        NavigationLink {
            AlbumView(album: album, player: player, resolutionAvailable: resolutionAvailable)
        } label: {
            HStack(spacing: 12) {
                MusicArtwork(url: album.art).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.name).font(.headline)
                    Text([album.artist, album.year.map(String.init), album.version, album.quality]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 4)
        }
    }

    private func applyStatus(_ status: TIDALCatalogClient.Status) {
        connected = status.connected
        resolutionAvailable = status.resolutionAvailable
        player.catalogConnected = status.connected
        player.resolutionAvailable = status.resolutionAvailable
    }

    private func closeLogin() {
        deviceLogin = nil
        loginURL = nil
        redirect = ""
        showingAccount = false
        error = nil
    }

    private func beginDeviceLogin() {
        showingAccount = connected
        run("Starting TIDAL sign-in…") {
            let login = try await TIDALCatalogClient.beginDeviceLogin()
            deviceLogin = login
            openURL(login.url)
        }
    }

    private func monitorDeviceLogin(_ login: TIDALCatalogClient.DeviceLogin) async {
        do {
            while true {
                try await Task.sleep(for: .seconds(1.5))
                if try await TIDALCatalogClient.checkDeviceLogin(login.id) {
                    let status = try await TIDALCatalogClient.status()
                    guard deviceLogin?.id == login.id else { return }
                    applyStatus(status)
                    closeLogin()
                    return
                }
            }
        } catch is CancellationError {
        } catch {
            guard deviceLogin?.id == login.id else { return }
            closeLogin()
            self.error = error.localizedDescription
        }
    }

    private func beginHiResLogin() {
        showingAccount = connected
        run("Starting TIDAL login…") {
            let url = try await TIDALCatalogClient.beginLogin()
            redirect = ""
            loginURL = url
            openURL(url)
        }
    }

    private func finishLogin() {
        let submittedURL = redirect.trimmingCharacters(in: .whitespacesAndNewlines)
        run("Signing in to TIDAL…") {
            applyStatus(try await TIDALCatalogClient.finishLogin(submittedURL))
            closeLogin()
        }
    }

    private func disconnect() {
        run("Disconnecting TIDAL…") {
            try await TIDALCatalogClient.disconnect()
            connected = false
            resolutionAvailable = false
            player.catalogConnected = false
            player.resolutionAvailable = false
            closeLogin()
            results = nil
        }
    }

    private func search() {
        let submittedQuery = searchQuery
        let submittedKinds = kinds
        guard connected, (1...150).contains(submittedQuery.count) else { return }
        run("Searching TIDAL…") {
            results = nil
            filters = CatalogFilters()
            let found = try await TIDALCatalogClient.search(submittedQuery, kinds: submittedKinds)
            if searchQuery == submittedQuery && kinds == submittedKinds { results = found }
        }
    }

    private func run(_ label: String, operation: @escaping @MainActor () async throws -> Void) {
        guard busy == nil else { return }
        busy = label
        error = nil
        Task { @MainActor in
            defer { busy = nil }
            do { try await operation() }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct AlbumView: View {
    let id: Int
    let seed: CatalogAlbum?
    let player: PlayerModel
    @State private var detail: CatalogAlbumDetail?
    @State private var error: String?

    init(album: CatalogAlbum, player: PlayerModel, resolutionAvailable: Bool) {
        id = album.id
        seed = album
        self.player = player
    }

    init(id: Int, player: PlayerModel) {
        self.id = id
        seed = nil
        self.player = player
    }

    private var album: CatalogAlbum? { detail?.album ?? seed }

    var body: some View {
        List {
            if let album {
                Section {
                    VStack(spacing: 14) {
                        MusicArtwork(url: album.art, cornerRadius: 16)
                            .frame(width: 230, height: 230)
                            .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
                            .padding(.bottom, 8)
                        Text(album.name).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(album.artist).font(.title3).foregroundStyle(MusicStyle.accent)
                        Text([album.year.map(String.init), album.version, album.quality,
                              detail.map { "\($0.tracks.count) tracks" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if player.resolutionAvailable { ResolutionRow(id: album.id, track: false) }
                        Button {
                            if let queue = detail?.queue { player.confirm(.album(album), tracks: queue) }
                        } label: {
                            Label("Play album", systemImage: "play.fill").font(.headline)
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!player.canQueue || detail?.queue == nil || (detail?.tracks.count ?? 0) > WiiMClient.maxQueueSize)
                        if (detail?.tracks.count ?? 0) > WiiMClient.maxQueueSize {
                            Text("This album exceeds the 100-track queue limit. You can play individual tracks.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Link("Open in TIDAL", destination: album.url).font(.subheadline)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                }.listRowBackground(Color.clear)
            }
            if let detail {
                Section("Tracks") {
                    ForEach(Array(detail.tracks.enumerated()), id: \.offset) { _, track in
                        CatalogTrackRow(track: track, art: detail.album.art, player: player,
                                        resolutionAvailable: player.resolutionAvailable, inAlbum: true)
                    }
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
            } else {
                ProgressView("Loading tracks…")
            }
        }
        .navigationTitle("Album").navigationBarTitleDisplayMode(.inline)
        .task(id: id) { await load() }
    }

    private func load() async {
        guard detail == nil else { return }
        error = nil
        do { detail = try await TIDALCatalogClient.album(id) }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}

struct CatalogTrackRow: View {
    let track: CatalogTrack
    let art: URL?
    let player: PlayerModel
    let resolutionAvailable: Bool
    var inAlbum = false

    private var isCurrent: Bool { player.nowPlaying?.trackID == String(track.id) }

    var body: some View {
        HStack(spacing: 12) {
            if inAlbum {
                Group {
                    if isCurrent { Image(systemName: "waveform").foregroundStyle(MusicStyle.accent) }
                    else { Text(track.number.map(String.init) ?? "•").foregroundStyle(.secondary) }
                }.font(.subheadline.monospacedDigit()).lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false).frame(minWidth: 24)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(track.title).font(.subheadline.weight(.semibold)).foregroundStyle(isCurrent ? MusicStyle.accent : .primary)
                Text(inAlbum ? track.artist : [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if !inAlbum && track.albumID > 0 {
                    NavigationLink("View album") { AlbumView(id: track.albumID, player: player) }
                        .font(.caption)
                }
                if resolutionAvailable { ResolutionRow(id: track.id, track: true) }
            }
            Spacer(minLength: 0)
            if let queueTrack = track.queueTrack(art: art) {
                Button { player.confirm(.track(queueTrack), tracks: [queueTrack]) } label: {
                    Image(systemName: "play.fill").font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Play \(track.title) on WiiM")
                .buttonStyle(.borderless).disabled(!player.canQueue)
            }
        }.padding(.vertical, 6)
    }
}

struct ResolutionRow: View {
    let id: Int
    let track: Bool
    @State private var label: String?
    @State private var failed = false
    @State private var loading = false

    var body: some View {
        Group {
            if let label {
                Text(label).font(.caption).foregroundStyle(.secondary)
            } else if loading {
                Text("Checking resolution…").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(failed ? "Retry resolution lookup" : "Check resolution") { Task { await load() } }
                    .font(.caption).buttonStyle(.borderless)
            }
        }
        .task(id: "\(track)-\(id)") { await load() }
    }

    private func load() async {
        guard label == nil, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let resolution = try await TIDALCatalogClient.resolution(id, track: track)
            label = resolution.label + (track ? " · catalog estimate" : " · first-track estimate")
        } catch is CancellationError {}
        catch { failed = true }
    }
}

struct ListeningHistoryView: View {
    let player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
            List {
                if player.history.isEmpty {
                    ContentUnavailableView("Your listening history", systemImage: "clock.arrow.circlepath",
                                           description: Text("Tracks and albums you play from this iPhone will appear here."))
                }
                ForEach(player.history) { entry in
                    HStack(spacing: 12) {
                        MusicArtwork(url: entry.item.art).frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.item.title).font(.headline)
                            Text(entry.item.artist).font(.subheadline).foregroundStyle(.secondary)
                            Text(entry.playedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            if let id = entry.item.albumID, id > 0 {
                                NavigationLink("View album") { AlbumView(id: id, player: player) }
                                    .font(.caption).disabled(!player.catalogConnected)
                            }
                        }
                        Spacer()
                        if case .track(let track) = entry.item {
                            Button { player.confirm(entry.item, tracks: [track]) } label: {
                                Image(systemName: "play.fill").frame(width: 44, height: 44)
                            }.buttonStyle(.borderless).disabled(!player.canQueue)
                                .accessibilityLabel("Play \(track.title)")
                        }
                    }.padding(.vertical, 4)
                }
            }
            .navigationTitle("History")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
