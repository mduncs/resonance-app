import SwiftUI

@main
struct ResonanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @State private var emotionEngine = EmotionEngine()
    @AppStorage("appTheme") private var appTheme = "System"
    @AppStorage("showMenuBarPlayer") private var showMenuBarPlayer = true
    @AppStorage("accentColorOption") private var accentColorOption = "Blue"

    private var preferredColorScheme: ColorScheme? {
        switch appTheme {
        case "Light": return .light
        case "Dark": return .dark
        default: return nil // System
        }
    }

    private var accentColor: Color {
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
                .tint(accentColor)
                .background(MainWindowIdentifierView())
                .onAppear {
                    // Wire up emotion engine for window management
                    appState.emotionEngine = emotionEngine
                    // Wire up AppState for dock menu
                    appDelegate.appState = appState
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
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

                Button("Get Info") {
                    // GI-B: on the One Plane, ⌘I toggles the docked evidence rail
                    // at the near strata instead of the modal sheet. Elsewhere it
                    // opens the Dossier Sheet for the now-playing song.
                    if appState.selectedSidebarItem == .plane,
                       PlaneEvidenceRailController.shared.nearOnPlane {
                        PlaneEvidenceRailController.shared.toggle()
                    } else if let song = appState.nowPlaying {
                        appState.getInfoContent = .song(song)
                    }
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(appState.nowPlaying == nil && appState.selectedSidebarItem != .plane)
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
            SettingsView()
                .environment(appState)
                .tint(accentColor)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Resonance", systemImage: "music.note", isInserted: $showMenuBarPlayer) {
            MenuBarPlayerView()
                .environment(appState)
                .tint(accentColor)
        }
        .menuBarExtraStyle(.window)
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
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.identifier = NSUserInterfaceItemIdentifier("mainWindow")
    }
}

struct PlaybackCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play/Pause") {
                Task { await appState.playbackManager.togglePlayPause() }
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Stop") {
                Task { await appState.playbackManager.stop() }
            }
            .keyboardShortcut(".", modifiers: .command)

            Divider()

            Button("Next Track") {
                Task { await appState.playbackManager.next() }
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)

            Button("Previous Track") {
                Task { await appState.playbackManager.previous() }
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Divider()

            Button("Volume Up") {
                appState.volume = min(1.0, appState.volume + 0.1)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button("Volume Down") {
                appState.volume = max(0.0, appState.volume - 0.1)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            Button("Toggle Shuffle") {
                appState.shuffleEnabled.toggle()
            }
            .keyboardShortcut("s", modifiers: .command)

            Menu("Repeat") {
                Button("Off") { appState.playbackManager.repeatMode = .off }
                Button("One") { appState.playbackManager.repeatMode = .one }
                Button("All") { appState.playbackManager.repeatMode = .all }
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
                appState.isLyricsPanelVisible.toggle()
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Show Queue") {
                appState.isQueueVisible.toggle()
            }
            .keyboardShortcut("u", modifiers: .command)

            Divider()

            Button("Search") {
                appState.shouldFocusSearch = true
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button("Mini Player") {
                appState.showMiniPlayer()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Button("Immersive Mode") {
                appState.enterImmersiveMode()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}

struct SongCommands: Commands {
    let appState: AppState

    private var nowPlaying: Song? {
        appState.nowPlaying
    }

    var body: some Commands {
        CommandMenu("Song") {
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
                        NSWorkspace.shared.selectFile(path.path, inFileViewerRootedAtPath: "")
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
