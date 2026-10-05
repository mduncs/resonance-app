import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.emotionEngine) private var emotionEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarTrailingEdge: CGFloat = 0

    var body: some View {
        splitView
        .onAppear {
            appState.reconcileSidebarSelectionWithVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            appState.reconcileSidebarSelectionWithVisibility()
        }
        .overlay(alignment: .bottom) {
            NowPlayingBarInset(contentLeading: sidebarTrailingEdge)
        }
        .accessibilityIdentifier(parityFixtureAccessibilityIdentifier)
        // Keep the protected Command HUD modal over the footer and inspector,
        // not only over the split-view content.
        .overlay {
            if appState.isCommandHUDVisible {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { appState.isCommandHUDVisible = false }

                    CommandHUDView()
                        .padding(.top, 110)
                }
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: appState.isCommandHUDVisible)
    }

    private var parityFixtureAccessibilityIdentifier: String {
        guard let fixture = DeterministicCaptureFixture.configuration else {
            return "Resonance.ContentView"
        }
        return "ParityFixture.route.\(fixture.route.rawValue).state.\(fixture.state.rawValue)"
    }

    private var splitView: some View {
        NavigationSplitView {
            SidebarView()
                .background {
                    SidebarAllocationProbe { trailingEdge in
                        sidebarTrailingEdge = trailingEdge
                    }
                }
        } detail: {
            DetailView()
                .accessibilityIdentifier("DetailView")
                // Reserve scrolling room, not a blank viewport strip: library
                // content must remain behind the floating glass footer.
                .contentMargins(.bottom, 82, for: .scrollContent)
        }
        .mouseNavigationHandler(appState: appState)
        .navigationSplitViewStyle(.balanced)
        .onChange(of: appState.nowPlaying?.coverArt) { _, newCoverArt in
            emotionEngine.updateColors(fromArtworkId: newCoverArt, using: appState)
        }
        .onAppear {
            // Initialize emotion engine with current song if playing
            if let coverArt = appState.nowPlaying?.coverArt {
                emotionEngine.updateColors(fromArtworkId: coverArt, using: appState)
            }
        }
        .inspector(isPresented: Binding(
            get: { appState.nowPlayingInspector != nil },
            set: { if !$0 { appState.nowPlayingInspector = nil } }
        )) {
            switch appState.nowPlayingInspector {
            case .lyrics:
                LyricsView()
                    .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
                    .contentMargins(.bottom, 82, for: .scrollContent)
            case .queue:
                ContinuePlayingPanel()
                    .inspectorColumnWidth(min: 258, ideal: 258, max: 400)
                    .contentMargins(.bottom, 82, for: .scrollContent)
            case nil:
                EmptyView()
            }
        }
        .sheet(isPresented: Binding(
            get: { !appState.isOnboardingComplete },
            set: { if !$0 { appState.isOnboardingComplete = true } }
        )) {
            OnboardingView()
                .environment(appState)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(
            get: { appState.showCreatePlaylistSheet },
            set: { appState.showCreatePlaylistSheet = $0 }
        )) {
            CreatePlaylistSheet(initialSongIds: appState.createPlaylistSongIds)
                .environment(appState)
        }
        .sheet(item: Binding(
            get: { appState.playlistDestinationRequest },
            set: { appState.playlistDestinationRequest = $0 }
        )) { request in
            PlaylistDestinationPicker(request: request)
                .environment(appState)
        }
        .sheet(item: Binding(
            get: { appState.editPlaylistTarget },
            set: { appState.editPlaylistTarget = $0 }
        )) { playlist in
            EditPlaylistSheet(playlist: playlist)
                .environment(appState)
        }
        .sheet(item: Binding(
            get: { appState.getInfoContent },
            set: { appState.getInfoContent = $0 }
        )) { content in
            GetInfoView(content: content)
                .environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.showSmartPlaylistEditor },
            set: { appState.showSmartPlaylistEditor = $0 }
        )) {
            SmartPlaylistEditorView(playlist: appState.editSmartPlaylistTarget)
                .environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.showSimilarSongsSheet },
            set: { appState.showSimilarSongsSheet = $0 }
        )) {
            if let seedSong = appState.similarSongsSeedSong {
                SimilarSongsView(seedSong: seedSong)
                    .environment(appState)
            }
        }
        .confirmationDialog(
            "Delete Playlist?",
            isPresented: Binding(
                get: { appState.deletePlaylistTarget != nil },
                set: { if !$0 { appState.deletePlaylistTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let playlist = appState.deletePlaylistTarget {
                    Task {
                        do {
                            try await appState.networkActor.deletePlaylist(id: playlist.id)
                            await MainActor.run {
                                appState.playlists.removeAll { $0.id == playlist.id }
                                appState.deletePlaylistTarget = nil
                            }
                        } catch {
                            await MainActor.run {
                                appState.deletePlaylistTarget = nil
                            }
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                appState.deletePlaylistTarget = nil
            }
        } message: {
            if let playlist = appState.deletePlaylistTarget {
                Text("Are you sure you want to delete \"\(playlist.name)\"? This cannot be undone.")
            }
        }
        .globalKeyboardShortcuts()
        // MARK: - Delete Song Confirmation
        .confirmationDialog(
            "Delete from Library?",
            isPresented: Binding(
                get: { appState.deleteConfirmSong != nil },
                set: { if !$0 { appState.deleteConfirmSong = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let song = appState.deleteConfirmSong {
                    Task {
                        do {
                            try await appState.trashManager.trashSong(song)
                        } catch {
                            print("Failed to trash song: \(error)")
                        }
                        appState.deleteConfirmSong = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                appState.deleteConfirmSong = nil
            }
        } message: {
            if let song = appState.deleteConfirmSong {
                Text("Move \"\(song.title)\" by \(song.artist) to Trash?\n\nYou can undo this for 10 seconds after deletion.")
            }
        }
        // MARK: - Delete Album Confirmation
        .confirmationDialog(
            "Delete Album from Library?",
            isPresented: Binding(
                get: { appState.deleteConfirmAlbum != nil },
                set: { if !$0 { appState.deleteConfirmAlbum = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let (album, songs) = appState.deleteConfirmAlbum {
                    Task {
                        do {
                            try await appState.trashManager.trashAlbum(album, songs: songs)
                        } catch {
                            print("Failed to trash album: \(error)")
                        }
                        appState.deleteConfirmAlbum = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                appState.deleteConfirmAlbum = nil
            }
        } message: {
            if let (album, songs) = appState.deleteConfirmAlbum {
                Text("Move \"\(album.name)\" (\(songs.count) songs) to Trash?\n\nYou can undo this for 10 seconds after deletion.")
            }
        }
        // MARK: - Undo Toast
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let feedback = appState.feedback {
                    FeedbackToastView(
                        message: feedback.message,
                        detail: feedback.detail,
                        style: feedback.style,
                        systemImage: feedback.systemImage,
                        actionTitle: feedback.actionTitle,
                        action: feedback.action,
                        dismissAction: appState.dismissFeedback
                    )
                    .transition(
                        reduceMotion
                            ? .identity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                }

                if let message = appState.undoToastMessage {
                    FeedbackToastView(
                        message: message,
                        detail: nil,
                        style: .info,
                        systemImage: "trash",
                        actionTitle: "Undo",
                        action: appState.undoToastAction
                    )
                    .transition(
                        reduceMotion
                            ? .identity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 80) // above the now playing bar
            .animation(reduceMotion ? nil : .spring(duration: 0.3), value: appState.feedback?.id)
            .animation(reduceMotion ? nil : .spring(duration: 0.3), value: appState.undoToastMessage)
        }
    }
}


/// Constrain each navigation destination's hosting view to its allocated viewport.
/// Applying this outside the navigation stack is too late: AppKit otherwise
/// feeds a scroll view's content-derived minimum back into the inspector split.
private struct DetailViewportLayout: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

struct DetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLoadingNavigation = false
    @State private var navigationTask: Task<Void, Never>?
    @State private var pendingNavigation: PendingNavigation?

    private enum NavigationTarget: Equatable {
        case album(String)
        case artist(String)
    }

    private enum NavigationTargetKind {
        case album
        case artist
    }

    private struct PendingNavigation: Equatable {
        let target: NavigationTarget
        let sidebar: SidebarItem
        let serverID: UUID?
        let generation: UUID
    }

    var body: some View {
        @Bindable var state = appState

        NavigationStack(path: $state.detailNavigationPath) {
            Group {
                switch appState.selectedSidebarItem {
                case .listen:
                    ListenView()
                case .plane:
                    PlaneView()
                case .home:
                    HomeView()
                case .waitingRoom:
                    WaitingRoomView()
                case .projects:
                    ProjectsView()
                case .unclassified:
                    UnclassifiedView()
                case .importPolicies:
                    ImportPoliciesView()
                case .artists:
                    ArtistsView()
                case .albums:
                    AlbumsView()
                case .songs:
                    SongsView()
                case .genres:
                    GenresView()
                case .folders:
                    FoldersView()
                case .favorites:
                    LikedSongsView()
                case .newMusic:
                    DiscoveryFeedView()
                case .recentlyAdded:
                    RecentlyAddedView()
                case .recentlyPlayed:
                    RecentlyPlayedView()
                case .downloads:
                    DownloadsView()
                case .playlists:
                    PlaylistsView()
                case .radio:
                    RadioView()
                case .search:
                    SearchView()
                }
            }
            .modifier(DetailViewportLayout())
            .navigationDestination(for: Album.self) { album in
                AlbumDetailView(album: album)
                    .id(album.id)
                    .modifier(DetailViewportLayout())
            }
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(artist: artist)
                    .modifier(DetailViewportLayout())
            }
            .navigationDestination(for: Genre.self) { genre in
                GenreDetailView(genre: genre)
                    .modifier(DetailViewportLayout())
            }
            .navigationDestination(for: MusicFolder.self) { folder in
                FolderDetailView(folder: folder)
                    .modifier(DetailViewportLayout())
            }
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
                    .modifier(DetailViewportLayout())
            }
            .navigationDestination(for: SmartPlaylist.self) { smartPlaylist in
                SmartPlaylistDetailView(playlist: smartPlaylist)
                    .modifier(DetailViewportLayout())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            // Loading indicator while fetching data for navigation
            if isLoadingNavigation {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isLoadingNavigation)
        .onAppear { appState.startNavigationHistory() }
        .onChange(of: appState.navigationTargetAlbumId) { _, albumId in
            handleAlbumNavigation(albumId)
        }
        .onChange(of: appState.navigationTargetArtistId) { _, artistId in
            handleArtistNavigation(artistId)
        }
        // Retry navigation when albums load (handles race condition)
        .onChange(of: appState.albums) { _, _ in
            if appState.navigationTargetAlbumId != nil, !isLoadingNavigation {
                handleAlbumNavigation(appState.navigationTargetAlbumId)
            }
        }
        // Retry navigation when artists load (handles race condition)
        .onChange(of: appState.artists) { _, _ in
            if appState.navigationTargetArtistId != nil, !isLoadingNavigation {
                handleArtistNavigation(appState.navigationTargetArtistId)
            }
        }
        .onChange(of: appState.selectedSidebarItem) { _, sidebar in
            guard let pendingNavigation, pendingNavigation.sidebar != sidebar else { return }
            finishNavigation(pendingNavigation, clearTarget: true)
        }
        .onDisappear {
            if let pendingNavigation {
                finishNavigation(pendingNavigation, clearTarget: true)
            }
        }
    }

    private func handleAlbumNavigation(_ albumId: String?) {
        guard let albumId else {
            cancelNavigation(target: .album)
            return
        }
        let request = beginNavigation(target: .album(albumId))
        guard isCurrentNavigation(request) else {
            finishNavigation(request, clearTarget: true)
            return
        }

        guard let serverID = request.serverID else {
            finishNavigation(request, clearTarget: true)
            return
        }
        isLoadingNavigation = true
        navigationTask = Task { @MainActor in
            do {
                let cached = try await appState.databaseManager.cachedAlbum(
                    id: albumId, serverID: serverID.uuidString
                )
                let album: Album
                if let cached {
                    album = cached
                } else {
                    album = try await appState.networkActor.fetchAlbum(
                        id: albumId, expectedServerID: serverID
                    )
                }
                try Task.checkCancellation()
                guard isCurrentNavigation(request) else {
                    finishNavigation(request, clearTarget: true)
                    return
                }
                pushAlbum(appState.presentedAlbum(album))
                finishNavigation(request, clearTarget: true)
            } catch is CancellationError {
                return
            } catch {
                if isCurrentNavigation(request) {
                    finishNavigation(request, clearTarget: true)
                }
            }
        }
    }

    private func handleArtistNavigation(_ artistId: String?) {
        guard let artistId else {
            cancelNavigation(target: .artist)
            return
        }
        let request = beginNavigation(target: .artist(artistId))
        guard isCurrentNavigation(request) else {
            finishNavigation(request, clearTarget: true)
            return
        }

        // Find artist in loaded artists
        if let artist = appState.artists.first(where: { $0.id == artistId }) {
            navigationTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(50))
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard isCurrentNavigation(request) else {
                    finishNavigation(request, clearTarget: true)
                    return
                }
                pushArtist(artist)
                finishNavigation(request, clearTarget: true)
            }
        } else if appState.artists.isEmpty {
            // Artists not loaded yet - trigger fetch and show loading
            isLoadingNavigation = true
            navigationTask = Task { @MainActor in
                do {
                    guard let serverID = request.serverID else {
                        finishNavigation(request, clearTarget: true)
                        return
                    }
                    let artists = try await appState.networkActor.fetchArtists(expectedServerID: serverID)
                    try Task.checkCancellation()
                    guard isCurrentNavigation(request) else {
                        finishNavigation(request, clearTarget: true)
                        return
                    }
                    appState.artists = artists
                    guard let artist = artists.first(where: { $0.id == artistId }) else {
                        finishNavigation(request, clearTarget: true)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                    try Task.checkCancellation()
                    guard isCurrentNavigation(request) else {
                        finishNavigation(request, clearTarget: true)
                        return
                    }
                    pushArtist(artist)
                    finishNavigation(request, clearTarget: true)
                } catch is CancellationError {
                    return
                } catch {
                    finishNavigation(request, clearTarget: true)
                }
            }
        } else {
            // Artists loaded but artist not found - clear after brief timeout
            // (artist may have been deleted from server)
            navigationTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard isCurrentNavigation(request) else {
                    finishNavigation(request, clearTarget: true)
                    return
                }
                finishNavigation(request, clearTarget: true)
            }
        }
    }

    private func beginNavigation(target: NavigationTarget) -> PendingNavigation {
        navigationTask?.cancel()
        let previousOrigin = pendingNavigation.flatMap { $0.target == target ? $0 : nil }
        let originSidebar = previousOrigin?.sidebar ?? appState.selectedSidebarItem
        let originServerID: UUID?
        if let previousOrigin {
            originServerID = previousOrigin.serverID
        } else {
            originServerID = appState.activeServer?.id
        }
        let request = PendingNavigation(
            target: target,
            sidebar: originSidebar,
            serverID: originServerID,
            generation: UUID()
        )
        pendingNavigation = request
        navigationTask = nil
        isLoadingNavigation = false
        switch target {
        case .album:
            appState.navigationTargetArtistId = nil
        case .artist:
            appState.navigationTargetAlbumId = nil
        }
        return request
    }

    private func isCurrentNavigation(_ request: PendingNavigation) -> Bool {
        guard pendingNavigation == request,
              appState.selectedSidebarItem == request.sidebar,
              appState.activeServer?.id == request.serverID else { return false }
        switch request.target {
        case .album(let id): return appState.navigationTargetAlbumId == id
        case .artist(let id): return appState.navigationTargetArtistId == id
        }
    }

    private func pushAlbum(_ album: Album) {
        if appState.selectedSidebarItem != .albums {
            appState.detailNavigationPath = NavigationPath()
        }
        appState.detailNavigationPath.append(album)
    }

    private func pushArtist(_ artist: Artist) {
        if appState.selectedSidebarItem != .artists {
            appState.detailNavigationPath = NavigationPath()
        }
        appState.detailNavigationPath.append(artist)
    }

    private func cancelNavigation(target: NavigationTargetKind) {
        guard let pendingNavigation else { return }
        switch (pendingNavigation.target, target) {
        case (.album, .album), (.artist, .artist): break
        default: return
        }
        finishNavigation(pendingNavigation, clearTarget: false)
    }

    private func finishNavigation(_ request: PendingNavigation, clearTarget: Bool) {
        guard pendingNavigation == request else { return }
        navigationTask?.cancel()
        navigationTask = nil
        pendingNavigation = nil
        isLoadingNavigation = false
        guard clearTarget else { return }
        switch request.target {
        case .album(let id):
            if appState.navigationTargetAlbumId == id { appState.navigationTargetAlbumId = nil }
        case .artist(let id):
            if appState.navigationTargetArtistId == id { appState.navigationTargetArtistId = nil }
        }
    }
}

private struct NowPlayingBarInset: View {
    let contentLeading: CGFloat

    var body: some View {
        // Music 1.7 state 50: the accessory begins at the allocated sidebar
        // edge (213), not the inset content origin (223). Its glass host is
        // centered in that remaining region and sits 19 points above bottom.
        // Read the live split allocation so resizing/collapse does not retain
        // the old constant +107 offset. Native inspector-open positioning is
        // still a separate proof obligation.
        GeometryReader { geometry in
            NowPlayingBar()
                .frame(width: 700, height: 54)
                .position(
                    x: ((geometry.size.width + contentLeading) / 2).rounded(),
                    y: 36
                )
        }
        .frame(height: 82)
    }
}

/// Measures the allocated split item, not the sidebar list's inset bounds or
/// a saved ideal width. The probe never changes split-view layout or defaults.
private struct SidebarAllocationProbe: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> AllocationView {
        let view = AllocationView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: AllocationView, context: Context) {
        nsView.onChange = onChange
        nsView.scheduleMeasurement()
    }

    final class AllocationView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var measurementScheduled = false
        private var lastTrailingEdge: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(splitGeometryChanged),
                name: NSSplitView.didResizeSubviewsNotification, object: nil
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(splitGeometryChanged),
                name: NSWindow.didResizeNotification, object: window
            )
            scheduleMeasurement()
        }

        override func layout() {
            super.layout()
            scheduleMeasurement()
        }

        @objc private func splitGeometryChanged(_ notification: Notification) {
            scheduleMeasurement()
        }

        func scheduleMeasurement() {
            guard !measurementScheduled else { return }
            measurementScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.measurementScheduled = false
                self.measureAllocation()
            }
        }

        private func measureAllocation() {
            guard let root = window?.contentView else { return }
            var child: NSView = self
            while let parent = child.superview {
                if let split = parent as? NSSplitView, split.isVertical {
                    let trailingEdge: CGFloat
                    if child.isHiddenOrHasHiddenAncestor || split.isSubviewCollapsed(child) {
                        trailingEdge = 0
                    } else {
                        // The following item's origin includes the actual
                        // divider allocation without guessing its thickness.
                        let following = split.subviews.first {
                            $0 !== child && !$0.isHidden && $0.frame.minX >= child.frame.maxX
                        }
                        trailingEdge = following.map { $0.convert($0.bounds, to: root).minX }
                            ?? child.convert(child.bounds, to: root).maxX
                    }
                    guard trailingEdge != lastTrailingEdge else { return }
                    lastTrailingEdge = trailingEdge
                    onChange?(max(0, trailingEdge))
                    return
                }
                child = parent
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
