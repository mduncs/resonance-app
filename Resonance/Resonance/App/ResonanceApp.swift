import AppKit
import SwiftUI

@main
struct ResonanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @State private var emotionEngine = EmotionEngine()
    @AppStorage("appTheme") private var appTheme = "System"
    @AppStorage("showMenuBarPlayer") private var showMenuBarPlayer = true
    @AppStorage("accentColorOption") private var accentColorOption = "Blue"

    private var menuBarPlayerInsertion: Binding<Bool> {
        // MenuBarExtra persists its own NSStatusItem visibility key even when
        // given a constant false binding. Preserve the user's existing value
        // in fixture mode while preventing the fixture from changing it.
        DeterministicCaptureFixture.isEnabled ? .constant(showMenuBarPlayer) : $showMenuBarPlayer
    }

    private var preferredColorScheme: ColorScheme? {
        if let fixture = DeterministicCaptureFixture.configuration {
            switch fixture.appearance {
            case .light: return .light
            case .dark: return .dark
            }
        }

        switch appTheme {
        case "Light": return .light
        case "Dark": return .dark
        default: return nil // System
        }
    }

    private var defaultWindowSize: CGSize {
        DeterministicCaptureFixture.configuration?.windowSize
            ?? CGSize(width: 1200, height: 800)
    }

    private var accentColor: Color {
        if DeterministicCaptureFixture.isEnabled {
            // Captured System.controlAccentColor in light Songs12 and verified
            // DarkAqua General02 resolves to the same explicit sRGB components.
            return Color(.sRGB, red: 247.0 / 255, green: 79.0 / 255,
                         blue: 158.0 / 255, opacity: 1)
        }

        switch accentColorOption {
        case "Purple": return .purple
        case "Pink": return .pink
        case "Red": return .red
        case "Orange": return .orange
        case "Yellow": return .yellow
        case "Green": return .green
        case "Graphite": return .gray
        default: return .blue
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(\.emotionEngine, emotionEngine)
                .preferredColorScheme(preferredColorScheme)
                .accentColor(DeterministicCaptureFixture.isEnabled ? accentColor : nil)
                .tint(accentColor)
                .background(MainWindowIdentifierView())
                .onAppear {
                    // Wire up emotion engine for window management
                    appState.emotionEngine = emotionEngine
                    // Wire up AppState for dock menu
                    appDelegate.appState = appState
                    #if DEBUG
                    ParityControlBridge.shared.start(appState: appState)
                    #endif
                    appState.presentFixtureAuxiliaryWindowIfNeeded()
                    appState.scheduleFixtureAuditIfNeeded()
                    appState.scheduleNormalSmokeAuditIfRequested()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Playlist...") {
                    appState.createPlaylistSongIds = []
                    appState.showCreatePlaylistSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Curation Command…") {
                    appState.isCommandHUDVisible = true
                }
                .keyboardShortcut("k", modifiers: .command)


            }
            PlaybackCommands(appState: appState)
            SongCommands(appState: appState)
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    if let url = URL(string: "https://github.com/mduncs/resonance-app#keyboard-shortcuts") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Report an Issue...") {
                    if let url = URL(string: "https://github.com/mduncs/resonance-app/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Settings {
            if DeterministicCaptureFixture.isEnabled {
                FixtureSettingsUnavailableView()
                    .preferredColorScheme(preferredColorScheme)
                    .tint(accentColor)
            } else {
                SettingsView()
                    .environment(appState)
                    .preferredColorScheme(preferredColorScheme)
                    .accentColor(nil)
                    .tint(accentColor)
            }
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Resonance", systemImage: "music.note", isInserted: menuBarPlayerInsertion) {
            MenuBarPlayerView()
                .environment(appState)
                .preferredColorScheme(preferredColorScheme)
                .accentColor(DeterministicCaptureFixture.isEnabled ? accentColor : nil)
                .tint(accentColor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// A fixture-safe placeholder: do not construct SettingsView here because its
/// @AppStorage bindings and Reset All action intentionally target user defaults.
private struct FixtureSettingsUnavailableView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Settings are unavailable in fixture mode")
                .font(.headline)
            Text("This isolated QA fixture does not open or modify the user's settings.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(minWidth: 400, minHeight: 180)
    }
}

/// Gives the primary SwiftUI window a stable AppKit identity so auxiliary
/// windows can hide and restore it without confusing it with Settings.
private struct MainWindowIdentifierView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MainWindowIdentifierNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class MainWindowIdentifierNSView: NSView {
    private var didConfigureCaptureWindow = false

    private var isBackgroundNormalSmokeLaunch: Bool {
        guard !DeterministicCaptureFixture.isEnabled else { return false }
        switch ProcessInfo.processInfo.environment["RESONANCE_NORMAL_SMOKE_BACKGROUND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "1", "true", "yes", "on", "background": return true
        default: return false
        }
    }

    private var isBackgroundFixtureLaunch: Bool {
        guard DeterministicCaptureFixture.isEnabled else { return false }
        switch ProcessInfo.processInfo.environment["RESONANCE_PARITY_BACKGROUND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "1", "true", "yes": return true
        default: return false
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.identifier = NSUserInterfaceItemIdentifier("mainWindow")

        if isBackgroundNormalSmokeLaunch {
            DispatchQueue.main.async { [weak self] in
                self?.window?.orderBack(nil)
            }
            return
        }

        guard !didConfigureCaptureWindow,
              let fixture = DeterministicCaptureFixture.configuration else {
            return
        }

        didConfigureCaptureWindow = true
        DispatchQueue.main.async { [weak self] in
            self?.configureFixtureWindow(fixture)
        }

        // AppDelegate honors the user's normal Start Minimized preference. A
        // fixture launch must remain visible, so bring this explicit capture
        // window back after that normal-path delay without changing the saved
        // preference.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let window = self.window else { return }
            self.disableFixturePersistence(in: window)
            guard !self.isBackgroundFixtureLaunch else { return }
            window.makeKeyAndOrderFront(nil)
        }

        // SwiftUI installs its split-view autosave name after constructing the
        // representable. Clear it once more after the hierarchy has settled so
        // a capture launch cannot create a production UserDefaults key.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let window = self.window else { return }
            self.disableFixturePersistence(in: window)
        }
    }

    private func configureFixtureWindow(
        _ fixture: DeterministicCaptureFixture.Configuration
    ) {
        guard let window else { return }

        disableFixturePersistence(in: window)

        let targetSize = fixture.windowSize
        var frame = window.frame
        frame.size = targetSize

        if let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.origin = CGPoint(
                x: visibleFrame.midX - targetSize.width / 2,
                y: visibleFrame.midY - targetSize.height / 2
            )
        }

        window.setFrame(frame, display: false)
        if isBackgroundFixtureLaunch {
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func disableFixturePersistence(in window: NSWindow) {
        window.isRestorable = false
        _ = window.setFrameAutosaveName("")

        guard let contentView = window.contentView else { return }
        clearSplitViewAutosaveNames(in: contentView)
    }

    private func clearSplitViewAutosaveNames(in view: NSView) {
        if let splitView = view as? NSSplitView {
            splitView.autosaveName = nil
        }
        for subview in view.subviews {
            clearSplitViewAutosaveNames(in: subview)
        }
    }
}

struct PlaybackCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandMenu("Playback") {
            Button(appState.playbackState == .playing ? "Pause" : "Play") {
                Task { await appState.playbackManager.togglePlayPause() }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(appState.nowPlaying == nil)

            Button("Stop") {
                Task { await appState.playbackManager.stop() }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(appState.nowPlaying == nil)

            Divider()

            Button("Next Track") {
                Task { await appState.playbackManager.next() }
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!appState.playbackManager.canGoNext)

            Button("Previous Track") {
                Task { await appState.playbackManager.previous() }
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!appState.playbackManager.canGoPrevious)

            Divider()

            Button("Volume Up") {
                appState.volume = min(1.0, appState.volume + 0.1)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(appState.volume >= 1.0)

            Button("Volume Down") {
                appState.volume = max(0.0, appState.volume - 0.1)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(appState.volume <= 0.0)

            Divider()

            Toggle("Shuffle", isOn: Binding(
                get: { appState.shuffleEnabled },
                set: { appState.shuffleEnabled = $0 }
            ))
            .keyboardShortcut("s", modifiers: .command)

            Divider()

            Button("Cycle Repeat Mode") {
                appState.playbackManager.cycleRepeatMode()
            }
            .keyboardShortcut("r", modifiers: .command)

            Menu("Repeat") {
                Toggle("Off", isOn: Binding(
                    get: { appState.playbackManager.repeatMode == .off },
                    set: { if $0 { appState.playbackManager.repeatMode = .off } }
                ))
                Toggle("One", isOn: Binding(
                    get: { appState.playbackManager.repeatMode == .one },
                    set: { if $0 { appState.playbackManager.repeatMode = .one } }
                ))
                Toggle("All", isOn: Binding(
                    get: { appState.playbackManager.repeatMode == .all },
                    set: { if $0 { appState.playbackManager.repeatMode = .all } }
                ))
            }
        }

        CommandMenu("View") {
            Button("Toggle Sidebar") {
                NSApp.keyWindow?.firstResponder?.tryToPerform(
                    #selector(NSSplitViewController.toggleSidebar(_:)),
                    with: nil
                )
            }
            .keyboardShortcut("\\", modifiers: .command)

            Button("Toggle Lyrics") {
                appState.toggleNowPlayingInspector(.lyrics)
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Show Queue") {
                appState.toggleNowPlayingInspector(.queue)
            }
            .keyboardShortcut("u", modifiers: .command)

            Divider()

            Button("Search") {
                appState.selectedSidebarItem = .search
                appState.shouldFocusSearch = true
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button("Immersive Mode") {
                appState.enterImmersiveMode()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandGroup(after: .windowArrangement) {
            Button("MiniPlayer") {
                appState.showMiniPlayer()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }
    }
}

struct SongCommands: Commands {
    let appState: AppState

    private var usesPlaneEvidenceRail: Bool {
        appState.selectedSidebarItem == .plane && PlaneEvidenceRailController.shared.nearOnPlane
    }

    private var infoSong: Song? {
        if appState.selectedSidebarItem == .songs {
            let selection = appState.songsInfoSelection
            // Multi-item information is not implemented: never silently open
            // only one selected item, or an unrelated now-playing song.
            return selection.count == 1 ? selection.first : nil
        }
        return appState.nowPlaying
    }

    private var nowPlaying: Song? {
        appState.nowPlaying
    }

    var body: some Commands {
        CommandMenu("Song") {
            Button("Get Info…") {
                // GI-B: on the One Plane, ⌘I toggles the docked evidence rail
                // at the near strata instead of the modal sheet. Elsewhere it
                // opens the Dossier Sheet for the selection when available,
                // falling back to playback only outside a selection surface.
                if usesPlaneEvidenceRail {
                    PlaneEvidenceRailController.shared.toggle()
                } else if let song = infoSong {
                    appState.getInfoContent = .song(song)
                }
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(!usesPlaneEvidenceRail && infoSong == nil)

            Divider()

            Button("Admit Current Song") {
                guard let song = nowPlaying, let serverId = appState.activeServerId else { return }
                try? appState.databaseManager.saveSongs([song], serverId: serverId)
                try? appState.databaseManager.admitSongAndRelated(
                    song,
                    serverId: serverId,
                    admittedBy: .manual,
                    sourceDetail: "command"
                )
                try? appState.databaseManager.upsertWaitingRoomItem(
                    song: song,
                    serverId: serverId,
                    state: .admitted,
                    source: "command_admit"
                )
                try? appState.databaseManager.setWaitingRoomState(
                    songId: song.id,
                    serverId: serverId,
                    state: .admitted
                )
                try? appState.databaseManager.unhideSongAndRelated(song, serverId: serverId)
                try? appState.databaseManager.clearAttention(
                    id: song.id,
                    type: .song,
                    serverId: serverId,
                    markType: .dismissed
                )
                appState.refreshHiddenIds()
                appState.refreshLibraryMembershipIds()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(nowPlaying == nil || appState.activeServerId == nil)

            Button("Mark Interesting") {
                guard let song = nowPlaying, let serverId = appState.activeServerId else { return }
                try? appState.databaseManager.saveSongs([song], serverId: serverId)
                try? appState.databaseManager.markAttention(
                    id: song.id,
                    type: .song,
                    serverId: serverId,
                    markType: .interesting,
                    source: "command"
                )
                try? appState.databaseManager.upsertWaitingRoomItem(
                    song: song,
                    serverId: serverId,
                    state: .interesting,
                    source: "command_interesting"
                )
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(nowPlaying == nil || appState.activeServerId == nil)

            Divider()

            Button("Love") {
                guard let song = nowPlaying else { return }
                Task {
                    try? await appState.networkActor.star(id: song.id, type: .song)
                }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(nowPlaying == nil)

            Divider()

            Button("Add to Playlist...") {
                guard let song = nowPlaying else { return }
                appState.createPlaylistSongIds = [song.id]
                appState.showCreatePlaylistSheet = true
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(nowPlaying == nil)

            Divider()

            Button("Go to Artist") {
                guard let song = nowPlaying else { return }
                appState.navigationTargetArtistId = song.artistId
            }
            .disabled(nowPlaying == nil)

            Button("Go to Album") {
                guard let song = nowPlaying else { return }
                appState.navigationTargetAlbumId = song.albumId
            }
            .disabled(nowPlaying == nil)

            Divider()

            Button("Show in Finder") {
                guard let song = nowPlaying, let server = appState.activeServer else { return }
                Task {
                    if let path = await appState.cacheActor.getAudioPath(
                        for: song.id,
                        serverId: server.id,
                        suffix: song.suffix
                    ) {
                        NSWorkspace.shared.selectFile(
                            path.path,
                            inFileViewerRootedAtPath: path.deletingLastPathComponent().path
                        )
                    } else {
                        await MainActor.run {
                            appState.showFeedback(
                                message: "No local file found",
                                detail: "Download this song first to reveal it in Finder.",
                                style: .warning,
                                systemImage: "folder.badge.questionmark"
                            )
                        }
                    }
                }
            }
            .disabled(nowPlaying == nil || appState.activeServer == nil)
        }
    }
}
