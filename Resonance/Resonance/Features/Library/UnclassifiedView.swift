import SwiftUI

private struct ReleaseShadowKey: Hashable {
    let identity: String

    init(song: Song) {
        if !song.albumId.isEmpty {
            identity = "album:\(song.albumId)"
        } else {
            identity = "metadata:\(song.artistId)::\(song.artist)::\(song.album)"
        }
    }
}

private struct ReleaseShadow: Identifiable, Hashable {
    let id: String
    let album: Album
    let songs: [Song]

    var metadata: String {
        let songLabel = songs.count == 1 ? "1 song" : "\(songs.count) songs"
        return "\(songLabel) · \(Self.formattedDuration(album.duration))"
    }

    private static func formattedDuration(_ duration: Int) -> String {
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes) min"
    }
}

private enum UnclassifiedRowID: Hashable {
    case release(String)
    case song(String)
}

private enum UnclassifiedAction {
    case admit
    case stage
    case reject
}

struct UnclassifiedView: View {
    @Environment(AppState.self) private var appState

    @State private var songs: [Song] = []
    @State private var sourceAttributions: [String: SourceAttributionRecord] = [:]
    @State private var expandedReleaseIds: Set<String> = []
    @State private var selection: Set<UnclassifiedRowID> = []
    @State private var keyboardCursor: UnclassifiedRowID?
    @State private var clearedTodayCount = 0
    @State private var isLoading = true
    @State private var actionError: ResonanceError?
    @FocusState private var isListFocused: Bool

    private var releaseShadows: [ReleaseShadow] {
        Dictionary(grouping: songs, by: ReleaseShadowKey.init(song:))
            .values
            .map { groupedSongs in
                let first = groupedSongs[0]
                let sortedSongs = groupedSongs.sorted(by: releaseSort)
                let albumId = first.albumId.isEmpty
                    ? "\(first.artistId)::\(first.artist)::\(first.album)"
                    : first.albumId
                let album = Album(
                    id: albumId,
                    name: first.album.isEmpty ? "Unknown Album" : first.album,
                    artist: first.artist.isEmpty ? "Unknown Artist" : first.artist,
                    artistId: first.artistId,
                    songCount: groupedSongs.count,
                    duration: groupedSongs.reduce(0) { $0 + $1.duration },
                    year: first.year,
                    genre: first.genre,
                    coverArt: first.coverArt,
                    starred: nil,
                    rating: nil
                )
                return ReleaseShadow(id: albumId, album: album, songs: sortedSongs)
            }
            .sorted { lhs, rhs in
                if lhs.album.artist.localizedCaseInsensitiveCompare(rhs.album.artist) == .orderedSame {
                    return lhs.album.name.localizedCaseInsensitiveCompare(rhs.album.name) == .orderedAscending
                }
                return lhs.album.artist.localizedCaseInsensitiveCompare(rhs.album.artist) == .orderedAscending
            }
    }

    private var summaryText: String {
        let releaseCount = releaseShadows.count
        let releaseLabel = releaseCount == 1 ? "1 release shadow" : "\(releaseCount) release shadows"
        let songLabel = songs.count == 1 ? "1 song" : "\(songs.count) songs"
        return "\(releaseLabel) · \(songLabel)"
    }

    private var visibleRowIds: [UnclassifiedRowID] {
        releaseShadows.flatMap { shadow in
            var ids: [UnclassifiedRowID] = [.release(shadow.id)]
            if expandedReleaseIds.contains(shadow.id) {
                ids.append(contentsOf: shadow.songs.map { .song($0.id) })
            }
            return ids
        }
    }

