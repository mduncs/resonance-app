import SwiftUI

/// A single album tile on the plane. Its size and label fidelity interpolate with
/// `tz` (0 = Constellation density, 1 = Shelf density) so Constellation→Shelf is
/// one morphing set of tiles, never a layout swap. Ports the prototype's
/// Shelf morph: size `56 + tz*84`, label height
/// `tz*32`, label opacity `(tz − 0.55)/0.45`.
///
/// Curation decorations (mark glyph, wear ring, audition treatment) come from the
/// bulk `planeDecorations` load. Marks and the audition chip are shelf-fidelity —
/// they scale/fade with `tz` like labels. The wear ring reads at both distances
/// (the prototype rings covers in `tile-far` and `tile-shelf` alike).
struct PlaneTile: View {
    let album: Album
    let tz: Double
    let tileSize: CGFloat
    let isNowPlaying: Bool
    let isSelected: Bool
    /// Curation state for this album, if any (nil while the data lane is empty).
    let decoration: PlaneAlbumDecoration?
    /// Wear tier relative to the loaded set: 0 none, 1 faint ring, 2 strong ring.
    let wearTier: Int
    /// True only for tiles sitting in the dashed audition strip.
    let isAudition: Bool
    /// Growing Edge glow strength in `0...1` (NM-2): >0 on an unseen new arrival,
    /// decaying with age and 0 once seen or past the freshness window. Drives the
    /// warm halo + unseen dot. See `PlaneFreshness`.
    var freshness: Double = 0
    let onSelect: () -> Void
    let onPlay: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState
    @State private var pulsing = false
    @State private var isHovered = false
    /// GI-C: the dossier's first sentence, fetched lazily on first hover through
    /// `DossierPreviewCache` (never bulk-fetched for the shelf). `storyFetched`
    /// distinguishes "not asked yet" from "asked, no testimony".
    @State private var story: String?
    @State private var storyFetched = false
    @State private var showBloom = false

    private var cornerRadius: CGFloat { 3 + tz * 2 }
    private var labelHeight: CGFloat { tz * 32 }
    private var labelOpacity: Double { min(1, max(0, (tz - 0.55) / 0.45)) }

