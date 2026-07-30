import SwiftUI

/// GI-B "The Evidence Rail" — the Dossier Sheet's content (`GetInfoView`),
/// docked as a summonable right rail at the plane's near strata (Object,
/// Player) instead of a modal sheet. Evidence you can read *while listening*:
/// playback and plane interaction continue while it is open.
///
/// The rail is embedded WITHIN `PlaneObjectView` and `PlanePlayerView` (each
/// stratum hosts it when it is most-present) rather than as a `PlaneView`-level
/// overlay, because that root cannot be edited by this lane. The parent's
/// crossfade already fades and disables the non-present stratum, so only the
/// active stratum's rail is visible and interactive — far distances show no
/// rail for free.
///
/// The rendering deliberately mirrors `GetInfoView`'s `DossierSection` prose
/// (RelativeDateTimeFormatter phrasing, humanized rawValues) and its Fetcher
/// source-voice testimony. This is a modest, intentional duplication: the sheet
/// remains the far-distance / list-context surface and is left untouched.

// MARK: - Toggle controller

/// Shared, `@Observable` toggle for the near-strata evidence rail. Lives as a
/// singleton because the plane's own state (`PlaneView`) and `AppState` are
/// owned by other lanes and cannot be edited here. ⌘I flips `isOpen` (routed in
/// `ResonanceApp` when the plane is the active surface); both embedded rails
/// observe it, and the plane crossfade decides which one the user actually sees.
@MainActor
@Observable
final class PlaneEvidenceRailController {
    static let shared = PlaneEvidenceRailController()

    /// Whether the rail is summoned. Both strata render their rail when true;
    /// only the most-present stratum's is visible/interactive.
    var isOpen = false

    /// Whether the plane camera is at a near stratum (Object / Player), where the
    /// rail is meaningful. Defaults true so the interim trigger works before
    /// `PlaneView` publishes camera distance. Once `PlaneView` sets this from its
    /// rounded distance, ⌘I at far distances (Constellation / Shelf) falls back to
    /// the Dossier Sheet — see the integration note in the GI-B report.
    var nearOnPlane = true

    private init() {}

    func toggle() { isOpen.toggle() }
    func open() { isOpen = true }
    func close() { isOpen = false }
}

// MARK: - Subject

/// What a rail is testifying about. Follows the stratum: Player → now-playing
/// song, Object → the focused album (`dossierStory` handles both).
enum EvidenceSubject: Equatable {
    case song(Song)
    case album(Album)

    var id: String {
        switch self {
        case .song(let song): return "song-\(song.id)"
        case .album(let album): return "album-\(album.id)"
        }
    }

    var title: String {
        switch self {
        case .song(let song): return song.title
        case .album(let album): return album.name
        }
    }

    var subtitle: String {
        switch self {
        case .song(let song): return song.artist
        case .album(let album): return album.artist
        }
    }

    var coverArtId: String? {
        switch self {
        case .song(let song): return song.coverArt
        case .album(let album): return album.coverArt
        }
    }
}

// MARK: - Rail

struct PlaneEvidenceRail: View {
    @Environment(AppState.self) private var appState

    /// nil renders the quiet empty state (no now-playing song / no focused album).
    let subject: EvidenceSubject?

    /// Fixed dock width. The host stratum cedes this gracefully.
    static let width: CGFloat = 320

