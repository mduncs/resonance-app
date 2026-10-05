import SwiftUI

struct ArtistRow: View {
    let artist: Artist
    var showsAlbumCount: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            // Artist image (circular)
            ArtistImageView(artistId: artist.id, coverArt: artist.coverArt)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if showsAlbumCount {
                    Text("\(artist.albumCount) albums")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct ArtistImageView: View {
    let artistId: String
    let coverArt: String?

    @Environment(AppState.self) private var appState
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.mic")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .clipShape(Circle())
        .task(id: coverArt) {
            // Reused rows must show the placeholder immediately when artwork
            // disappears or changes, not retain a previous artist's image.
            image = nil
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let coverArt, !coverArt.isEmpty else { return }

        // Fast path: check in-memory cache first
        if let cached = await appState.cacheActor.getArtworkImage(for: coverArt, size: .small) {
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.image = cached
            }
            return
        }

        // Fetch from server
        do {
            let data = try await appState.networkActor.fetchCoverArt(id: coverArt, size: 100)
            guard !Task.isCancelled else { return }
            try await appState.cacheActor.cacheArtworkWithImage(data, for: coverArt, size: .small)
            if let nsImage = NSImage(data: data) {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.image = nsImage
                }
            }
        } catch {
            // Silent failure
        }
    }
}

#Preview {
    VStack {
        ArtistRow(artist: .placeholder)
        ArtistRow(artist: .placeholder)
    }
    .padding()
    .frame(width: 300)
    .environment(AppState())
}
