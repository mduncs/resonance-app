import SwiftUI

// MARK: - Grid Navigation Helper

/// Calculates the next index for arrow key navigation in a grid
struct GridNavigator {
    let itemCount: Int
    let columnsPerRow: Int

    func navigate(from currentIndex: Int?, direction: KeyEquivalent) -> Int? {
        guard itemCount > 0 else { return nil }
        // Starting keyboard navigation should land on the first item. Treating
        // nil as index zero and then applying the arrow skipped the first item
        // (and could jump an entire row on Down).
        guard let currentIndex else { return 0 }
        let current = min(max(currentIndex, 0), itemCount - 1)

        switch direction {
        case .leftArrow:
            return current > 0 ? current - 1 : current
        case .rightArrow:
            return current < itemCount - 1 ? current + 1 : current
        case .upArrow:
            let newIndex = current - columnsPerRow
            return newIndex >= 0 ? newIndex : current
        case .downArrow:
            let newIndex = current + columnsPerRow
            return newIndex < itemCount ? newIndex : current
        default:
            return current
        }
    }
}

// MARK: - Focusable Grid Item

/// A focusable wrapper for grid items with keyboard support
struct FocusableGridItem<Content: View>: View {
    let isSelected: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    let content: () -> Content

    @FocusState private var isFocused: Bool

    init(
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onActivate = onActivate
        self.content = content
    }

    var body: some View {
        content()
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 3)
                }
            }
            .onTapGesture {
                onSelect()
            }
            .onTapGesture(count: 2) {
                onActivate()
            }
            .onKeyPress(.return) {
                onActivate()
                return .handled
            }
            .onKeyPress(.space) {
                onSelect()
                return .handled
            }
            .onChange(of: isFocused) { _, newValue in
                if newValue {
                    onSelect()
                }
            }
    }
}

// MARK: - Keyboard Navigable Grid

/// A LazyVGrid with built-in keyboard navigation
struct KeyboardNavigableGrid<Item: Identifiable, ItemContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: [Item]
    let columns: [GridItem]
    let spacing: CGFloat
    @Binding var selectedId: Item.ID?
    let onActivate: (Item) -> Void
    let itemContent: (Item) -> ItemContent

    @FocusState private var focusedId: Item.ID?
    @State private var viewportWidth: CGFloat = 0

    private var estimatedColumnsPerRow: Int {
        guard columns.count == 1, let column = columns.first,
              case .adaptive(let minimum, _) = column.size else {
            return max(1, columns.count)
        }

        guard viewportWidth > 0 else { return 1 }
        let columnSpacing = column.spacing ?? 8
        return max(1, Int((viewportWidth + columnSpacing) / (minimum + columnSpacing)))
    }

    init(
        items: [Item],
        columns: [GridItem],
        spacing: CGFloat = 20,
        selectedId: Binding<Item.ID?>,
        onActivate: @escaping (Item) -> Void,
        @ViewBuilder itemContent: @escaping (Item) -> ItemContent
    ) {
        self.items = items
        self.columns = columns
        self.spacing = spacing
        self._selectedId = selectedId
        self.onActivate = onActivate
        self.itemContent = itemContent
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        itemContent(item)
                            .id(item.id)
                            .focusable()
                            .focused($focusedId, equals: item.id)
                            .focusEffectDisabled()
                            .overlay {
                                if selectedId == item.id {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.accentColor, lineWidth: 3)
                                }
                            }
                            .onTapGesture {
                                selectedId = item.id
                                focusedId = item.id
                            }
                            .onTapGesture(count: 2) {
                                onActivate(item)
                            }
                    }
                }
                .padding()
            }
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { viewportWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in
                            viewportWidth = width
                        }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                handleArrowKey(press.key, proxy: proxy)
            }
            .onKeyPress(.return) {
                if let id = selectedId, let item = items.first(where: { $0.id == id }) {
                    onActivate(item)
                    return .handled
                }
                return .ignored
            }
            .onChange(of: focusedId) { _, newValue in
                if let newValue {
                    selectedId = newValue
                }
            }
        }
    }

    private func handleArrowKey(_ key: KeyEquivalent, proxy: ScrollViewProxy) -> KeyPress.Result {
        let navigator = GridNavigator(itemCount: items.count, columnsPerRow: estimatedColumnsPerRow)

        let currentIndex: Int?
        if let selectedId {
            currentIndex = items.firstIndex(where: { $0.id == selectedId })
        } else {
            currentIndex = nil
        }

        if let newIndex = navigator.navigate(from: currentIndex, direction: key),
           newIndex >= 0, newIndex < items.count {
            let newId = items[newIndex].id
            selectedId = newId
            focusedId = newId
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                proxy.scrollTo(newId, anchor: .center)
            }
            return .handled
        }
        return .ignored
    }
}

// MARK: - View Extension for Escape Key

