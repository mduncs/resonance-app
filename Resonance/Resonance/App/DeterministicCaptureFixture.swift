import CoreGraphics
import Foundation

/// Launch-only configuration for deterministic parity captures.
///
/// This type has no effect unless one of the two explicit fixture gates is
/// present in the injected environment. The atlas gate is new; the legacy
/// `RESONANCE_CAPTURE_FIXTURE=now-playing` invocation remains supported for
/// existing capture scripts.
enum DeterministicCaptureFixture {
    // Legacy player fixture keys.
    static let environmentKey = "RESONANCE_CAPTURE_FIXTURE"
    static let stateEnvironmentKey = "RESONANCE_CAPTURE_STATE"
    static let appearanceEnvironmentKey = "RESONANCE_CAPTURE_APPEARANCE"

    // Atlas keys. Keep these literals stable: scripts use them as a narrow
    // launch contract rather than as app settings.
    static let parityFixtureEnvironmentKey = "RESONANCE_PARITY_FIXTURE"
    static let parityRouteEnvironmentKey = "RESONANCE_PARITY_ROUTE"
    static let parityStateEnvironmentKey = "RESONANCE_PARITY_STATE"
    static let parityAppearanceEnvironmentKey = "RESONANCE_PARITY_APPEARANCE"
    static let parityWidthEnvironmentKey = "RESONANCE_PARITY_WIDTH"
    static let parityHeightEnvironmentKey = "RESONANCE_PARITY_HEIGHT"
    static let parityBackgroundEnvironmentKey = "RESONANCE_PARITY_BACKGROUND"
    static let parityScratchRootEnvironmentKey = "RESONANCE_PARITY_SCRATCH_ROOT"
    static let parityWindowWidthEnvironmentKey = "RESONANCE_PARITY_WINDOW_WIDTH"
    static let parityWindowHeightEnvironmentKey = "RESONANCE_PARITY_WINDOW_HEIGHT"
    static let paritySupportsSeekingEnvironmentKey = "RESONANCE_PARITY_SUPPORTS_SEEKING"
    static let parityMultipleRoutesEnvironmentKey = "RESONANCE_PARITY_MULTIPLE_ROUTES"

    typealias Route = ParityFixtureRoute
    typealias State = ParityFixtureState

    static let routeManifest = ParityFixtureCatalog.routeManifest

    enum PlaybackMode: Sendable, Equatable {
        case paused
        case playing

        var isPlaying: Bool { self == .playing }
    }

    enum Appearance: String, Sendable, Equatable, Codable {
        case light
        case dark
    }

    enum Mode: String, Sendable, Equatable {
        case atlas
        case nowPlaying
    }

    struct Configuration: Sendable, Equatable {
        let mode: Mode
        let route: ParityFixtureRoute
        let state: ParityFixtureState
        let playbackMode: PlaybackMode
        let appearance: Appearance
        let duration: TimeInterval
        let currentTime: TimeInterval
        let supportsSeeking: Bool
        let multipleRoutesDetected: Bool
        let windowSize: CGSize
        let background: Bool
        let scratchRoot: URL?
        let usesScaleLibrary: Bool

        var isAtlas: Bool { mode == .atlas }
        var isLegacyNowPlaying: Bool { mode == .nowPlaying }
        var fixtureDatabaseURL: URL? {
            scratchRoot?.appendingPathComponent("resonance-parity-atlas.db", isDirectory: false)
        }

        init(
            mode: Mode = .atlas,
            route: ParityFixtureRoute = .home,
            state: ParityFixtureState = .paused,
            playbackMode: PlaybackMode? = nil,
            appearance: Appearance = .light,
            duration: TimeInterval = 240,
            currentTime: TimeInterval = 72,
            supportsSeeking: Bool = true,
            multipleRoutesDetected: Bool = false,
            windowSize: CGSize = CGSize(width: 1820, height: 1119),
            background: Bool = false,
            scratchRoot: URL? = nil,
            usesScaleLibrary: Bool = false
        ) {
            self.mode = mode
            self.route = route
            self.state = state
            self.playbackMode = playbackMode ?? (state == .playing ? .playing : .paused)
            self.appearance = appearance
            self.duration = duration
            self.currentTime = currentTime
            self.supportsSeeking = supportsSeeking
            self.multipleRoutesDetected = multipleRoutesDetected
            self.windowSize = windowSize
            self.background = background
            self.scratchRoot = scratchRoot
            self.usesScaleLibrary = mode == .atlas && usesScaleLibrary
        }

