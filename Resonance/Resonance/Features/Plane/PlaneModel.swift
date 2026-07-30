import Foundation

/// One horizontal-flow lane on the plane: a group of albums that share a source
/// voice. Lanes are the structural substrate of the Constellation/Shelf stratum
/// Sources form the lane structure of the plane.
struct PlaneLane: Identifiable, Equatable, Sendable {
    /// Lane key — the source display name, `PlaneLaneBuilder.catchAllKey`, or
    /// `PlaneLaneBuilder.auditionKey` for the dashed waiting-room strip.
    let id: String
    /// Header caption shown above the lane.
    let title: String
    let albums: [Album]
    /// True for the audition strip — the Salon projection of the Waiting Room
    /// Rendered with a dashed
    /// treatment and reduced-opacity covers, and always sorts first.
    var isAudition: Bool = false
}

/// Result of a lane rebuild: the lanes plus a per-album first-voice name map used
/// for the Object stratum's provenance line. Sendable so it can cross actors.
struct PlaneLaneResult: Sendable {
    let lanes: [PlaneLane]
    /// albumId → first source voice display name (present only for sourced albums).
    let voiceNames: [String: String]
}

/// Pure, nonisolated lane grouping so the source-voice bulk resolve can run off
/// the main actor. One lane is created per source; albums with no voice fall into
/// a single catch-all "Library" lane that always sorts last. Audition items (any
/// album whose decoration reports `onAudition`) are lifted out of their source
/// lanes into a dashed strip that always sorts first.
enum PlaneLaneBuilder {
    static let catchAllKey = "Library"
    static let auditionKey = "__audition__"
    static let auditionTitle = "On audition — waiting room"

    static func build(
        albums: [Album],
        voicesByAlbum: [String: [SourceAttributionRecord]],
        decorations: [String: PlaneAlbumDecoration] = [:]
    ) -> PlaneLaneResult {
        var order: [String] = []
        var buckets: [String: [Album]] = [:]
        var voiceNames: [String: String] = [:]
        var auditionAlbums: [Album] = []

        for album in albums {
            let voiceName = voicesByAlbum[album.id]?.first?.sourceDisplayName
            let resolved = (voiceName?.isEmpty == false) ? voiceName : nil
            if let resolved { voiceNames[album.id] = resolved }

            // Audition items leave their source lane and gather in the strip.
            if decorations[album.id]?.onAudition == true {
                auditionAlbums.append(album)
                continue
            }

            let key = resolved ?? catchAllKey
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(album)
        }

        // Catch-all lane sinks to the bottom; source lanes keep first-appearance order.
        let sourced = order.filter { $0 != catchAllKey }
        let ordered = sourced + (buckets[catchAllKey] != nil ? [catchAllKey] : [])
        var lanes = ordered.map { key in
            PlaneLane(id: key, title: key, albums: buckets[key] ?? [])
        }

        // The dashed strip is a lane only when it has items — otherwise no strip
        // at all (never an empty lane).
        if !auditionAlbums.isEmpty {
            lanes.insert(
                PlaneLane(id: auditionKey, title: auditionTitle, albums: auditionAlbums, isAudition: true),
                at: 0
            )
        }

        return PlaneLaneResult(lanes: lanes, voiceNames: voiceNames)
    }
}

/// Maps each album's play count to a wear tier relative to the loaded set, so the
/// most-played covers earn a warm "wear ring" the way a shelf's favorites show
/// spine wear. Most covers remain bare, with a small strong tier and a slightly larger
/// faint tier.
///
/// Thresholds (over albums with `playCount > 0`, ranked by play count desc):
/// the strongest ~10% (at least one) get the strong ring (tier 2), the next ~20%
/// get the faint ring (tier 1), everyone else none. Ties share a tier because the
/// cutoff is a play-count *value* (`>=`), not a fixed slot count.
enum PlaneWear {
    static func tiers(decorations: [String: PlaneAlbumDecoration]) -> [String: Int] {
        let played = decorations.filter { $0.value.playCount > 0 }
        guard !played.isEmpty else { return [:] }

        let counts = played.map(\.value.playCount).sorted(by: >)
        let n = counts.count
        // At least one album can reach the strong tier; the faint tier widens the
        // net a little without swamping the shelf.
        let strongIndex = max(0, min(n - 1, Int((Double(n) * 0.10).rounded(.up)) - 1))
        let faintIndex = max(0, min(n - 1, Int((Double(n) * 0.30).rounded(.up)) - 1))
        let strongCutoff = counts[strongIndex]
        let faintCutoff = counts[faintIndex]

        var tiers: [String: Int] = [:]
        for (id, decoration) in played {
            if decoration.playCount >= strongCutoff {
                tiers[id] = 2
            } else if decoration.playCount >= faintCutoff {
                tiers[id] = 1
            }
        }
        return tiers
    }
}

/// The Growing Edge (NM-2): a newly discovered album glows warm on its tile, and
/// the warmth decays linearly over a window from the moment it was discovered —
/// full at discovery, gone at/after `windowDays`, cleared the instant it is seen.
/// Pure and database-free (mirrors `PlaneWear`'s dependency-free style) so the
/// decay curve is testable in isolation. The decayed glow is deliberately *gone*: the
/// Arrivals Ledger, not the plane, remembers what arrived last month.
enum PlaneFreshness {
    /// Days over which a fresh discovery's glow fades to nothing.
    static let windowDays: Double = 7

    /// Glow intensity in `0...1` for a discovered album:
    /// - `discoveredAt == nil` → 0 (the album isn't a tracked discovery).
    /// - `isSeen == true` → 0 (seeing an arrival clears its glow immediately).
    /// - otherwise linear from 1 at `now == discoveredAt` to 0 at
    ///   `now >= discoveredAt + windowDays`. Future-dated discoveries (clock
    ///   skew across clients) clamp to full rather than overshooting.
    static func intensity(discoveredAt: Date?, isSeen: Bool, now: Date = Date()) -> Double {
        guard let discoveredAt, !isSeen else { return 0 }
        let window = windowDays * 24 * 60 * 60
        let age = now.timeIntervalSince(discoveredAt)
        if age <= 0 { return 1 }
        if age >= window { return 0 }
        return 1 - (age / window)
    }
}