    @State private var dossier: DossierStory?
    @State private var fetcherEvidence: [FetcherSongSourceEvidence] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.bar)
        .task(id: subject?.id) { load() }
        .onReceive(NotificationCenter.default.publisher(for: .resonanceCurationDidChange)) { _ in
            load()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Evidence")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if let subject {
                EnvironmentAlbumArtView(coverArtId: subject.coverArtId, size: .small, flexible: true)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, height: 44)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Evidence")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                Text(subject?.title ?? "Nothing here")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if let subject {
                    Text(subject.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button {
                PlaneEvidenceRailController.shared.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close evidence rail")
            .accessibilityLabel("Close evidence rail")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if subject == nil {
            emptyState
        } else if let dossier, dossier.hasTestimony || !fetcherEvidence.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if dossier.hasTestimony {
                        chapter("Dossier") {
                            ForEach(Array(DossierProse.storyLines(dossier).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    if !fetcherEvidence.isEmpty {
                        chapter("Sources") {
                            ForEach(fetcherEvidence.prefix(5)) { evidence in
                                sourceVoice(evidence)
                            }
                            if fetcherEvidence.count > 5 {
                                Text("\(fetcherEvidence.count - 5) more Fetcher source matches are hidden.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Text("Read-only Fetcher evidence. This does not create Library membership.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            quietDossier
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("Nothing to testify")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var quietDossier: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The library has no story for this item yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func chapter<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(.tertiary)
            rows()
        }
    }

    private func sourceVoice(_ evidence: FetcherSongSourceEvidence) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(evidence.collectionDisplayName)
                .font(.system(size: 12, weight: .medium))
            if let sourceKind = evidence.sourceKindDisplayName {
                Text(sourceKind)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Text(sourceTestimony(for: evidence))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    // MARK: Loading

    private func load() {
        guard let subject, let serverId = appState.activeServerId else {
            dossier = nil
            fetcherEvidence = []
            return
        }

        switch subject {
        case .song(let song):
            dossier = try? appState.databaseManager.dossierStory(
                songId: song.id,
                songPath: song.path,
                albumId: song.albumId,
                serverId: serverId
            )
            loadFetcherEvidence(for: song)
        case .album(let album):
            dossier = try? appState.databaseManager.dossierStory(
                albumId: album.id,
                serverId: serverId
            )
            fetcherEvidence = []
        }
    }

    private func loadFetcherEvidence(for song: Song) {
        fetcherEvidence = []
        guard UserDefaults.standard.bool(forKey: FetcherContractSettings.isEnabledKey),
              let directory = FetcherContractLoader().configuredDirectory(),
              let snapshot = try? FetcherContractLoader().loadSnapshot(from: directory) else { return }
        fetcherEvidence = snapshot.songSourceEvidence(forNavidromeSongId: song.id)
    }

    private func sourceTestimony(for evidence: FetcherSongSourceEvidence) -> String {
        var sentences = ["\(evidence.sourceItem.title)."]

        if evidence.evidenceRows.isEmpty {
            sentences.append("Connected to this library track through Fetcher's identity bridge.")
        } else {
            sentences.append(contentsOf: evidence.evidenceRows.prefix(3).map { row in
                "\(row.evidenceLabel), recorded as \(row.evidenceKind.railDisplayName) with \(row.confidence.railDisplayName) confidence."
            })
        }

        if let identity = evidence.identityRows.first {
            sentences.append(
                "Linked to this library track as \(identity.mappingStatus.railDisplayName), with \(identity.mappingConfidence.railDisplayName) confidence."
            )
        } else if let candidate = evidence.candidates.first {
            sentences.append(
                "Recorded as a \(candidate.candidateState.railDisplayName) import candidate."
            )
        }

        return "\u{201C}\(sentences.joined(separator: " "))\u{201D}"
    }
}

// MARK: - Shared prose (GI-C)

/// The dossier prose builder, shared by the rail, the per-distance previews
/// (Shelf hover chip, Object story line, Player session line), and the Shelf
/// bloom popover. Extracted from the rail so "the dossier's first sentence"
/// (GI-C's preview unit) can never drift from the full testimony it blooms into.
enum DossierProse {
    /// The full testimony as ordered prose lines. Mirrors
    /// `GetInfoView.DossierSection` phrasing; the rail and the bloom render these.
    static func storyLines(_ dossier: DossierStory) -> [String] {
        var lines: [String] = []

        if let waitingRoom = dossier.waitingRoom {
            var sentence = "Arrived in the Waiting Room \(datePhrase(waitingRoom.addedAt)) via \(friendly(waitingRoom.source))"
            if waitingRoom.auditionCount > 0 {
                let times = waitingRoom.auditionCount == 1 ? "once" : "\(waitingRoom.auditionCount) times"
                sentence += ", auditioned \(times)"
                if let last = waitingRoom.lastAuditionedAt {
                    sentence += " (last \(datePhrase(last)))"
                }
            }
            sentence += " — currently \(friendly(waitingRoom.state))."
            lines.append(sentence)
            if let notes = waitingRoom.notes, !notes.isEmpty {
                lines.append("Waiting Room note: \u{201C}\(notes)\u{201D}")
            }
        }

        if let admission = dossier.admission {
            var sentence = "Admitted to the Library \(datePhrase(admission.admittedAt)) via \(friendly(admission.admittedBy))"
            if let detail = admission.sourceDetail, !detail.isEmpty {
                sentence += " (\(friendly(detail)))"
            }
            lines.append(sentence + ".")
        }

        for mark in dossier.attentionMarks {
            var sentence = "Marked \(friendly(mark.type)) \(datePhrase(mark.markedAt))"
            if let note = mark.note, !note.isEmpty {
                sentence += ": \u{201C}\(note)\u{201D}"
            }
            lines.append(sentence + ".")
        }

        if let likedAt = dossier.likedAt {
            lines.append("Liked \(datePhrase(likedAt)).")
        }

        if let starredAt = dossier.starredAt {
            lines.append("Starred \(datePhrase(starredAt)).")
        }

        if dossier.plays.playCount > 0 {
            let times = dossier.plays.playCount == 1 ? "once" : "\(dossier.plays.playCount) times"
            var sentence = "Played \(times)"
            if let first = dossier.plays.firstPlayedAt {
                sentence += ", first \(datePhrase(first))"
            }
            if let last = dossier.plays.lastPlayedAt {
                sentence += ", most recently \(datePhrase(last))"
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
                sentence += " via \(friendly(download))"
            }
            lines.append(sentence + ".")
        }

        return lines
    }

    /// The preview unit: the testimony's first sentence, or nil when the library
    /// has no story (previews omit themselves rather than showing placeholder
    /// noise).
    static func firstSentence(_ dossier: DossierStory?) -> String? {
        guard let dossier, dossier.hasTestimony else { return nil }
        return storyLines(dossier).first
    }

    /// "on Jan 5, 2026" for older dates, "2 days ago" for recent ones.
    static func datePhrase(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 30 * 24 * 3600 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        let formatted = date.formatted(date: .abbreviated, time: .omitted)
        return "on \(formatted)"
    }

    /// Humanize rawValue strings like "more_like_this" or "new-music".
    static func friendly(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

// MARK: - Preview cache (GI-C)

/// Lazily-filled cache of dossier first sentences keyed by evidence-subject id,
/// invalidated wholesale on curation writes. Previews fetch through here on
/// hover / subject change, so the Shelf never bulk-loads dossiers — a tile costs
/// one `dossierStory` read the first time it is hovered, then nothing.
@MainActor
final class DossierPreviewCache {
    static let shared = DossierPreviewCache()

    /// subject id → first sentence (`nil` = fetched, no testimony). Distinct from
    /// an absent key, which means "never fetched".
    private var sentences: [String: String?] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .resonanceCurationDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DossierPreviewCache.shared.sentences.removeAll()
            }
        }
    }

    /// Cached first sentence for the subject, fetching once on miss.
    func firstSentence(for subject: EvidenceSubject, appState: AppState) -> String? {
        if let cached = sentences[subject.id] { return cached }
        guard let serverId = appState.activeServerId else { return nil }

        let dossier: DossierStory?
        switch subject {
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
        }

        let sentence = DossierProse.firstSentence(dossier)
        sentences[subject.id] = sentence
        return sentence
    }
}

// MARK: - Shelf bloom (GI-C)

/// The Shelf-distance bloom: the tile chip's full testimony, expanded in place as
/// an anchored popover (the rail only exists inside the Object/Player strata, so
/// at Shelf the bloom is the popover rendering the same `DossierProse`).
struct DossierBloomView: View {
    @Environment(AppState.self) private var appState

    let subject: EvidenceSubject

    @State private var dossier: DossierStory?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(subject.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Text(subject.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let dossier, dossier.hasTestimony {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(DossierProse.storyLines(dossier).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("The library has no story for this item yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .task(id: subject.id) { load() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Full testimony for \(subject.title)")
    }

    private func load() {
        guard let serverId = appState.activeServerId else {
            dossier = nil
            return
        }
        switch subject {
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
        }
    }
}

private extension String {
    /// Local mirror of GetInfoView's private `fetcherInfoDisplayName` (lowercased
    /// for mid-sentence use, matching the sheet's source-voice phrasing).
    var railDisplayName: String {
        replacingOccurrences(of: "_", with: " ").capitalized.lowercased()
    }
}