        var catalog: ParityFixtureCatalog {
            usesScaleLibrary ? .scale : .standard
        }
    }

    /// Legacy compatibility: true for atlas and now-playing gates, false for
    /// every other value. No process-global mutable state is used.
    static var isEnabled: Bool { configuration != nil }

    static var isAtlasEnabled: Bool { configuration?.mode == .atlas }

    /// Parse an injected environment dictionary. `configuration` below is the
    /// ProcessInfo wrapper used by the application.
    static func configuration(environment: [String: String]) -> Configuration? {
        let parityValue = normalized(environment[parityFixtureEnvironmentKey])
        let legacyValue = normalized(environment[environmentKey])

        if parityValue == "atlas" {
            return parseAtlasConfiguration(environment)
        }

        guard ["now-playing", "now_playing", "true", "yes", "1"].contains(legacyValue) else {
            return nil
        }

        let state = ParityFixtureState.parse(environment[stateEnvironmentKey]) ?? .paused
        let playbackMode: PlaybackMode = state == .playing ? .playing : .paused
        return Configuration(
            mode: .nowPlaying,
            route: .footer,
            state: state == .playing ? .playing : .paused,
            playbackMode: playbackMode,
            appearance: parseAppearance(environment[appearanceEnvironmentKey]),
            duration: 240,
            currentTime: 72,
            supportsSeeking: true,
            windowSize: CGSize(width: 1820, height: 1119),
            background: false,
            scratchRoot: nil
        )
    }

    /// ProcessInfo wrapper. Tests should use `configuration(environment:)` so
    /// they never need to mutate the process environment.
    static var configuration: Configuration? {
        configuration(environment: ProcessInfo.processInfo.environment)
    }

    private static func parseAtlasConfiguration(_ environment: [String: String]) -> Configuration {
        let route = ParityFixtureRoute.parse(environment[parityRouteEnvironmentKey]) ?? .home
        let state = ParityFixtureState.parse(environment[parityStateEnvironmentKey]) ?? defaultState(for: route)
        let width = parseDimension(
            environment[parityWidthEnvironmentKey] ?? environment[parityWindowWidthEnvironmentKey]
        ) ?? 1820
        let height = parseDimension(
            environment[parityHeightEnvironmentKey] ?? environment[parityWindowHeightEnvironmentKey]
        ) ?? 1119
        return Configuration(
            mode: .atlas,
            route: route,
            state: state,
            playbackMode: state == .playing ? .playing : .paused,
            appearance: parseAppearance(environment[parityAppearanceEnvironmentKey]),
            duration: 240,
            currentTime: 72,
            supportsSeeking: environment[paritySupportsSeekingEnvironmentKey].map { parseBoolean($0) } ?? true,
            multipleRoutesDetected: parseBoolean(environment[parityMultipleRoutesEnvironmentKey]),
            windowSize: CGSize(width: width, height: height),
            background: parseBoolean(environment[parityBackgroundEnvironmentKey]),
            scratchRoot: parseScratchRoot(environment[parityScratchRootEnvironmentKey]),
            usesScaleLibrary: normalized(environment["RESONANCE_PARITY_LIBRARY_SCALE"]) == "100k"
        )
    }

    private static func defaultState(for route: ParityFixtureRoute) -> ParityFixtureState {
        switch route {
        case .footer, .miniPlayerArtwork, .miniPlayerQueue, .fullscreenNowPlaying:
            return .paused
        case .lyrics, .miniPlayerLyrics:
            return .synced
        case .search, .searchNoResults:
            return .empty
        default:
            return .loaded
        }
    }

    private static func parseAppearance(_ rawValue: String?) -> Appearance {
        normalized(rawValue) == "dark" ? .dark : .light
    }

    private static func parseDimension(_ rawValue: String?) -> CGFloat? {
        guard let rawValue,
              let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite,
              value > 0,
              value <= 10_000 else {
            return nil
        }
        return CGFloat(value)
    }

    private static func parseBoolean(_ rawValue: String?) -> Bool {
        switch normalized(rawValue) {
        case "1", "true", "yes", "on", "background": return true
        default: return false
        }
    }

