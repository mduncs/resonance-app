import SwiftUI

// MARK: - Get Info Content Types

enum GetInfoContent: Identifiable {
    case song(Song)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)

    var id: String {
        switch self {
        case .song(let song): return "song-\(song.id)"
        case .album(let album): return "album-\(album.id)"
        case .artist(let artist): return "artist-\(artist.id)"
        case .playlist(let playlist): return "playlist-\(playlist.id)"
        }
    }

    var title: String {
        switch self {
        case .song(let song): return song.title
        case .album(let album): return album.name
        case .artist(let artist): return artist.name
        case .playlist(let playlist): return playlist.name
        }
    }

    var coverArtId: String? {
        switch self {
        case .song(let song): return song.coverArt
        case .album(let album): return album.coverArt
        case .artist(let artist): return artist.coverArt
        case .playlist(let playlist): return playlist.coverArt
        }
    }
}

// MARK: - Get Info View

struct GetInfoView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let content: GetInfoContent

    @State private var fetcherSnapshot: FetcherContractSnapshot?
    @State private var dossier: DossierStory?
    @State private var areDetailsExpanded: Bool

    init(content: GetInfoContent) {
        self.content = content
        _areDetailsExpanded = State(initialValue: {
            switch content {
            case .song, .album:
                return false
            case .artist, .playlist:
                return true
            }
        }())
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with artwork and title
            header
                .padding()
                .background(.bar)

            Divider()

            // Dossier testimony followed by demoted metadata
            Form {
                if let dossier {
                    DossierSection(dossier: dossier)
                }

                if !fetcherEvidence.isEmpty {
                    FetcherSourceVoicesSection(evidenceRows: fetcherEvidence)
                }

                DisclosureGroup("Details", isExpanded: $areDetailsExpanded) {
                    switch content {
                    case .song(let song):
                        SongInfoSection(song: song)
                    case .album(let album):
                        AlbumInfoSection(album: album)
                    case .artist(let artist):
                        ArtistInfoSection(artist: artist)
                    case .playlist(let playlist):
                        PlaylistInfoSection(playlist: playlist)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            // Footer with close button
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(.bar)
        }
        .frame(minWidth: 460, idealWidth: 460, minHeight: 500)
        .task(id: content.id) {
            loadDossier()
            loadFetcherSnapshotIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            EnvironmentAlbumArtView(coverArtId: content.coverArtId, size: .medium)

            VStack(alignment: .leading, spacing: 4) {
                Text(content.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)

                switch content {
                case .song(let song):
                    Text(song.artist)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text(song.album)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                case .album(let album):
                    Text(album.artist)
                        .font(.body)
                        .foregroundStyle(.secondary)
                case .artist(let artist):
                    Text("\(artist.albumCount) albums")
                        .font(.body)
                        .foregroundStyle(.secondary)
                case .playlist(let playlist):
                    Text(playlist.owner)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("\(playlist.songCount) songs")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
    }

    private var fetcherEvidence: [FetcherSongSourceEvidence] {
        guard case .song(let song) = content else { return [] }
        return fetcherSnapshot?.songSourceEvidence(forNavidromeSongId: song.id) ?? []
    }

    private func loadDossier() {
        dossier = nil

        guard let serverId = appState.activeServerId else { return }

        switch content {
        case .song(let song):
            dossier = try? appState.databaseManager.dossierStory(
                songId: song.id,
                songPath: song.path,
                albumId: song.albumId,
                serverId: serverId
            )
        case .album(let album):
            dossier = try? appState.databaseManager.dossierStory(
                albumId: album.id,
                serverId: serverId
            )
        case .artist, .playlist:
            break
        }
    }

    private func loadFetcherSnapshotIfNeeded() {
        fetcherSnapshot = nil

        guard case .song = content,
              UserDefaults.standard.bool(forKey: FetcherContractSettings.isEnabledKey),
              let directory = FetcherContractLoader().configuredDirectory() else { return }

        fetcherSnapshot = try? FetcherContractLoader().loadSnapshot(from: directory)
    }
}

// MARK: - Song Info Section

private struct SongInfoSection: View {
    let song: Song

    var body: some View {
        Section("Track Information") {
            InfoRow(label: "Title", value: song.title)
            InfoRow(label: "Artist", value: song.artist)
            InfoRow(label: "Album", value: song.album)

            if let track = song.track {
                InfoRow(label: "Track Number", value: "\(track)")
            }

            if let discNumber = song.discNumber, discNumber > 0 {
                InfoRow(label: "Disc Number", value: "\(discNumber)")
            }

            if let year = song.year {
                InfoRow(label: "Year", value: "\(year)")
            }

            if let genre = song.genre {
                InfoRow(label: "Genre", value: genre)
            }
        }

        Section("Audio") {
            InfoRow(label: "Duration", value: song.formattedDuration)

            if let bitRate = song.bitRate {
                InfoRow(label: "Bit Rate", value: "\(bitRate) kbps")
            }

            InfoRow(label: "Format", value: song.suffix.uppercased())
            InfoRow(label: "Content Type", value: song.contentType)
        }

        Section("Library") {
            if let rating = song.rating, rating > 0 {
                InfoRow(label: "Rating", value: String(repeating: "\u{2605}", count: rating))
            }

            if song.starred != nil {
                InfoRow(label: "Loved", value: "Yes")
            }

            if song.isExplicit {
                InfoRow(label: "Explicit", value: "Yes")
            }
        }

        if let replayGain = song.replayGain, hasReplayGainData(replayGain) {
            Section("Replay Gain") {
                if let trackGain = replayGain.trackGain {
                    InfoRow(label: "Track Gain", value: String(format: "%.2f dB", trackGain))
                }
                if let albumGain = replayGain.albumGain {
                    InfoRow(label: "Album Gain", value: String(format: "%.2f dB", albumGain))
                }
                if let trackPeak = replayGain.trackPeak {
                    InfoRow(label: "Track Peak", value: String(format: "%.6f", trackPeak))
                }
                if let albumPeak = replayGain.albumPeak {
                    InfoRow(label: "Album Peak", value: String(format: "%.6f", albumPeak))
                }
            }
        }
    }

    private func hasReplayGainData(_ rg: ReplayGain) -> Bool {
        rg.trackGain != nil || rg.albumGain != nil || rg.trackPeak != nil || rg.albumPeak != nil
    }
}

private struct FetcherSourceVoicesSection: View {
    let evidenceRows: [FetcherSongSourceEvidence]

    var body: some View {
        Section("Sources") {
            ForEach(evidenceRows.prefix(5)) { evidence in
                VStack(alignment: .leading, spacing: 4) {
                    Text(evidence.collectionDisplayName)
                        .font(.callout)
                        .fontWeight(.medium)

                    if let sourceKind = evidence.sourceKindDisplayName {
                        Text(sourceKind)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Text(sourceTestimony(for: evidence))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 3)
            }

            if evidenceRows.count > 5 {
                Text("\(evidenceRows.count - 5) more Fetcher source matches are hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Read-only Fetcher evidence. This does not create Library membership.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func sourceTestimony(for evidence: FetcherSongSourceEvidence) -> String {
        var sentences = ["\(evidence.sourceItem.title)."]

        if evidence.evidenceRows.isEmpty {
            sentences.append("Connected to this library track through Fetcher's identity bridge.")
        } else {
            sentences.append(contentsOf: evidence.evidenceRows.prefix(3).map { row in
                "\(row.evidenceLabel), recorded as \(row.evidenceKind.fetcherInfoDisplayName.lowercased()) with \(row.confidence.fetcherInfoDisplayName.lowercased()) confidence."
            })
        }

        if let identity = evidence.identityRows.first {
            sentences.append(
                "Linked to this library track as \(identity.mappingStatus.fetcherInfoDisplayName.lowercased()), with \(identity.mappingConfidence.fetcherInfoDisplayName.lowercased()) confidence."
            )
        } else if let candidate = evidence.candidates.first {
            sentences.append(
                "Recorded as a \(candidate.candidateState.fetcherInfoDisplayName.lowercased()) import candidate."
            )
        }

        return "\u{201C}\(sentences.joined(separator: " "))\u{201D}"
    }
}

// MARK: - Album Info Section

private struct AlbumInfoSection: View {
    let album: Album

    var body: some View {
        Section("Album Information") {
            InfoRow(label: "Name", value: album.name)
            InfoRow(label: "Artist", value: album.artist)

            if let year = album.year {
                InfoRow(label: "Year", value: "\(year)")
            }

            if let genre = album.genre {
                InfoRow(label: "Genre", value: genre)
            }
        }

        Section("Contents") {
            InfoRow(label: "Tracks", value: "\(album.songCount)")
            InfoRow(label: "Duration", value: formatDuration(album.duration))
        }

        Section("Library") {
            if let rating = album.rating, rating > 0 {
                InfoRow(label: "Rating", value: String(repeating: "\u{2605}", count: rating))
            }

            if album.starred != nil {
                InfoRow(label: "Loved", value: "Yes")
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Artist Info Section

private struct ArtistInfoSection: View {
    let artist: Artist

    var body: some View {
        Section("Artist Information") {
            InfoRow(label: "Name", value: artist.name)
            InfoRow(label: "Albums", value: "\(artist.albumCount)")
        }

        Section("Library") {
            if artist.starred != nil {
                InfoRow(label: "Loved", value: "Yes")
            }
        }
    }
}

// MARK: - Playlist Info Section

private struct PlaylistInfoSection: View {
    let playlist: Playlist

    var body: some View {
        Section("Playlist Information") {
            InfoRow(label: "Name", value: playlist.name)
            InfoRow(label: "Owner", value: playlist.owner)

            if let comment = playlist.comment, !comment.isEmpty {
                InfoRow(label: "Description", value: comment)
            }
        }

        Section("Contents") {
            InfoRow(label: "Songs", value: "\(playlist.songCount)")
            InfoRow(label: "Duration", value: playlist.formattedDuration)
        }

        Section("Details") {
            InfoRow(label: "Created", value: formatDate(playlist.created))
            InfoRow(label: "Modified", value: formatDate(playlist.changed))
            InfoRow(label: "Visibility", value: playlist.isPublic ? "Public" : "Private")
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Dossier Section (GI-A)

/// Prose-first testimony from the curation database, rendered ahead of the
/// technical metadata. Each chapter becomes a sentence or two; the section
/// stays quiet (single line) when the database has no story yet.
private struct DossierSection: View {
    let dossier: DossierStory

    var body: some View {
        Section("Dossier") {
            if dossier.hasTestimony {
                ForEach(Array(storyLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            } else {
                Text("The library has no story for this item yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var storyLines: [String] {
        var lines: [String] = []

        if let waitingRoom = dossier.waitingRoom {
            var sentence = "Arrived in the Waiting Room \(Self.datePhrase(waitingRoom.addedAt)) via \(Self.friendly(waitingRoom.source))"
            if waitingRoom.auditionCount > 0 {
                let times = waitingRoom.auditionCount == 1 ? "once" : "\(waitingRoom.auditionCount) times"
                sentence += ", auditioned \(times)"
                if let last = waitingRoom.lastAuditionedAt {
                    sentence += " (last \(Self.datePhrase(last)))"
                }
            }
            sentence += " — currently \(Self.friendly(waitingRoom.state))."
            lines.append(sentence)
            if let notes = waitingRoom.notes, !notes.isEmpty {
                lines.append("Waiting Room note: \u{201C}\(notes)\u{201D}")
            }
        }

        if let admission = dossier.admission {
            var sentence = "Admitted to the Library \(Self.datePhrase(admission.admittedAt)) via \(Self.friendly(admission.admittedBy))"
            if let detail = admission.sourceDetail, !detail.isEmpty {
                sentence += " (\(Self.friendly(detail)))"
            }
            lines.append(sentence + ".")
        }

        for mark in dossier.attentionMarks {
            var sentence = "Marked \(Self.friendly(mark.type)) \(Self.datePhrase(mark.markedAt))"
            if let note = mark.note, !note.isEmpty {
                sentence += ": \u{201C}\(note)\u{201D}"
            }
            lines.append(sentence + ".")
        }

        if let likedAt = dossier.likedAt {
            lines.append("Liked \(Self.datePhrase(likedAt)).")
        }

        if let starredAt = dossier.starredAt {
            lines.append("Starred \(Self.datePhrase(starredAt)).")
        }

        if dossier.plays.playCount > 0 {
            let times = dossier.plays.playCount == 1 ? "once" : "\(dossier.plays.playCount) times"
            var sentence = "Played \(times)"
            if let first = dossier.plays.firstPlayedAt {
                sentence += ", first \(Self.datePhrase(first))"
            }
            if let last = dossier.plays.lastPlayedAt {
                sentence += ", most recently \(Self.datePhrase(last))"
            }
            lines.append(sentence + ".")
        }

        if !dossier.projects.isEmpty {
            let names = dossier.projects.map(\.name).joined(separator: ", ")
            lines.append(dossier.projects.count == 1
                ? "Part of the project \(names)."
                : "Part of projects: \(names).")
        }

        for voice in dossier.attributionVoices.prefix(3) {
            var sentence = "Sourced from \(voice.sourceDisplayName ?? voice.downloadSource ?? "an unknown source")"
            if let download = voice.downloadSource, voice.sourceDisplayName != nil {
                sentence += " via \(Self.friendly(download))"
            }
            lines.append(sentence + ".")
        }

        return lines
    }

    /// "on Jan 5, 2026" for older dates, "2 days ago" for recent ones.
    private static func datePhrase(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 30 * 24 * 3600 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        let formatted = date.formatted(date: .abbreviated, time: .omitted)
        return "on \(formatted)"
    }

    /// Humanize rawValue strings like "more_like_this" or "new-music".
    private static func friendly(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

// MARK: - Info Row

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

private extension String {
    var fetcherInfoDisplayName: String {
        replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - Previews

#Preview("Song Info") {
    GetInfoView(content: .song(.placeholder))
        .environment(AppState())
}

#Preview("Album Info") {
    GetInfoView(content: .album(.placeholder))
        .environment(AppState())
}

#Preview("Artist Info") {
    GetInfoView(content: .artist(.placeholder))
        .environment(AppState())
}
