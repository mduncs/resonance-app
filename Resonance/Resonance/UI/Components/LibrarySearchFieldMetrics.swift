import AppKit
import SwiftUI

/// Preserve SwiftUI's native search field and editing behavior while matching
/// the 222×38 field recorded in the 1000/1500-point Music library captures.
struct LibrarySearchFieldMetrics: NSViewRepresentable {
    func makeNSView(context: Context) -> MetricView { MetricView() }
    func updateNSView(_ view: MetricView, context: Context) { view.scheduleConfiguration() }
    static func dismantleNSView(_ view: MetricView, coordinator: ()) { view.deactivate() }

    final class MetricView: NSView {
        // AppKit's AX frame includes two points outside this content width.
        private let contentWidth: CGFloat = 220
        private var lifecycle = LibrarySearchFieldLifecycle()
        private weak var observedWindow: NSWindow?
        private var ownershipToken: UInt64 = 0
        private var configurationScheduled = false
        private var delayedConfigurations: [DispatchWorkItem] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== observedWindow else {
                scheduleConfiguration()
                return
            }
            deactivate()
            guard let window else { return }
            observedWindow = window
            let generation = lifecycle.activate()
            ownershipToken = LibrarySearchFieldCoordinator.shared.makeOwnershipToken()
            scheduleConfiguration()
            // SwiftUI can install the toolbar after the content view mounts.
            for delay in [0.1, 0.3] {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.lifecycle.permits(generation) else { return }
                    self.configure(generation: generation)
                }
                delayedConfigurations.append(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }

        func scheduleConfiguration() {
            guard lifecycle.isActive, !configurationScheduled else { return }
            configurationScheduled = true
            let generation = lifecycle.generation
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configurationScheduled = false
                guard self.lifecycle.permits(generation) else { return }
                self.configure(generation: generation)
            }
        }

        private func configure(generation: UInt64) {
            guard lifecycle.permits(generation), let window, window === observedWindow else { return }
            let items = window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem } ?? []
            guard items.count == 1, let candidate = items.first else { return }
            LibrarySearchFieldCoordinator.shared.claim(
                owner: self,
                token: ownershipToken,
                window: window,
                item: candidate,
                contentWidth: contentWidth
            )
        }

        func deactivate() {
            let previousWindow = observedWindow
            lifecycle.deactivate()
            configurationScheduled = false
            delayedConfigurations.forEach { $0.cancel() }
            delayedConfigurations.removeAll()
            if let previousWindow {
                LibrarySearchFieldCoordinator.shared.release(
                    owner: self,
                    token: ownershipToken,
                    window: previousWindow
                )
            }
            observedWindow = nil
            ownershipToken = 0
        }
    }
}

/// Small value seam used by deferred callbacks so work from a dismantled or
/// remounted representable cannot mutate the window toolbar.
struct LibrarySearchFieldLifecycle {
    private(set) var generation: UInt64 = 0
    private(set) var isActive = false

    mutating func activate() -> UInt64 {
        generation &+= 1
        isActive = true
        return generation
    }

    mutating func deactivate() {
        generation &+= 1
        isActive = false
    }

    func permits(_ candidate: UInt64) -> Bool {
        isActive && generation == candidate
    }
}

/// Owns the one AppKit constraint for a window's native SwiftUI search item.
/// During route transitions the newest mounted probe wins; an older probe's
/// delayed callback cannot steal ownership or restore the new owner's item.
@MainActor
private final class LibrarySearchFieldCoordinator {
    static let shared = LibrarySearchFieldCoordinator()

    private final class WindowState {
        weak var window: NSWindow?
        weak var owner: LibrarySearchFieldMetrics.MetricView?
        weak var item: NSSearchToolbarItem?
        weak var field: NSSearchField?
        var ownerToken: UInt64 = 0
        var previousPreferredWidth: CGFloat?
        var widthConstraint: NSLayoutConstraint?
    }

    private var nextToken: UInt64 = 0
    private var states: [ObjectIdentifier: WindowState] = [:]

    func makeOwnershipToken() -> UInt64 {
        nextToken &+= 1
        return nextToken
    }

    func claim(
        owner: LibrarySearchFieldMetrics.MetricView,
        token: UInt64,
        window: NSWindow,
        item: NSSearchToolbarItem,
        contentWidth: CGFloat
    ) {
        removeReleasedWindows()
        let key = ObjectIdentifier(window)
        let state = states[key] ?? WindowState()
        if states[key] == nil {
            state.window = window
            states[key] = state
        }

        guard state.owner === owner || token >= state.ownerToken else { return }
        let field = item.searchField
        if state.owner === owner, state.item === item, state.field === field,
           state.widthConstraint?.isActive == true,
           item.preferredWidthForSearchField == contentWidth {
            return
        }

        restore(state)
        state.owner = owner
        state.ownerToken = token
        state.item = item
        state.field = field
        if item.preferredWidthForSearchField != contentWidth {
            state.previousPreferredWidth = item.preferredWidthForSearchField
            item.preferredWidthForSearchField = contentWidth
        }

        // AppKit explicitly supports updating this constraint after assigning
        // preferredWidthForSearchField. Exactly one coordinator-owned constraint
        // remains active for the current window/item.
        let constraint = field.widthAnchor.constraint(equalToConstant: contentWidth)
        constraint.priority = NSLayoutConstraint.Priority(999)
        constraint.identifier = "Resonance.LibrarySearchWidth"
        constraint.isActive = true
        state.widthConstraint = constraint
    }

    func release(
        owner: LibrarySearchFieldMetrics.MetricView,
        token: UInt64,
        window: NSWindow
    ) {
        let key = ObjectIdentifier(window)
        guard let state = states[key], state.owner === owner, state.ownerToken == token else { return }
        restore(state)
        states.removeValue(forKey: key)
    }

    private func restore(_ state: WindowState) {
        state.widthConstraint?.isActive = false
        state.widthConstraint = nil
        if let item = state.item,
           let previousPreferredWidth = state.previousPreferredWidth,
           item.preferredWidthForSearchField == 220 {
            item.preferredWidthForSearchField = previousPreferredWidth
        }
        state.owner = nil
        state.item = nil
        state.field = nil
        state.ownerToken = 0
        state.previousPreferredWidth = nil
    }

    private func removeReleasedWindows() {
        states = states.filter { $0.value.window != nil }
    }
}
