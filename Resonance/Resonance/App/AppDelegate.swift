import AppKit
import MediaPlayer

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mediaKeyTap: Any?
    weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMediaKeyHandling()
        setupNowPlayingInfo()

        // Handle "Start Minimized" setting
        if UserDefaults.standard.bool(forKey: "startMinimized") {
            // Hide the main window after a brief delay to let it initialize
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApplication.shared.windows.first { $0.title != "" && $0.isVisible }?.orderOut(nil)
            }
        }
    }

    // MARK: - Dock Menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "Resonance")

        // Now Playing info (disabled, display only)
        let nowPlayingItem = NSMenuItem(
            title: formatNowPlayingTitle(),
            action: nil,
            keyEquivalent: ""
        )
        nowPlayingItem.isEnabled = false
        menu.addItem(nowPlayingItem)

        // Album/Artist subtitle
        if let song = appState?.nowPlaying {
            let subtitleItem = NSMenuItem(
                title: "\(song.artist) — \(song.album)",
                action: nil,
                keyEquivalent: ""
            )
            subtitleItem.isEnabled = false
            menu.addItem(subtitleItem)
        }

        menu.addItem(.separator())

        // Favorite
        if appState?.nowPlaying != nil {
            let favoriteItem = NSMenuItem(
                title: "Favorite",
                action: #selector(toggleFavorite),
                keyEquivalent: ""
            )
            favoriteItem.target = self
            menu.addItem(favoriteItem)
        }

        menu.addItem(.separator())

        // Repeat submenu
        let repeatMenu = NSMenu(title: "Repeat")
        let repeatOffItem = NSMenuItem(title: "Off", action: #selector(setRepeatOff), keyEquivalent: "")
        repeatOffItem.target = self
        repeatOffItem.state = appState?.playbackManager.repeatMode == .off ? .on : .off
        repeatMenu.addItem(repeatOffItem)

        let repeatOneItem = NSMenuItem(title: "One", action: #selector(setRepeatOne), keyEquivalent: "")
        repeatOneItem.target = self
        repeatOneItem.state = appState?.playbackManager.repeatMode == .one ? .on : .off
        repeatMenu.addItem(repeatOneItem)

        let repeatAllItem = NSMenuItem(title: "All", action: #selector(setRepeatAll), keyEquivalent: "")
        repeatAllItem.target = self
        repeatAllItem.state = appState?.playbackManager.repeatMode == .all ? .on : .off
        repeatMenu.addItem(repeatAllItem)

        let repeatItem = NSMenuItem(title: "Repeat", action: nil, keyEquivalent: "")
        repeatItem.submenu = repeatMenu
        menu.addItem(repeatItem)

        // Shuffle submenu
        let shuffleMenu = NSMenu(title: "Shuffle")
        let shuffleOnItem = NSMenuItem(title: "On", action: #selector(setShuffleOn), keyEquivalent: "")
        shuffleOnItem.target = self
        shuffleOnItem.state = appState?.queueManager.isShuffleEnabled == true ? .on : .off
        shuffleMenu.addItem(shuffleOnItem)

        let shuffleOffItem = NSMenuItem(title: "Off", action: #selector(setShuffleOff), keyEquivalent: "")
        shuffleOffItem.target = self
        shuffleOffItem.state = appState?.queueManager.isShuffleEnabled == false ? .on : .off
        shuffleMenu.addItem(shuffleOffItem)

        let shuffleItem = NSMenuItem(title: "Shuffle", action: nil, keyEquivalent: "")
        shuffleItem.submenu = shuffleMenu
        menu.addItem(shuffleItem)

        menu.addItem(.separator())

        // Play/Pause
        let isPlaying = appState?.playbackState == .playing
        let playPauseItem = NSMenuItem(
            title: isPlaying ? "Pause" : "Play",
            action: #selector(togglePlayPause),
            keyEquivalent: ""
        )
        playPauseItem.target = self
        menu.addItem(playPauseItem)

        // Next Track
        let nextItem = NSMenuItem(
            title: "Next Track",
            action: #selector(nextTrack),
            keyEquivalent: ""
        )
        nextItem.target = self
        nextItem.isEnabled = appState?.playbackManager.canGoNext ?? false
        menu.addItem(nextItem)

        // Previous Track
        let prevItem = NSMenuItem(
            title: "Previous Track",
            action: #selector(previousTrack),
            keyEquivalent: ""
        )
        prevItem.target = self
        prevItem.isEnabled = appState?.playbackManager.canGoPrevious ?? false
        menu.addItem(prevItem)

        return menu
    }

    private func formatNowPlayingTitle() -> String {
        guard let song = appState?.nowPlaying else {
            return "♫ Not Playing"
        }
        let text = song.title
        if text.count > 50 {
            return "♫ " + String(text.prefix(47)) + "..."
        }
        return "♫ " + text
    }

    // MARK: - Dock Menu Actions

    @objc private func togglePlayPause() {
        Task {
            await appState?.playbackManager.togglePlayPause()
        }
    }

    @objc private func nextTrack() {
        Task {
            await appState?.playbackManager.next()
        }
    }

    @objc private func previousTrack() {
        Task {
            await appState?.playbackManager.previous()
        }
    }

    @objc private func toggleFavorite() {
        Task {
            guard let song = appState?.nowPlaying else { return }
            try? await appState?.networkActor.star(id: song.id, type: .song)
        }
    }

    @objc private func setRepeatOff() {
        appState?.playbackManager.repeatMode = .off
    }

    @objc private func setRepeatOne() {
        appState?.playbackManager.repeatMode = .one
    }

    @objc private func setRepeatAll() {
        appState?.playbackManager.repeatMode = .all
    }

    @objc private func setShuffleOn() {
        if appState?.queueManager.isShuffleEnabled == false {
            appState?.queueManager.toggleShuffle()
        }
    }

    @objc private func setShuffleOff() {
        if appState?.queueManager.isShuffleEnabled == true {
            appState?.queueManager.toggleShuffle()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clear play history if setting is enabled
        if UserDefaults.standard.bool(forKey: "clearHistoryOnQuit") {
            try? appState?.databaseManager.write { db in
                try db.execute(sql: "DELETE FROM play_history")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running in menu bar
    }

    // MARK: - Media Keys

    private func setupMediaKeyHandling() {
        // Register for remote command center events
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.handlePlay()
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.handlePause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleTogglePlayPause()
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleNextTrack()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.handlePreviousTrack()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.handleSeek(to: event.positionTime)
            return .success
        }
    }

    private func setupNowPlayingInfo() {
        // Now Playing info is updated by NowPlayingService
    }

    // MARK: - Media Key Command Handlers

    private func handlePlay() {
        Task {
            if appState?.playbackState != .playing {
                await appState?.playbackManager.togglePlayPause()
            }
        }
    }

    private func handlePause() {
        Task {
            if appState?.playbackState == .playing {
                await appState?.playbackManager.togglePlayPause()
            }
        }
    }

    private func handleTogglePlayPause() {
        Task {
            await appState?.playbackManager.togglePlayPause()
        }
    }

    private func handleNextTrack() {
        Task {
            await appState?.playbackManager.next()
        }
    }

    private func handlePreviousTrack() {
        Task {
            await appState?.playbackManager.previous()
        }
    }

    private func handleSeek(to position: TimeInterval) {
        Task {
            await appState?.playbackManager.seek(to: position)
        }
    }
}