    private static func parseScratchRoot(_ rawValue: String?) -> URL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: rawValue, isDirectory: true)
    }

    private static func normalized(_ rawValue: String?) -> String {
        rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    /// Synthetic metadata retained for old player-only fixture callers.
    /// The atlas catalog is the richer source of truth for new launch wiring.
    static let songs: [Song] = [
        Song(
            id: "capture-fixture-song-01",
            title: "Fixture Song",
            album: "Fixture Album",
            albumId: "capture-fixture-album",
            artist: "Fixture Artist",
            artistId: "capture-fixture-artist",
            track: 1,
            discNumber: 1,
            year: 2026,
            genre: "Electronic",
            duration: 240,
            bitRate: 320,
            contentType: "audio/mpeg",
            suffix: "mp3",
            coverArt: nil,
            starred: nil,
            rating: nil,
            replayGain: nil,
            isExplicit: false,
            path: nil
        ),
        Song(
            id: "capture-fixture-song-02",
            title: "Fixture Encore",
            album: "Fixture Album",
            albumId: "capture-fixture-album",
            artist: "Fixture Artist",
            artistId: "capture-fixture-artist",
            track: 2,
            discNumber: 1,
            year: 2026,
            genre: "Electronic",
            duration: 240,
            bitRate: 320,
            contentType: "audio/mpeg",
            suffix: "mp3",
            coverArt: nil,
            starred: nil,
            rating: nil,
            replayGain: nil,
            isExplicit: false,
            path: nil
        )
    ]
}

#if DEBUG
import AppKit

/// Local control transport for explicitly enabled synthetic fixture processes.
/// The stdio MCP adapter lives outside the app; no listener or production API.
@MainActor
final class ParityControlBridge {
    static let shared = ParityControlBridge()
    private weak var appState: AppState?
    private var timer: Timer?
    private var directory: URL?
    private var busy = false
    // Registered by the mounted Songs view; updates its actual SwiftUI binding.
    var selectSongs: (([Int]) throws -> Void)?
    var songPagingSnapshot: (() -> [String: Int]?)?
    var detailSelectionSnapshot: (() -> [String: Any])?