    private var selectedSongs: [Song] {
        let shadowsById = Dictionary(uniqueKeysWithValues: releaseShadows.map { ($0.id, $0) })
        let songsById = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        var ids = Set<String>()

        for selected in selection {
            switch selected {
            case .release(let id):
                shadowsById[id]?.songs.forEach { ids.insert($0.id) }
            case .song(let id):
                ids.insert(id)
            }
        }
        return songs.filter { ids.contains($0.id) && songsById[$0.id] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let actionError {
                ErrorBanner(error: actionError) {
                    self.actionError = nil
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            if isLoading {
                loadingState
            } else if songs.isEmpty {
                CompactUnclassifiedStatusView(
                    title: "No Unclassified Media",
                    systemImage: "rectangle.dashed",
                    message: "Cached songs that are outside the library will appear here."
                )
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                dockList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .task {
            loadSongs()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unclassified")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    HStack(spacing: 10) {
                        Text(summaryText)
                        Text("Cleared today: \(clearedTodayCount)")
                            .fontWeight(.medium)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    loadSongs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }

            HStack(spacing: 8) {
                Button {
                    perform(.admit)
                } label: {
                    Label("Admit", systemImage: "checkmark.circle")
                }

                Button {
                    perform(.stage)
                } label: {
                    Label("Stage", systemImage: "tray")
                }

                Button(role: .destructive) {
                    perform(.reject)
                } label: {
                    Label("Reject", systemImage: "hand.thumbsdown")
                }

                Spacer()

                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("J/K navigate · A admit · W stage · X reject")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedSongs.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    private var selectionSummary: String {
        let count = selectedSongs.count
        return count == 1 ? "1 song selected" : "\(count) songs selected"
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading unclassified media...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dockList: some View {
        List(selection: $selection) {
            dockColumnHeader

            ForEach(releaseShadows) { shadow in
                releaseRow(shadow)
                    .tag(UnclassifiedRowID.release(shadow.id))

                if expandedReleaseIds.contains(shadow.id) {
                    ForEach(shadow.songs) { song in
                        songRow(song)
                            .tag(UnclassifiedRowID.song(song.id))
                            .contextMenu {
                                SongContextMenu(song: song)
                                Divider()
                                Button {
                                    selectAndPerform(.admit, song: song)
                                } label: {
                                    Label("Admit", systemImage: "checkmark.circle")
                                }
                                Button {
                                    selectAndPerform(.stage, song: song)
                                } label: {
                                    Label("Stage", systemImage: "tray")
                                }
                                Button(role: .destructive) {
                                    selectAndPerform(.reject, song: song)
                                } label: {
                                    Label("Reject", systemImage: "hand.thumbsdown")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.inset)
        .focused($isListFocused)
        .onAppear {
            isListFocused = true
        }
        .onChange(of: selection) { _, newSelection in
            if newSelection.count == 1 {
                keyboardCursor = newSelection.first
            }
        }
        .onKeyPress(keys: [KeyEquivalent("j")], phases: .down) { _ in
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("k")], phases: .down) { _ in
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("a")], phases: .down) { _ in
            perform(.admit)
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("w")], phases: .down) { _ in
            perform(.stage)
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("x")], phases: .down) { _ in
            perform(.reject)
            return .handled
        }
        .frame(minHeight: 240, maxHeight: .infinity)
    }

    private var dockColumnHeader: some View {
        HStack(spacing: 12) {
            Text("Artist — Album / Song")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Count · Duration")
                .frame(width: 130, alignment: .trailing)
            Text("Source")
                .frame(width: 180, alignment: .leading)
            Color.clear
                .frame(width: 24)
        }
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.vertical, 2)
        .selectionDisabled()
    }

    private func releaseRow(_ shadow: ReleaseShadow) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    toggleExpansion(shadow.id)
                } label: {
                    Image(systemName: expandedReleaseIds.contains(shadow.id)
                          ? "chevron.down"
                          : "chevron.right")
                        .font(.caption)
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)
                .help(expandedReleaseIds.contains(shadow.id) ? "Collapse release" : "Expand release")

                Text(shadow.album.artist)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("—")
                    .foregroundStyle(.tertiary)
                Text(shadow.album.name)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(shadow.metadata)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)

            Text(sourceName(for: shadow))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: 180, alignment: .leading)

            Color.clear
                .frame(width: 24)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func songRow(_ song: Song) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Color.clear
                    .frame(width: 20)

                Text(trackLabel(for: song))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)

                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(song.formattedDuration)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)

            Text(sourceName(for: song))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: 180, alignment: .leading)

            Button {
                Task {
                    await appState.playbackManager.play(songs: [song])
                }
            } label: {
                Image(systemName: "play.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .frame(width: 24)
            .help("Preview \(song.title)")
            .accessibilityLabel("Preview \(song.title)")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func loadSongs() {
        isLoading = true
        guard let serverId = appState.activeServerId else {
            songs = []
            sourceAttributions = [:]
            clearedTodayCount = 0
            isLoading = false
            return
        }

        appState.refreshLibraryMembershipIds()
        do {
            let waitingRoomSongIds = Set(
                try appState.databaseManager
                    .loadWaitingRoomItems(serverId: serverId, includeDecided: true)
                    .map { $0.song.id }
            )
            let loadedSongs = try appState.databaseManager
                .loadUnclassifiedSongs(serverId: serverId)
                .filter { !waitingRoomSongIds.contains($0.id) }
            songs = loadedSongs
            sourceAttributions = try appState.databaseManager
                .sourceAttributionsBySongId(songs: loadedSongs)
            clearedTodayCount = try appState.databaseManager
                .unclassifiedClearedTodayCount(serverId: serverId)
            pruneInteractionState()
            actionError = nil
        } catch {
            songs = []
            sourceAttributions = [:]
            actionError = resonanceError(from: error)
        }
        isLoading = false
    }

    private func refreshClearedTodayCount() {
        guard let serverId = appState.activeServerId else {
            clearedTodayCount = 0
            return
        }

        do {
            clearedTodayCount = try appState.databaseManager
                .unclassifiedClearedTodayCount(serverId: serverId)
        } catch {
            actionError = resonanceError(from: error)
        }
    }

    private func perform(_ action: UnclassifiedAction) {
        let targets = selectedSongs
        guard !targets.isEmpty else { return }

        for song in targets {
            switch action {
            case .admit:
                admitSong(song, refreshCount: false)
            case .stage:
                stageSong(song, refreshCount: false)
            case .reject:
                rejectSong(song, refreshCount: false)
            }
        }
        refreshClearedTodayCount()
        pruneInteractionState()
        isListFocused = true
    }

    private func selectAndPerform(_ action: UnclassifiedAction, song: Song) {
        selection = [.song(song.id)]
        keyboardCursor = .song(song.id)
        perform(action)
    }

    private func admitSong(_ song: Song, refreshCount: Bool = true) {
        guard let serverId = appState.activeServerId else { return }

        do {
            try appState.databaseManager.admitSongAndRelated(
                song,
                serverId: serverId,
                admittedBy: .manual,
                sourceDetail: "unclassified"
            )
            try appState.databaseManager.upsertWaitingRoomItem(
                song: song,
                serverId: serverId,
                state: .admitted,
                source: "unclassified_admit"
            )
            try appState.databaseManager.setWaitingRoomState(
                songId: song.id,
                serverId: serverId,
                state: .admitted
            )
            appState.refreshLibraryMembershipIds()
            removeSongs(withIds: [song.id])
            actionError = nil
        } catch {
            actionError = resonanceError(from: error)
        }
        if refreshCount {
            refreshClearedTodayCount()
        }
    }

    private func stageSong(_ song: Song, refreshCount: Bool = true) {
        guard let serverId = appState.activeServerId else { return }

        do {
            try appState.databaseManager.upsertWaitingRoomItem(
                song: song,
                serverId: serverId,
                state: .unheard,
                source: "unclassified"
            )
            removeSongs(withIds: [song.id])
            actionError = nil
        } catch {
            actionError = resonanceError(from: error)
        }
        if refreshCount {
            refreshClearedTodayCount()
        }
    }

    private func rejectSong(_ song: Song, refreshCount: Bool = true) {
        guard let serverId = appState.activeServerId else { return }

        do {
            try appState.databaseManager.hideItem(
                id: song.id,
                type: "song",
                serverId: serverId,
                reason: "unclassified_reject"
            )
            appState.refreshHiddenIds()
            removeSongs(withIds: [song.id])
            actionError = nil
        } catch {
            actionError = resonanceError(from: error)
        }
        if refreshCount {
            refreshClearedTodayCount()
        }
    }

    private func removeSongs(withIds ids: Set<String>) {
        songs.removeAll { ids.contains($0.id) }
        ids.forEach { sourceAttributions.removeValue(forKey: $0) }
    }

    private func moveSelection(by offset: Int) {
        let rows = visibleRowIds
        guard !rows.isEmpty else { return }

        let current = keyboardCursor.flatMap { rows.firstIndex(of: $0) }
            ?? rows.firstIndex(where: selection.contains)
        let nextIndex: Int
        if let current {
            nextIndex = min(max(current + offset, 0), rows.count - 1)
        } else {
            nextIndex = offset < 0 ? rows.count - 1 : 0
        }

        let next = rows[nextIndex]
        selection = [next]
        keyboardCursor = next
    }

    private func toggleExpansion(_ releaseId: String) {
        if expandedReleaseIds.contains(releaseId) {
            expandedReleaseIds.remove(releaseId)
        } else {
            expandedReleaseIds.insert(releaseId)
        }
        isListFocused = true
    }

    private func pruneInteractionState() {
        let releaseIds = Set(releaseShadows.map(\.id))
        let songIds = Set(songs.map(\.id))
        selection = selection.filter { row in
            switch row {
            case .release(let id):
                return releaseIds.contains(id)
            case .song(let id):
                return songIds.contains(id)
            }
        }
        expandedReleaseIds.formIntersection(releaseIds)
        if let keyboardCursor, !visibleRowIds.contains(keyboardCursor) {
            self.keyboardCursor = nil
        }
    }

    private func sourceName(for song: Song) -> String {
        guard let name = sourceAttributions[song.id]?.sourceDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else { return "—" }
        return name
    }

    private func sourceName(for shadow: ReleaseShadow) -> String {
        let names = shadow.songs.map(sourceName(for:)).filter { $0 != "—" }
        guard let first = names.first else { return "—" }

        let counts = names.reduce(into: [String: Int]()) { counts, name in
            counts[name, default: 0] += 1
        }
        return names.first { counts[$0] == counts.values.max() } ?? first
    }

    private func trackLabel(for song: Song) -> String {
        let track = song.track.map(String.init) ?? "—"
        guard let disc = song.discNumber, disc > 1 else { return track }
        return "\(disc).\(track)"
    }

    private func resonanceError(from error: Error) -> ResonanceError {
        if let resonanceError = error as? ResonanceError {
            return resonanceError
        }
        return .unknown(error)
    }

    private func releaseSort(_ lhs: Song, _ rhs: Song) -> Bool {
        let lhsDisc = lhs.discNumber ?? 0
        let rhsDisc = rhs.discNumber ?? 0
        if lhsDisc != rhsDisc {
            return lhsDisc < rhsDisc
        }

        let lhsTrack = lhs.track ?? Int.max
        let rhsTrack = rhs.track ?? Int.max
        if lhsTrack != rhsTrack {
            return lhsTrack < rhsTrack
        }

        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}

private struct CompactUnclassifiedStatusView: View {
    let title: String
    let systemImage: String
    let message: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
    }
}

#Preview {
    UnclassifiedView()
        .environment(AppState())
}
