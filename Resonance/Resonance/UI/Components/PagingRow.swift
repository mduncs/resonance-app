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
    @ViewBuilder let content: (Item) -> Content

    @State private var leadingID: Item.ID?
    @State private var viewportWidth: CGFloat = 0
    @State private var rowHovered = false

    private let puckSize: CGFloat = 32
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
        .scrollIndicators(.hidden)
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
            .offset(x: puckInset, y: chevronCenterY - puckSize / 2)
        }
        .overlay(alignment: .topTrailing) {
            chevron(systemImage: "chevron.right", enabled: canPageForward, label: forwardLabel) {
                page(by: 1)
            }
            .offset(x: -puckInset, y: chevronCenterY - puckSize / 2)
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
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: puckSize, height: puckSize)
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

private struct PagingRowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