    func start(appState: AppState) {
        guard timer == nil, DeterministicCaptureFixture.isAtlasEnabled,
              ProcessInfo.processInfo.environment["RESONANCE_PARITY_CONTROL"] == "1",
              let scratch = DeterministicCaptureFixture.configuration?.scratchRoot else { return }
        let root = scratch.resolvingSymlinksInPath()
        // Foundation may canonicalize the system /private/tmp alias back to
        // /tmp even after resolving symlinks.
        guard root.path.hasPrefix("/private/tmp/") || root.path.hasPrefix("/tmp/") else { return }
        let directory = root.appendingPathComponent("control", isDirectory: true)
        do {
            for name in ["requests", "responses"] {
                try FileManager.default.createDirectory(
                    at: directory.appendingPathComponent(name), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            self.directory = directory
            self.appState = appState
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                Task { @MainActor in await ParityControlBridge.shared.poll() }
            }
            print("[ParityControl] ready=\(directory.path)")
        } catch {
            print("[ParityControl] unavailable: \(error.localizedDescription)")
        }
    }

    private func poll() async {
        guard !busy, let directory, let appState else { return }
        busy = true
        defer { busy = false }
        let requests = directory.appendingPathComponent("requests")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: requests, includingPropertiesForKeys: nil) else { return }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "json", UUID(uuidString: id) != nil else { continue }
            var response: [String: Any] = ["id": id]
            do {
                let data = try Data(contentsOf: file)
                guard data.count <= 65_536,
                      let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      request["id"] as? String == id,
                      let method = request["method"] as? String else {
                    throw ControlError.invalid("Malformed request")
                }
                response["result"] = try await perform(method, params: request["params"] as? [String: Any] ?? [:], appState: appState)
            } catch {
                response["error"] = ["message": error.localizedDescription]
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
                try data.write(to: directory.appendingPathComponent("responses").appendingPathComponent(file.lastPathComponent), options: .atomic)
                try FileManager.default.removeItem(at: file)
            } catch {
                // Do not replay a mutation after an output failure.
                try? FileManager.default.removeItem(at: file)
                print("[ParityControl] response failure: \(error.localizedDescription)")
            }
        }
    }

    private enum ControlError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }

    private var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "mainWindow" }
    }

    private func songTable() -> NSTableView? {
        guard let root = window?.contentView else { return nil }
        var pending = [root]
        var matches: [NSTableView] = []
        while let view = pending.popLast() {
            if let table = view as? NSTableView, table.tableColumns.count > 3 { matches.append(table) }
            pending.append(contentsOf: view.subviews)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func searchField() -> NSSearchField? {
        // Toolbar controls are outside contentView. Inspect only this fixture's
        // own window hierarchy, never another process or the frontmost window.
        guard let root = window?.contentView?.superview else { return nil }
        var pending = [root]
        var matches: [NSSearchField] = []
        while let view = pending.popLast() {
            if let field = view as? NSSearchField { matches.append(field) }
            pending.append(contentsOf: view.subviews)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func footerVolumeSlider() -> NSSlider? {
        guard let root = window?.contentView else { return nil }
        var pending = [root]
        while let view = pending.popLast() {
            if let slider = view as? NSSlider,
               slider.accessibilityIdentifier() == "FooterVolumeSlider" { return slider }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func mountedView<T: NSView>(_ type: T.Type) -> T? {
        guard let root = window?.contentView else { return nil }
        var pending = [root]
        while let view = pending.popLast() {
            if let match = view as? T { return match }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func songColumnMenu() throws -> NSMenu {
        guard let window, let header = songTable()?.headerView,
              let event = NSEvent.mouseEvent(with: .rightMouseDown,
                location: header.convert(NSPoint(x: 30, y: 8), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0),
              let menu = header.menu(for: event) else {
            throw ControlError.invalid("Songs header does not supply a column menu")
        }
        // Construct the real menu without displaying it or posting the event.
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        return menu
    }

    private func menuItem(at path: [String]) throws -> NSMenuItem {
        guard !path.isEmpty, var menu = NSApp.mainMenu else { throw ControlError.invalid("Menu path required") }
        for (index, title) in path.enumerated() {
            // Match AppKit's lazy population before item validation. update()
            // alone can expose stale SwiftUI titles/enabled state.
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            guard let item = menu.items.first(where: { $0.title == title }) else {
                throw ControlError.invalid("Menu item not found: \(title)")
            }
            if index == path.count - 1 { return item }
            guard let submenu = item.submenu else { throw ControlError.invalid("Not a submenu: \(title)") }
            menu = submenu
        }
        throw ControlError.invalid("Menu path required")
    }

    private func describeMenu(_ menu: NSMenu) -> [[String: Any]] {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        return menu.items.map { item in
            var result: [String: Any] = ["title": item.title, "enabled": item.isEnabled,
                "separator": item.isSeparatorItem, "key": item.keyEquivalent,
                "modifiers": item.keyEquivalentModifierMask.rawValue, "state": item.state.rawValue]
            if let submenu = item.submenu { result["children"] = describeMenu(submenu) }
            return result
        }
    }

    private func perform(_ method: String, params: [String: Any], appState: AppState) async throws -> [String: Any] {
        switch method {
        case "snapshot":
            var result: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                "route": appState.selectedSidebarItem.rawValue, "isPlaying": appState.playbackManager.isPlaying,
                "windowIsKey": window?.isKeyWindow ?? false, "appIsActive": NSApp.isActive,
                "infoTitle": appState.getInfoContent?.title ?? NSNull() as Any,
                "nowPlayingID": appState.nowPlaying?.id ?? NSNull() as Any,
                "nowPlayingTitle": appState.nowPlaying?.title ?? NSNull() as Any]
            result["currentTime"] = appState.currentTime
            result["duration"] = appState.currentDuration
            result["volume"] = appState.volume
            result["navigationDepth"] = appState.detailNavigationPath.count
            result["canNavigateBack"] = appState.canNavigateBack
            result["canNavigateForward"] = appState.canNavigateForward
            if let path = appState.detailNavigationPath.codable,
               let data = try? JSONEncoder().encode(path) {
                result["navigationPath"] = try? JSONSerialization.jsonObject(with: data)
            }
            if let wheel = mountedView(FooterVolumeWheelRegion.self)?.controller {
                result["volumeTarget"] = wheel.targetVolume ?? NSNull() as Any
            }
            if let slider = footerVolumeSlider() {
                result["volumeSlider"] = ["value": slider.doubleValue,
                    "focusRingType": slider.focusRingType.rawValue, "enabled": slider.isEnabled]
            }
            result["selectedSongIDs"] = appState.songsInfoSelection.map(\.id)
            result["firstResponderClass"] = window?.firstResponder.map { String(describing: type(of: $0)) }
                ?? NSNull() as Any
            result["selectAllTargetClass"] = NSApp.target(
                forAction: NSSelectorFromString("selectAll:"), to: nil, from: nil
            ).map { String(describing: type(of: $0)) } ?? NSNull() as Any
            result["queueBaseSongIDs"] = appState.queueManager.baseItems.map { $0.song.id }
            result["queueBasePosition"] = appState.queueManager.basePosition
            if let detailSelectionSnapshot { result["detailSelection"] = detailSelectionSnapshot() }
            if let paging = songPagingSnapshot?() { result["songPaging"] = paging }
            if let table = songTable() {
                result["songTable"] = ["rowCount": table.numberOfRows, "selectedIndices": Array(table.selectedRowIndexes)]
                result["songColumns"] = table.tableColumns.map {
                    ["identifier": $0.identifier.rawValue, "title": $0.title,
                     "width": $0.width, "hidden": $0.isHidden] as [String: Any]
                }
            }
            result["searchText"] = searchField()?.stringValue ?? NSNull() as Any
            return result
        case "mouse_navigation":
            guard !NSApp.isActive, window?.isKeyWindow == false,
                  let button = params["button"] as? Int, [3, 4].contains(button),
                  let handler = mountedView(MouseNavigationNSView.self) else {
                throw ControlError.invalid("Background fixture and mouse navigation button 3/4 required")
            }
            return ["accepted": handler.navigate(mouseButton: button),
                    "navigationDepth": appState.detailNavigationPath.count,
                    "canNavigateBack": appState.canNavigateBack,
                    "canNavigateForward": appState.canNavigateForward]
        case "volume_scroll", "volume_closed_scroll":
            guard !NSApp.isActive, window?.isKeyWindow == false,
                  let x = params["x"] as? Int, let y = params["y"] as? Int,
                  (-1000...1000).contains(x), (-1000...1000).contains(y),
                  let precise = params["precise"] as? Bool,
                  let raw = CGEvent(scrollWheelEvent2Source: nil,
                    units: precise ? .pixel : .line, wheelCount: 2,
                    wheel1: Int32(y), wheel2: Int32(x), wheel3: 0),
                  let event = NSEvent(cgEvent: raw) else {
                throw ControlError.invalid("Background fixture and bounded scroll deltas required")
            }
            var consumed = true
            if method == "volume_closed_scroll" {
                guard footerVolumeSlider() == nil,
                      let region = mountedView(FooterVolumeWheelRegion.self) else {
                    throw ControlError.invalid("Closed volume button required")
                }
                let inside = params["inside"] as? Bool ?? true
                let point = NSPoint(x: inside ? region.bounds.midX : region.bounds.maxX + 10,
                                    y: region.bounds.midY)
                consumed = region.handleScrollWheel(event, in: window, at: region.convert(point, to: nil))
            } else {
                guard let slider = footerVolumeSlider() else { throw ControlError.invalid("Open volume slider required") }
                slider.scrollWheel(with: event)
            }
            return ["accepted": true, "consumed": consumed, "deltaX": event.scrollingDeltaX,
                    "deltaY": event.scrollingDeltaY, "precise": event.hasPreciseScrollingDeltas,
                    "volume": appState.volume,
                    "targetVolume": mountedView(FooterVolumeWheelRegion.self)?.controller?.targetVolume ?? NSNull() as Any]
        case "volume_pointer":
            guard !NSApp.isActive, window?.isKeyWindow == false,
                  let window, let slider = footerVolumeSlider(),
                  let percent = params["percent"] as? Int, (-100...200).contains(percent),
                  let phase = params["phase"] as? String,
                  let type = ["down": NSEvent.EventType.leftMouseDown,
                              "drag": .leftMouseDragged, "up": .leftMouseUp][phase],
                  let event = NSEvent.mouseEvent(with: type,
                    location: slider.convert(NSPoint(x: 8 + (slider.bounds.width - 16) * CGFloat(percent) / 100,
                                                     y: slider.bounds.midY), to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw ControlError.invalid("Open background fixture volume slider and valid pointer phase required")
            }
            // Call the actual control's event handlers without global mouse events.
            switch type {
            case .leftMouseDown: slider.mouseDown(with: event)
            case .leftMouseDragged: slider.mouseDragged(with: event)
            default: slider.mouseUp(with: event)
            }
            return ["accepted": true, "volume": appState.volume,
                    "sliderValue": slider.doubleValue, "focusRingType": slider.focusRingType.rawValue,
                    "appIsActive": NSApp.isActive, "windowIsKey": window.isKeyWindow]
        case "edit_search":
            guard !NSApp.isActive, window?.isKeyWindow == false else {
                throw ControlError.invalid("Background editing is disabled while the fixture is active or key")
            }
            guard let text = params["text"] as? String, text.count <= 512,
                  let window, let field = searchField(),
                  window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else {
                throw ControlError.invalid("A mounted native search field and at most 512 characters are required")
            }
            // Real AppKit text editing reaches the normal control/SwiftUI binding.
            // AXSetValue alone changes visible text without necessarily doing so.
            // No app activation, key-window change, global keys or pointer movement.
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            return ["accepted": true, "fieldValue": field.stringValue,
                    "appIsActive": NSApp.isActive, "windowIsKey": window.isKeyWindow]
        case "song_column_menu":
            return ["items": describeMenu(try songColumnMenu())]
        case "toggle_song_column":
            guard let title = params["title"] as? String else {
                throw ControlError.invalid("An exact column menu title is required")
            }
            let menu = try songColumnMenu()
            let matches = menu.items.enumerated().filter { $0.element.title == title }
            guard matches.count == 1, let match = matches.first,
                  match.element.isEnabled, match.element.submenu == nil, match.element.action != nil else {
                throw ControlError.invalid("An unambiguous enabled column menu item is required")
            }
            menu.performActionForItem(at: match.offset)
        case "navigate":
            guard let name = params["route"] as? String, let route = SidebarItem(rawValue: name) else {
                throw ControlError.invalid("Unknown sidebar route")
            }
            appState.selectedSidebarItem = route
        case "select_songs":
            guard appState.selectedSidebarItem == .songs, let table = songTable(), let selectSongs,
                  let indices = params["indices"] as? [Int],
                  indices.allSatisfy({ $0 >= 0 && $0 < table.numberOfRows }) else {
                throw ControlError.invalid("Loaded Songs table and valid visible row indices required")
            }
            try selectSongs(indices)
        case "pointer_move":
            guard let window,
                  let x = params["x"] as? Int, let y = params["y"] as? Int,
                  x >= 0, y >= 0, CGFloat(x) <= window.frame.width, CGFloat(y) <= window.frame.height,
                  let event = NSEvent.mouseEvent(with: .mouseMoved,
                    location: NSPoint(x: x, y: y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 0, pressure: 0) else {
                throw ControlError.invalid("Valid window-local integer coordinates required")
            }
            // Deliver only within this opt-in synthetic fixture. No CGEvent
            // posting, global cursor movement, key-window change or activation.
            window.acceptsMouseMovedEvents = true
            window.sendEvent(event)
            return ["accepted": true, "delivery": "app-local NSEvent.mouseMoved",
                    "windowIsKey": window.isKeyWindow, "appIsActive": NSApp.isActive]
        case "local_pointer":
            let delivery = (params["delivery"] as? String) ?? "window"
            guard !NSApp.isActive, let window,
                  let x = params["x"] as? Int, let y = params["y"] as? Int,
                  x >= 0, y >= 0, CGFloat(x) <= window.frame.width, CGFloat(y) <= window.frame.height,
                  let kind = params["kind"] as? String, ["left", "right"].contains(kind),
                  ["window", "application", "posted"].contains(delivery),
                  let modifiers = params["modifiers"] as? [String],
                  Set(modifiers).isSubset(of: ["command", "shift", "option"]),
                  let down = NSEvent.mouseEvent(with: kind == "right" ? .rightMouseDown : .leftMouseDown,
                    location: NSPoint(x: x, y: y), modifierFlags: eventModifiers(modifiers),
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: kind == "right" ? .rightMouseUp : .leftMouseUp,
                    location: NSPoint(x: x, y: y), modifierFlags: eventModifiers(modifiers),
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else {
                throw ControlError.invalid("Inactive fixture, bounded local point and modifiers required")
            }
            // Deliver normal AppKit window events to the mounted SwiftUI row;
            // never invoke the selection model or post a system-wide event.
            if delivery == "posted" {
                NSApp.postEvent(up, atStart: true)
                NSApp.postEvent(down, atStart: true)
            } else if delivery == "application" {
                NSApp.sendEvent(down)
                NSApp.sendEvent(up)
            } else {
                window.sendEvent(down)
                window.sendEvent(up)
            }
            return ["accepted": true, "delivery": "\(delivery).sendEvent mouseDown/mouseUp",
                    "eventModifiers": down.modifierFlags.rawValue,
                    "currentEventModifiers": NSApp.currentEvent?.modifierFlags.rawValue ?? NSNull() as Any,
                    "globalModifiers": NSEvent.modifierFlags.rawValue,
                    "windowIsKey": window.isKeyWindow, "appIsActive": NSApp.isActive]
        case "local_key":
            let delivery = (params["delivery"] as? String) ?? "window"
            guard !NSApp.isActive, let window,
                  ["window", "posted"].contains(delivery),
                  let key = params["key"] as? String,
                  let spec = ["up": ("\u{F700}", UInt16(126)),
                              "down": ("\u{F701}", UInt16(125)),
                              "return": ("\r", UInt16(36)),
                              "a": ("a", UInt16(0))][key],
                  let modifiers = params["modifiers"] as? [String],
                  Set(modifiers).isSubset(of: ["command", "shift", "option"]),
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: eventModifiers(modifiers), timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: spec.0, charactersIgnoringModifiers: spec.0,
                    isARepeat: false, keyCode: spec.1) else {
                throw ControlError.invalid("Inactive fixture and bounded local key required")
            }
            if delivery == "posted" { NSApp.postEvent(event, atStart: true) }
            else { window.sendEvent(event) }
            return ["accepted": true, "delivery": "\(delivery).sendEvent keyDown",
                    "eventModifiers": event.modifierFlags.rawValue,
                    "windowIsKey": window.isKeyWindow, "appIsActive": NSApp.isActive]
        case "focus_window":
            guard let window else { throw ControlError.invalid("Main window unavailable") }
            // Establish app-local key-window routing without activating the app,
            // ordering it forward, posting keystrokes, or moving the pointer.
            window.makeKey()
            return ["accepted": true, "windowIsKey": window.isKeyWindow, "appIsActive": NSApp.isActive]
        case "menu":
            let path = params["path"] as? [String] ?? []
            let menu: NSMenu?
            if path.isEmpty { menu = NSApp.mainMenu } else { menu = try menuItem(at: path).submenu }
            guard let menu else { throw ControlError.invalid("Menu unavailable") }
            return ["items": describeMenu(menu)]
        case "invoke_menu":
            guard let path = params["path"] as? [String] else { throw ControlError.invalid("Menu path required") }
            let item = try menuItem(at: path)
            guard item.isEnabled, !item.isSeparatorItem, item.submenu == nil,
                  let menu = item.menu, menu.index(of: item) >= 0 else {
                throw ControlError.invalid("Menu command unavailable or disabled")
            }
            menu.performActionForItem(at: menu.index(of: item))
        case "playback":
            switch params["action"] as? String {
            case "play_pause": await appState.playbackManager.togglePlayPause()
            case "next": await appState.playbackManager.next()
            case "previous": await appState.playbackManager.previous()
            case "stop": await appState.playbackManager.stop()
            default: throw ControlError.invalid("Unknown playback action")
            }
        case "dismiss_info":
            appState.getInfoContent = nil
        default:
            throw ControlError.invalid("Unknown control method")
        }
        return ["accepted": true]
    }

    private func eventModifiers(_ names: [String]) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if names.contains("command") { result.insert(.command) }
        if names.contains("shift") { result.insert(.shift) }
        if names.contains("option") { result.insert(.option) }
        return result
    }
}
#endif
