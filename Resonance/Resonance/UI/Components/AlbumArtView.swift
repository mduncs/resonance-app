import SwiftUI

// MARK: - Artwork Size

enum ArtworkSize {
    case miniBar    // 35pt (now playing bar)
    case small      // 40-50pt (list rows)
    case medium     // 100pt (cards)
    case large      // 200pt (detail headers)
    case extraLarge // 300pt (now playing)

    var pointSize: CGFloat {
        switch self {
        case .miniBar: return 35
        case .small: return 50
        case .medium: return 100
        case .large: return 200
        case .extraLarge: return 300
        }
    }

    var suffix: String {
        switch self {
        case .miniBar: return "xs"
        case .small: return "sm"
        case .medium: return "md"
        case .large: return "lg"
        case .extraLarge: return "xl"
        }
    }
}

struct AlbumArtView: View {
    let coverArtId: String?
    let size: ArtworkSize
    var flexible: Bool = false  // When true, doesn't apply fixed frame - parent controls size

    // Pass actors directly to avoid Environment access in TableColumn closures
    var cacheActor: CacheActor?
    var networkActor: NetworkActor?

    @State private var image: NSImage?
    @State private var isLoading = false

    private var frameSize: CGFloat? {
        flexible ? nil : size.pointSize
    }

    private var radius: CGFloat {
        flexible ? 0 : cornerRadius
    }

    var body: some View {
        imageContent
            .task(id: coverArtId) {
                await loadImage()
            }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let image {
            Color.clear
                .frame(width: frameSize, height: frameSize)
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius))
        } else if isLoading {
            RoundedRectangle(cornerRadius: radius)
                .fill(Color(nsColor: NSColor.unemphasizedSelectedContentBackgroundColor))
                .frame(width: frameSize, height: frameSize)
                .overlay {
                    ProgressView()
                        .scaleEffect(size == .small ? 0.5 : 1.0)
                }
        } else {
            RoundedRectangle(cornerRadius: radius)
                .fill(Color(nsColor: NSColor.unemphasizedSelectedContentBackgroundColor))
                .frame(width: frameSize, height: frameSize)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: size.pointSize * 0.3))
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private var cornerRadius: CGFloat {
        switch size {
        case .miniBar: return 8
        case .small: return 4
        case .medium: return 6
        case .large: return 8
        case .extraLarge: return 12
        }
    }

    private func loadImage() async {
        guard let coverArtId, !coverArtId.isEmpty else { return }
        guard let cacheActor, let networkActor else { return }

        // Fast path: check in-memory cache first (returns NSImage directly, no allocation)
        if let cached = await cacheActor.getArtworkImage(for: coverArtId, size: size) {
            await MainActor.run {
                self.image = cached
            }
            return
        }

        isLoading = true
        defer { isLoading = false }

        // Fetch from server
        do {
            let data = try await networkActor.fetchCoverArt(
                id: coverArtId,
                size: Int(size.pointSize * 2) // 2x for Retina
            )
            // Cache to disk and populate memory cache
            try? await cacheActor.cacheArtworkWithImage(data, for: coverArtId, size: size)
            if let nsImage = NSImage(data: data) {
                await MainActor.run {
                    self.image = nsImage
                }
            }
        } catch {
            // Silent failure - shows placeholder
        }
    }
}

// MARK: - Environment Wrapper
// Use this in normal view contexts where Environment is available.
// Use AlbumArtView directly with actors passed in for TableColumn closures.

struct EnvironmentAlbumArtView: View {
    let coverArtId: String?
    let size: ArtworkSize
    var flexible: Bool = false

    @Environment(AppState.self) private var appState

    var body: some View {
        AlbumArtView(
            coverArtId: coverArtId,
            size: size,
            flexible: flexible,
            cacheActor: appState.cacheActor,
            networkActor: appState.networkActor
        )
    }
}

#Preview {
    HStack(spacing: 20) {
        EnvironmentAlbumArtView(coverArtId: nil, size: .small)
        EnvironmentAlbumArtView(coverArtId: nil, size: .medium)
        EnvironmentAlbumArtView(coverArtId: nil, size: .large)
    }
    .padding()
    .environment(AppState())
}
