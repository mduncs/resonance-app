import SwiftUI

// MARK: - Grid Navigation Helper

/// Calculates the next index for arrow key navigation in a grid
struct GridNavigator {
    let itemCount: Int
    let columnsPerRow: Int

    func navigate(from currentIndex: Int?, direction: KeyEquivalent) -> Int? {
        guard itemCount > 0 else { return nil }

        let current = currentIndex ?? 0

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
    let items: [Item]
    let columns: [GridItem]
    let spacing: CGFloat
    @Binding var selectedId: Item.ID?
    let onActivate: (Item) -> Void
    let itemContent: (Item) -> ItemContent

    @FocusState private var focusedId: Item.ID?
    @State private var estimatedColumnsPerRow: Int = 4

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
            withAnimation {
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

    // Volume step sizes
    private let smallVolumeStep: Float = 0.05  // 5%
    private let largeVolumeStep: Float = 0.15  // 15%
    // Seek step size
    private let seekStep: TimeInterval = 5.0  // 5 seconds

    func body(content: Content) -> some View {
        content
            // Space: Play/Pause
            .onKeyPress(.space, phases: .down) { _ in
                Task { await appState.playbackManager.togglePlayPause() }
                return .handled
            }
            // Command+Left: Previous track
            .onKeyPress(.leftArrow, phases: .down) { press in
                if press.modifiers.contains(.command) {
                    Task { await appState.playbackManager.previous() }
                    return .handled
                }
                return .ignored
            }
            // Command+Right: Next track
            .onKeyPress(.rightArrow, phases: .down) { press in
                if press.modifiers.contains(.command) {
                    Task { await appState.playbackManager.next() }
                    return .handled
                }
                return .ignored
            }
            // Left arrow (no modifier): Seek back 5 seconds
            .onKeyPress(.leftArrow, phases: .down) { press in
                if press.modifiers.isEmpty {
                    let newTime = max(0, appState.currentTime - seekStep)
                    Task { await appState.playbackManager.seek(to: newTime) }
                    return .handled
                }
                return .ignored
            }
            // Right arrow (no modifier): Seek forward 5 seconds
            .onKeyPress(.rightArrow, phases: .down) { press in
                if press.modifiers.isEmpty {
                    let newTime = min(appState.duration, appState.currentTime + seekStep)
                    Task { await appState.playbackManager.seek(to: newTime) }
                    return .handled
                }
                return .ignored
            }
            // Up arrow: Volume up (small step)
            .onKeyPress(.upArrow, phases: .down) { press in
                if press.modifiers.isEmpty {
                    appState.volume = min(1.0, appState.volume + smallVolumeStep)
                    return .handled
                }
                return .ignored
            }
            // Down arrow: Volume down (small step)
            .onKeyPress(.downArrow, phases: .down) { press in
                if press.modifiers.isEmpty {
                    appState.volume = max(0, appState.volume - smallVolumeStep)
                    return .handled
                }
                return .ignored
            }
            // Command+Up: Volume up (large step)
            .onKeyPress(.upArrow, phases: .down) { press in
                if press.modifiers.contains(.command) && !press.modifiers.contains(.shift) {
                    appState.volume = min(1.0, appState.volume + largeVolumeStep)
                    return .handled
                }
                return .ignored
            }
            // Command+Down: Volume down (large step)
            .onKeyPress(.downArrow, phases: .down) { press in
                if press.modifiers.contains(.command) && !press.modifiers.contains(.shift) {
                    appState.volume = max(0, appState.volume - largeVolumeStep)
                    return .handled
                }
                return .ignored
            }
            // Command+L: Toggle lyrics panel
            .onKeyPress(keys: [KeyEquivalent("l")], phases: .down) { press in
                if press.modifiers.contains(.command) && !press.modifiers.contains(.option) && !press.modifiers.contains(.shift) {
                    appState.isLyricsPanelVisible.toggle()
                    return .handled
                }
                return .ignored
            }
            // Command+Option+Right: Toggle queue panel
            .onKeyPress(.rightArrow, phases: .down) { press in
                if press.modifiers.contains(.command) && press.modifiers.contains(.option) {
                    appState.isQueueVisible.toggle()
                    return .handled
                }
                return .ignored
            }
            // Command+F: Focus search
            .onKeyPress(keys: [KeyEquivalent("f")], phases: .down) { press in
                if press.modifiers.contains(.command) && !press.modifiers.contains(.shift) {
                    appState.shouldFocusSearch = true
                    return .handled
                }
                return .ignored
            }
            // Command+S: Toggle shuffle
            .onKeyPress(keys: [KeyEquivalent("s")], phases: .down) { press in
                if press.modifiers.contains(.command) && !press.modifiers.contains(.shift) {
                    appState.shuffleEnabled.toggle()
                    return .handled
                }
                return .ignored
            }
            // Command+R: Cycle repeat mode
            .onKeyPress(keys: [KeyEquivalent("r")], phases: .down) { press in
                if press.modifiers.contains(.command) && !press.modifiers.contains(.shift) {
                    appState.playbackManager.cycleRepeatMode()
                    return .handled
                }
                return .ignored
            }
            // Command+0: Toggle MiniPlayer
            .onKeyPress(keys: [KeyEquivalent("0")], phases: .down) { press in
                if press.modifiers.contains(.command) && !press.modifiers.contains(.shift) {
                    appState.showMiniPlayer()
                    return .handled
                }
                return .ignored
            }
            // Command+Shift+F: Toggle fullscreen/immersive mode
            .onKeyPress(keys: [KeyEquivalent("f")], phases: .down) { press in
                if press.modifiers.contains(.command) && press.modifiers.contains(.shift) {
                    appState.enterImmersiveMode()
                    return .handled
                }
                return .ignored
            }
            // Command+N: New playlist
            .onKeyPress(keys: [KeyEquivalent("n")], phases: .down) { press in
                if press.modifiers.contains(.command) && !press.modifiers.contains(.shift) {
                    appState.createPlaylistSongIds = []
                    appState.showCreatePlaylistSheet = true
                    return .handled
                }
                return .ignored
            }
            // Command+I: Get info for now playing
            .onKeyPress(keys: [KeyEquivalent("i")], phases: .down) { press in
                if press.modifiers.contains(.command) && !press.modifiers.contains(.shift) {
                    if let song = appState.nowPlaying {
                        appState.getInfoContent = .song(song)
                    }
                    return .handled
                }
                return .ignored
            }
            // Command+M: Minimize window
            .onKeyPress(keys: [KeyEquivalent("m")], phases: .down) { press in
                if press.modifiers.contains(.command) && !press.modifiers.contains(.shift) {
                    NSApp.keyWindow?.miniaturize(nil)
                    return .handled
                }
                return .ignored
            }
            // Command+W: Close window
            .onKeyPress(keys: [KeyEquivalent("w")], phases: .down) { press in
                if press.modifiers.contains(.command) && !press.modifiers.contains(.shift) {
                    NSApp.keyWindow?.close()
                    return .handled
                }
                return .ignored
            }
            // Command+.: Stop playback
            .onKeyPress(keys: [KeyEquivalent(".")], phases: .down) { press in
                if press.modifiers.contains(.command) && !press.modifiers.contains(.shift) {
                    Task { await appState.playbackManager.stop() }
                    return .handled
                }
                return .ignored
            }
            // Delete/Backspace: Remove selected item from queue
            .onKeyPress(.delete, phases: .down) { _ in
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
}

class MouseNavigationNSView: NSView {
    var appState: AppState?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            // Monitor for mouse button events globally within the app
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                self?.handleMouseButton(event)
                return event
            }
        }
    }

    override func removeFromSuperview() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        super.removeFromSuperview()
    }

    private func handleMouseButton(_ event: NSEvent) {
        guard let appState = appState else { return }

        switch event.buttonNumber {
        case 3: // Mouse button 4 (back)
            if !appState.detailNavigationPath.isEmpty {
                appState.detailNavigationPath.removeLast()
            }
        case 4: // Mouse button 5 (forward)
            // Forward navigation would require history tracking
            // For now, this is a no-op
            break
        default:
            break
        }
    }
}
