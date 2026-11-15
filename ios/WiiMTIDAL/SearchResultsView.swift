import SwiftUI

@Observable final class CatalogFilters {
    var artist = ""
    var album = ""
    var hiResOnly = false
    var collapsed: Set<String> = []
}

struct SearchRecord: Identifiable {
    let album: CatalogAlbum?
    let track: CatalogTrack?
    var id: String { album.map { "album:\($0.id)" } ?? "track:\(track!.id)" }
    var artist: String { album?.artist ?? track!.artist }
    var albumName: String { album?.name ?? track!.album }
    var tier: Int { album?.qualityTier ?? track!.qualityTier }
    var date: String { album?.releaseDate ?? track?.releaseDate ?? (album?.year ?? track?.year).map(String.init) ?? "" }
    var title: String { album?.name ?? track!.title }
    var number: Int { track?.number ?? 0 }

    static func chronological(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.date.isEmpty != rhs.date.isEmpty { return !lhs.date.isEmpty }
        for (left, right) in [(lhs.date, rhs.date), (lhs.albumName, rhs.albumName)] where left != right {
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        if lhs.number != rhs.number { return lhs.number < rhs.number }
        if lhs.title != rhs.title { return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }
}

struct SearchResultsView: View {
    let results: CatalogResults
    let query: String
    let player: PlayerModel
    @Bindable var filters: CatalogFilters
    @State private var showingFilters = false
    private let tiers = ["Hi-Res Lossless", "Lossless", "Compressed", "Unknown"]

    private var categories: [(key: String, title: String, records: [SearchRecord])] {
        [("artist", "Artist matches", results.artistAlbums.map { SearchRecord(album: $0, track: nil) }),
         ("album", "Album matches", results.albums.map { SearchRecord(album: $0, track: nil) }),
         ("track", "Track matches", results.tracks.map { SearchRecord(album: nil, track: $0) })]
    }
    private var all: [SearchRecord] { categories.flatMap(\.records) }
    private var filtered: [SearchRecord] { all.filter(matches) }
    private var artists: [String] {
        Array(Set(all.filter { !filters.hiResOnly || $0.tier == 0 }.map(\.artist))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var albums: [String] {
        Array(Set(all.filter { (!filters.hiResOnly || $0.tier == 0) && (filters.artist.isEmpty || $0.artist == filters.artist) }.map(\.albumName)))
            .filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var isFiltered: Bool { !filters.artist.isEmpty || !filters.album.isEmpty || filters.hiResOnly }

    var body: some View {
        Section {
            HStack {
                Text(isFiltered ? "\(filtered.count) of \(all.count) matches" : "\(all.count) matches")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button { showingFilters = true } label: {
                    Label("Filters", systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }.font(.subheadline).buttonStyle(.borderless)
                Menu {
                    Button("Expand groups") { filters.collapsed = [] }
                    Button("Collapse groups") { filters.collapsed = Set(categories.map(\.key)) }
                } label: { Label("View options", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
            }
            if isFiltered {
                Button("Clear filters") { filters.artist = ""; filters.album = ""; filters.hiResOnly = false }
                    .font(.subheadline)
            }
        }
        .listRowBackground(Color.clear)
        .sheet(isPresented: $showingFilters) {
            NavigationStack {
                Form {
                    Toggle("Hi-Res only", isOn: $filters.hiResOnly)
                    Picker("Artist", selection: $filters.artist) {
                        Text("All artists").tag("")
                        ForEach(artists, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Album", selection: $filters.album) {
                        Text("All albums").tag("")
                        ForEach(albums, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Clear filters") { filters.artist = ""; filters.album = ""; filters.hiResOnly = false }
                }
                .navigationTitle("Filter results").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingFilters = false } } }
            }
            .presentationDetents([.medium, .large])
            .onChange(of: filters.hiResOnly) { normalizeFilters() }
            .onChange(of: filters.artist) { normalizeFilters() }
        }
        if filtered.isEmpty {
            ContentUnavailableView(isFiltered ? "No matches with these filters" : "No matches found", systemImage: "magnifyingglass",
                                   description: Text(isFiltered ? "Clear filters to see all results." : "Try another search or category."))
                .listRowBackground(Color.clear)
        }
        ForEach(categories, id: \.key) { category in
            let records = category.records.filter(matches)
            if !records.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: expansion(category.key)) {
                        ForEach(0..<4, id: \.self) { tier in
                            let tierRecords = records.filter { $0.tier == tier }
                            if !tierRecords.isEmpty {
                                DisclosureGroup(isExpanded: expansion("\(category.key)-\(tier)")) {
                                    artistGroups(tierRecords, prefix: "\(category.key)-\(tier)")
                                } label: {
                                    Text("\(tiers[tier]) · \(tierRecords.count)").font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                    } label: {
                        Text("\(category.title) · \(records.count)").font(.headline)
                    }
                }
            }
        }
    }

    private func artistGroups(_ records: [SearchRecord], prefix: String) -> some View {
        let grouped = Dictionary(grouping: records, by: { $0.artist.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let keys = grouped.keys.sorted {
            if ($0 == normalized) != ($1 == normalized) { return $0 == normalized }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
        return ForEach(keys, id: \.self) { key in
            let items = grouped[key]!.sorted(by: SearchRecord.chronological)
            DisclosureGroup(isExpanded: expansion("\(prefix)-\(key)")) {
                ForEach(items) { record in
                    if let album = record.album {
                        VStack(alignment: .leading, spacing: 6) {
                            NavigationLink {
                                AlbumView(album: album, player: player, resolutionAvailable: player.resolutionAvailable)
                            } label: {
                                HStack(spacing: 10) {
                                    MusicArtwork(url: album.art).frame(width: 54, height: 54)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(album.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                        Text([album.year.map(String.init), album.version].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if let tags = album.tags, !tags.isEmpty {
                                            Text(tags.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            if player.resolutionAvailable { ResolutionRow(id: album.id, track: false) }
                        }.padding(.vertical, 7)
                    } else if let track = record.track {
                        CatalogTrackRow(track: track, art: nil, player: player, resolutionAvailable: player.resolutionAvailable)
                    }
                }
            } label: { Text("\(items[0].artist) · \(items.count)").font(.subheadline) }
        }
    }

    private func matches(_ record: SearchRecord) -> Bool {
        (filters.artist.isEmpty || record.artist == filters.artist) && (filters.album.isEmpty || record.albumName == filters.album) && (!filters.hiResOnly || record.tier == 0)
    }
    private func expansion(_ key: String) -> Binding<Bool> {
        Binding(get: { !filters.collapsed.contains(key) }, set: { if $0 { filters.collapsed.remove(key) } else { filters.collapsed.insert(key) } })
    }
    private func normalizeFilters() {
        if !artists.contains(filters.artist) { filters.artist = "" }
        if !albums.contains(filters.album) { filters.album = "" }
    }
}
