import SwiftUI

/// Horizontal shelf of fixed-width cards with Apple-Music-style hover paging
/// chevrons instead of a scrollbar.
///
/// Layout rules that matter here:
/// - The chevron pucks are **always** in the view tree; hover only toggles
///   opacity + hit testing, so nothing ever reflows under the cursor.
/// - Page size is derived from the measured viewport width, so a wider window
///   scrolls more cards per click.
struct PagingRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    /// Width of a single card, used to compute how many fit per page.
    let itemWidth: CGFloat
    let spacing: CGFloat
    /// Distance from the top of the row to the vertical center of the chevrons —
    /// pass the artwork center so the pucks sit on the album art, not the labels.
    var chevronCenterY: CGFloat
    /// Vertical alignment for the underlying `LazyHStack`.
    var itemAlignment: VerticalAlignment = .center
    /// Optional row name folded into the chevron accessibility labels.
    var contextLabel: String? = nil
    var controlStyle: ShelfPagingControlStyle = .circular
    /// Let a card's shadow extend vertically without leaking cards sideways.
    var shadowOverflow: CGFloat = 0
    @ViewBuilder let content: (Item) -> Content

    @State private var leadingID: Item.ID?
    @State private var viewportWidth: CGFloat = 0
    @State private var rowHovered = false

    private var puckHeight: CGFloat { controlStyle == .capturedRecentlyPlayed ? 52 : 32 }
    private let puckInset: CGFloat = 6

    private var leadingIndex: Int {
        guard let leadingID, let index = items.firstIndex(where: { $0.id == leadingID }) else { return 0 }
        return index
    }

    private var perPage: Int {
        guard viewportWidth > 0, itemWidth > 0 else { return 1 }
        return max(1, Int(floor((viewportWidth + spacing) / (itemWidth + spacing))))
    }

    private var maxLeadingIndex: Int {
        max(0, items.count - perPage)
    }

    private var canPageBackward: Bool { leadingIndex > 0 }
    private var canPageForward: Bool { leadingIndex + perPage < items.count }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: itemAlignment, spacing: spacing) {
                ForEach(items) { item in
                    content(item)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 1) // Prevent clipping of card shadows
        }
        // Unlike .hidden, .never overrides persistent indicator policy. These
        // captured shelves provide paging buttons as the alternative to swiping.
        .scrollIndicators(.never, axes: .horizontal)
        .scrollClipDisabled(shadowOverflow > 0)
        .clipShape(ShelfViewportClip(shadowOverflow: shadowOverflow))
        .scrollPosition(id: $leadingID, anchor: .leading)
        .scrollTargetBehavior(.viewAligned)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: PagingRowWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(PagingRowWidthKey.self) { width in
            viewportWidth = width
        }
        .overlay(alignment: .topLeading) {
            chevron(systemImage: "chevron.left", enabled: canPageBackward, label: backwardLabel) {
                page(by: -1)
            }
            .offset(x: puckInset, y: chevronCenterY - puckHeight / 2)
        }
        .overlay(alignment: .topTrailing) {
            chevron(systemImage: "chevron.right", enabled: canPageForward, label: forwardLabel) {
                page(by: 1)
            }
            .offset(x: -puckInset, y: chevronCenterY - puckHeight / 2)
        }
        .onHover { rowHovered = $0 }
    }

    private var backwardLabel: String {
        contextLabel.map { "Scroll \($0) left" } ?? "Scroll left"
    }

    private var forwardLabel: String {
        contextLabel.map { "Scroll \($0) right" } ?? "Scroll right"
    }

    @ViewBuilder
    private func chevron(
        systemImage: String,
        enabled: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        let visible = rowHovered && enabled

        Button(action: action) {
            ShelfPagingButtonFace(systemImage: systemImage, style: controlStyle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!enabled)
        .animation(DesignTokens.Animation.quick, value: visible)
    }

    private func page(by direction: Int) {
        guard !items.isEmpty else { return }
        let target = min(max(leadingIndex + direction * perPage, 0), maxLeadingIndex)
        guard target != leadingIndex else { return }
        withAnimation(DesignTokens.Animation.standard) {
            leadingID = items[target].id
        }
    }
}

private struct ShelfViewportClip: Shape {
    let shadowOverflow: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: 0, dy: -shadowOverflow))
    }
}

private struct PagingRowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


/// Only the Recently Played control has this captured shape evidence. Other
/// shelves retain their previous appearance until their states are established.
enum ShelfPagingControlStyle {
    case circular
    case capturedRecentlyPlayed
}

struct ShelfPagingButtonFace: View {
    let systemImage: String
    let style: ShelfPagingControlStyle

    private var glyph: some View {
        // Native ColorShapeLayer is 8×29; its CGPath is not decoded yet.
        // Preserve the existing glyph rather than claiming a guessed replacement.
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }

    var body: some View {
        switch style {
        case .capturedRecentlyPlayed:
            // Aug22 05-home Response_0/4: frame28×52, cornerRadius14,
            // borderWidth0, shadowOpacity0. Native layered backdrop remains
            // unresolved; ultraThinMaterial is retained, not certified equivalent.
            glyph
                .frame(width: 28, height: 52)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        case .circular:
            glyph
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                }
                .shadow(
                    color: DesignTokens.Shadow.cardLight.color,
                    radius: DesignTokens.Shadow.cardLight.radius,
                    x: DesignTokens.Shadow.cardLight.x,
                    y: DesignTokens.Shadow.cardLight.y
                )
        }
    }
}
