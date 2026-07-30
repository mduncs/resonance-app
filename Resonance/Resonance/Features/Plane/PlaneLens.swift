import Foundation
import Observation

/// Opening a project does not
/// leave the plane, it *scopes* it. An active lens narrows the Constellation/
/// Shelf lanes (and the dashed audition strip) to the project's items while the
/// camera grammar stays untouched. A lens is a *view* of the plane, never a
/// mutation of it — dropping the lens restores the full library instantly.
struct PlaneLens: Equatable, Sendable {
    let project: Project
    /// Album ids visible under this lens (albums the project's items resolve to).
    let albumIds: Set<String>
    /// Project items that resolve to no tile on the plane: song references whose
    /// song (or album) is not in the loaded set, album references outside the
    /// loaded set, and artist references (which have no tile at all). Surfaced as
    /// "+N unresolved" on the lens chip — no ghost tiles this slice.
    let unresolvedCount: Int
}

/// Pure lens resolution, dependency-free in the `PlaneLaneBuilder` style so it
/// can be exercised without a database: given the project's raw items, the songs
/// that resolved from the database join, and the albums currently on the plane,
/// decide which album tiles the lens keeps and how many items fell through.
enum PlaneLensResolver {
    static func resolve(
        project: Project,
        items: [ProjectItem],
        resolvedSongs: [Song],
        albums: [Album]
    ) -> PlaneLens {
        let loadedAlbumIds = Set(albums.map(\.id))
        let songsById = Dictionary(resolvedSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var visible: Set<String> = []
        var unresolved = 0

        for item in items {
            switch item.itemType {
            case .song:
                if let song = songsById[item.itemId],
                   !song.albumId.isEmpty,
                   loadedAlbumIds.contains(song.albumId) {
                    visible.insert(song.albumId)
                } else {
                    unresolved += 1
                }
            case .album:
                if loadedAlbumIds.contains(item.itemId) {
                    visible.insert(item.itemId)
                } else {
                    unresolved += 1
                }
            case .artist:
                unresolved += 1
            }
        }

        return PlaneLens(project: project, albumIds: visible, unresolvedCount: unresolved)
    }
}

/// Cross-room hand-off for lens activation: the Projects room requests a lens,
/// the plane consumes it when it is (or next becomes) visible. Deliberately a
/// tiny standalone store rather than an `AppState` property so the lens slice
/// stays within the plane's file ownership; folding it into `AppState` later is
/// a mechanical move.
@MainActor
@Observable
final class PlaneLensStore {
    static let shared = PlaneLensStore()

    /// Project id waiting to be applied as a lens by the plane.
    private(set) var requestedProjectId: String?

    func request(projectId: String) {
        requestedProjectId = projectId
    }

    /// Consume the pending request (the plane calls this exactly once per apply).
    func consumeRequest() -> String? {
        defer { requestedProjectId = nil }
        return requestedProjectId
    }
}