extension View {
    /// Adds escape key handling to clear search or dismiss
    func onEscapeKey(perform action: @escaping () -> Void) -> some View {
        self.onKeyPress(.escape) {
            action()
            return .handled
        }
    }
}

// MARK: - Global Keyboard Shortcuts (Apple Music Style)

/// Handles global keyboard shortcuts matching Apple Music behavior
struct GlobalKeyboardShortcuts: ViewModifier {
    @Environment(AppState.self) private var appState

    // MARK: Routing contract
    //
    // Command-key equivalents are owned by the app menu registries in
    // ResonanceApp.swift (Playback/View/Song/File) and dispatch before this
    // modifier ever sees the event; duplicating them here creates silent
    // second routes that drift apart. This modifier therefore carries only
    // bindings no menu declares: unmodified transport keys, ⌘R repeat
    // cycling, and Delete-to-remove in the visible queue.

    /// True while the user is typing into a text control. Unmodified keys
    /// must yield to text entry instead of scrubbing playback, stepping
    /// volume, or deleting queue items underneath the field editor.
    private var isTextEntryActive: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    // Transport step sizes
    private let smallVolumeStep: Float = 0.05  // 5%
    private let seekStep: TimeInterval = 5.0  // 5 seconds

    func body(content: Content) -> some View {
        content
            // Space: play/pause. Bare Space appears in no menu, so this is
            // the only route.
            .onKeyPress(.space, phases: .down) { _ in
                guard !isTextEntryActive else { return .ignored }
                Task { await appState.playbackManager.togglePlayPause() }
                return .handled
            }
            // Left arrow: seek back five seconds
            .onKeyPress(.leftArrow, phases: .down) { press in
                guard press.modifiers.isEmpty, !isTextEntryActive else { return .ignored }
                let newTime = max(0, appState.currentTime - seekStep)
                Task { await appState.playbackManager.seek(to: newTime) }
                return .handled
            }
            // Right arrow: seek forward five seconds
            .onKeyPress(.rightArrow, phases: .down) { press in
                guard press.modifiers.isEmpty, !isTextEntryActive else { return .ignored }
                let newTime = min(appState.duration, appState.currentTime + seekStep)
                Task { await appState.playbackManager.seek(to: newTime) }
                return .handled
            }
            // Up/down arrows: volume in small steps. The Playback menu owns
            // ⌘↑/⌘↓ for the large step.
            .onKeyPress(.upArrow, phases: .down) { press in
                guard press.modifiers.isEmpty, !isTextEntryActive else { return .ignored }
                appState.volume = min(1.0, appState.volume + smallVolumeStep)
                return .handled
            }
            .onKeyPress(.downArrow, phases: .down) { press in
                guard press.modifiers.isEmpty, !isTextEntryActive else { return .ignored }
                appState.volume = max(0, appState.volume - smallVolumeStep)
                return .handled
            }
            // Delete: remove the selected queue item, but only while the
            // queue inspector is open and nothing is being typed. A bare
            // Delete elsewhere in the app must never mutate the queue.
            .onKeyPress(.delete, phases: .down) { _ in
                guard !isTextEntryActive,
                      appState.nowPlayingInspector == .queue else { return .ignored }
                appState.removeSelectedQueueItem()
                return .handled
            }
    }
}

extension View {
    /// Applies Apple Music-style global keyboard shortcuts
    func globalKeyboardShortcuts() -> some View {
        self.modifier(GlobalKeyboardShortcuts())
    }

    /// Handles mouse button 4/5 for back/forward navigation
    func mouseNavigationHandler(appState: AppState) -> some View {
        self.modifier(MouseNavigationModifier(appState: appState))
    }
}

// MARK: - Mouse Button Navigation (Back/Forward)

struct MouseNavigationModifier: ViewModifier {
    let appState: AppState

    func body(content: Content) -> some View {
        content
            .background(MouseNavigationView(appState: appState))
    }
}

struct MouseNavigationView: NSViewRepresentable {
    let appState: AppState

    func makeNSView(context: Context) -> MouseNavigationNSView {
        let view = MouseNavigationNSView()
        view.appState = appState
        return view
    }

    func updateNSView(_ nsView: MouseNavigationNSView, context: Context) {
        nsView.appState = appState
    }

    static func dismantleNSView(_ nsView: MouseNavigationNSView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

class MouseNavigationNSView: NSView {
    var appState: AppState?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        if window != nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                guard let self, event.window === self.window,
                      self.window?.attachedSheet == nil else { return event }
                return self.navigate(mouseButton: event.buttonNumber) ? nil : event
            }
        }
    }

    override func removeFromSuperview() {
        stopMonitoring()
        super.removeFromSuperview()
    }

    func stopMonitoring() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    @discardableResult
    func navigate(mouseButton: Int) -> Bool {
        guard let appState else { return false }
        switch mouseButton {
        case 3: // Mouse button 4 (back)
            appState.navigateBack()
        case 4: // Mouse button 5 (forward)
            appState.navigateForward()
        default:
            return false
        }
        return true
    }
}