    // Audition covers ride at reduced opacity throughout; the dashed outline is a
    // constellation-fidelity cue that fades out as the chip fades in on approach.
    private var coverOpacity: Double { isAudition ? 0.7 : 1 }
    private var dashOpacity: Double { isAudition ? (1 - labelOpacity) * 0.9 : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: tz * 8) {
            cover

            if labelHeight > 0.5 {
                label
            }
        }
        .frame(width: tileSize, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPlay)
        .simultaneousGesture(TapGesture(count: 1).onEnded(onSelect))
        .onHover { hovering in
            isHovered = hovering
            if hovering { loadStoryIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resonanceCurationDidChange)) { _ in
            // The shared cache already dropped its entries; forget the local copy
            // so the next hover refetches.
            story = nil
            storyFetched = false
        }
        .help(labelOpacity < 0.5 ? helpText : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Click to open, double-click to play")
        .accessibilityAddTraits(.isButton)
        .onAppear {
            if isNowPlaying && !reduceMotion {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
        }
    }

    private var cover: some View {
        EnvironmentAlbumArtView(coverArtId: album.coverArt, size: .large, flexible: true)
            .frame(width: tileSize, height: tileSize)
            .opacity(coverOpacity)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // Wear ring: an inset warm hairline on the most-played covers.
            .overlay {
                if wearTier > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(wearTier == 2 ? 0.30 : 0.15), lineWidth: 1.5)
                        .padding(0.75)
                }
            }
            // Growing Edge halo (NM-2): a warm hairline on an unseen new arrival,
            // fading with the freshness decay. Warm-tinted like the ✳ interesting
            // mark (`.orange`) — a quiet border, not a neon ring; reads at both
            // Constellation and Shelf like the wear ring.
            .overlay {
                if hasFreshness {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.55 * freshness), lineWidth: 1.5)
                }
            }
            // Selection / now-playing / hover ring.
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: strokeWidth)
                    .opacity(strokeOpacity)
            }
            // Dashed audition outline (constellation-fidelity).
            .overlay {
                if dashOpacity > 0.01 {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            Color.secondary,
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                        .opacity(dashOpacity)
                }
            }
            // "on audition" chip (shelf-fidelity, fades in with labels).
            .overlay(alignment: .bottomLeading) {
                if isAudition && labelOpacity > 0.01 {
                    auditionChip.opacity(labelOpacity)
                }
            }
            // GI-C hover story chip (shelf-fidelity): the dossier's first sentence
            // over the cover's bottom edge while hovered; clicking blooms the full
            // testimony in place as an anchored popover. Overlay-only, so the tile
            // never changes size on hover (the hover-oscillation lesson).
            .overlay(alignment: .bottomLeading) {
                if let story, showChip || showBloom {
                    storyChip(story)
                }
            }
            // Growing Edge unseen dot: a small warm dot in the corner while the
            // arrival is unseen, fading out over the freshness window.
            .overlay(alignment: .topTrailing) {
                if hasFreshness {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                        .padding(5)
                        .opacity(min(1, 0.4 + 0.6 * freshness))
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(tz * 0.12), radius: tz * 6, x: 0, y: tz * 3)
            // Warm outer glow, strongest on the freshest arrivals.
            .shadow(color: .orange.opacity(0.45 * freshness), radius: 9 * freshness)
    }

    private var hasFreshness: Bool { freshness > 0.001 }

    // MARK: - GI-C story chip

    /// Chip is shelf-fidelity (like labels and the audition chip) and hover-only.
    private var showChip: Bool { isHovered && labelOpacity > 0.5 }

    /// Fetch the first sentence once per tile identity, only at shelf fidelity —
    /// hovering across the Constellation stays free.
    private func loadStoryIfNeeded() {
        guard labelOpacity > 0.5, !storyFetched else { return }
        storyFetched = true
        story = DossierPreviewCache.shared.firstSentence(for: .album(album), appState: appState)
    }

    private func storyChip(_ sentence: String) -> some View {
        Button {
            showBloom = true
        } label: {
            Text(sentence)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: tileSize - 12, alignment: .leading)
        .padding(.horizontal, 6)
        // Sit above the audition chip when both are present.
        .padding(.bottom, isAudition && labelOpacity > 0.01 ? 27 : 6)
        .popover(isPresented: $showBloom, arrowEdge: .bottom) {
            DossierBloomView(subject: .album(album))
        }
        .help("Read the full story")
        .accessibilityLabel("Story: \(sentence). Click for the full testimony.")
    }

    private var auditionChip: some View {
        Text("on audition")
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .padding(6)
            .allowsHitTesting(false)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(album.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                markGlyph
            }
            Text(album.artist)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: tileSize, height: labelHeight, alignment: .topLeading)
        .opacity(labelOpacity)
        .clipped()
        .allowsHitTesting(false)
    }

    // ♥ in the accent for "loved", ✳ in a warm secondary for "interesting"
    // (`.orange`, the app's existing warm accent — no new palette).
    @ViewBuilder
    private var markGlyph: some View {
        switch decoration?.mark {
        case "loved":
            Text("♥")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
        case "interesting":
            Text("✳")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    // A steady accent ring on the now-playing tile (gently pulsing unless reduce
    // motion), a faint accent ring on the selected tile, and a hover hairline.
    private var strokeColor: Color {
        if isNowPlaying || isSelected { return .accentColor }
        return .primary
    }

    private var strokeWidth: CGFloat {
        (isNowPlaying || isSelected) ? 1.5 : 1
    }

    private var strokeOpacity: Double {
        if isNowPlaying { return pulsing ? 0.35 : 1 }
        if isSelected { return 0.6 }
        return isHovered ? 0.12 : 0
    }

    private var markSuffix: String {
        switch decoration?.mark {
        case "loved": return ", loved"
        case "interesting": return ", interesting"
        default: return ""
        }
    }

    private var helpText: String {
        "\(album.name) — \(album.artist)" + (isAudition ? " (on audition)" : "")
    }

    private var accessibilityLabel: String {
        var label = "\(album.name) by \(album.artist)\(markSuffix)"
        if isAudition { label += ", on audition" }
        if hasFreshness { label += ", new arrival" }
        return label
    }
}
