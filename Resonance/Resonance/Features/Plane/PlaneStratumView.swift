import SwiftUI

/// The Constellation↔Shelf stratum: source lanes of morphing album tiles. Tile
/// size and lane spacing interpolate with the camera's `tz` so the whole surface
/// is one continuous zoom.
///
/// The first lane, when present, is the dashed audition strip — the Salon
/// projection of the Waiting Room.
struct PlaneStratumView: View {
    let lanes: [PlaneLane]
    let z: Double
    let nowPlayingAlbumId: String?
    let selectedAlbumId: String?
    /// Curation state keyed by album id (empty while the data lane is a stub).
    let decorations: [String: PlaneAlbumDecoration]
    /// Wear tier keyed by album id (0/1/2), relative to the loaded set.
    let wearByAlbum: [String: Int]
    let onSelect: (Album) -> Void
    let onPlay: (Album) -> Void

    var body: some View {
        let tz = PlanePresence.tz(at: z)
        let tileSize = CGFloat(56 + tz * 84)

        Group {
            if lanes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16 + tz * 20) {
                        ForEach(lanes) { lane in
                            laneView(lane, tz: tz, tileSize: tileSize)
                        }
                    }
                    .frame(maxWidth: 1240, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 44)
                    .padding(.vertical, 44)
                    .padding(.bottom, 90)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func laneView(_ lane: PlaneLane, tz: Double, tileSize: CGFloat) -> some View {
        if lane.isAudition {
            auditionLane(lane, tz: tz, tileSize: tileSize)
        } else {
            sourceLane(lane, tz: tz, tileSize: tileSize)
        }
    }

    private func sourceLane(_ lane: PlaneLane, tz: Double, tileSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5 + tz * 6) {
            laneHeader(lane.title)
            grid(lane, tz: tz, tileSize: tileSize)
        }
    }

    // The audition strip: a dashed top/bottom rule brackets the lane so it reads
    // as a distinct waiting-room shelf, not another source lane.
    private func auditionLane(_ lane: PlaneLane, tz: Double, tileSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5 + tz * 6) {
            dashedRule
            laneHeader(lane.title)
            grid(lane, tz: tz, tileSize: tileSize)
            dashedRule
        }
    }

    private func laneHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(.tertiary)
    }

    private var dashedRule: some View {
        Rectangle()
            .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .frame(height: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(_ lane: PlaneLane, tz: Double, tileSize: CGFloat) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize), spacing: 8 + tz * 8)],
            alignment: .leading,
            spacing: 8 + tz * 12
        ) {
            ForEach(lane.albums) { album in
                let decoration = decorations[album.id]
                PlaneTile(
                    album: album,
                    tz: tz,
                    tileSize: tileSize,
                    isNowPlaying: album.id == nowPlayingAlbumId,
                    isSelected: album.id == selectedAlbumId,
                    decoration: decoration,
                    wearTier: wearByAlbum[album.id] ?? 0,
                    isAudition: lane.isAudition,
                    freshness: PlaneFreshness.intensity(
                        discoveredAt: decoration?.discoveredAt,
                        isSeen: decoration?.isSeenDiscovery ?? false
                    ),
                    onSelect: { onSelect(album) },
                    onPlay: { onPlay(album) }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Nothing admitted yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Albums you admit to the library appear here as source lanes.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
