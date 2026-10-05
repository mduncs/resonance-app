import Foundation
import ImageIO
import XCTest
@testable import Resonance

final class ParityFixtureCatalogTests: XCTestCase {
    func testConfigurationIsExplicitlyGatedAndLegacyNowPlayingRemainsCompatible() {
        XCTAssertNil(DeterministicCaptureFixture.configuration(environment: [:]))
        XCTAssertNil(DeterministicCaptureFixture.configuration(environment: [
            "RESONANCE_PARITY_ROUTE": "albums"
        ]))

        let atlas = DeterministicCaptureFixture.configuration(environment: [
            "RESONANCE_PARITY_FIXTURE": " atlas ",
            "RESONANCE_PARITY_ROUTE": "mini_player_queue",
            "RESONANCE_PARITY_STATE": "playing",
            "RESONANCE_PARITY_APPEARANCE": "dark",
            "RESONANCE_PARITY_WIDTH": "1440",
            "RESONANCE_PARITY_HEIGHT": "900",
            "RESONANCE_PARITY_BACKGROUND": "yes",
            "RESONANCE_PARITY_SUPPORTS_SEEKING": "false",
            "RESONANCE_PARITY_MULTIPLE_ROUTES": "true",
            "RESONANCE_PARITY_SCRATCH_ROOT": "/tmp/resonance-atlas-tests"
        ])
        XCTAssertEqual(atlas?.mode, .atlas)
        XCTAssertEqual(atlas?.route, .miniPlayerQueue)
        XCTAssertEqual(atlas?.state, .playing)
        XCTAssertEqual(atlas?.playbackMode, .playing)
        XCTAssertEqual(atlas?.appearance, .dark)
        XCTAssertEqual(atlas?.windowSize, CGSize(width: 1440, height: 900))
        XCTAssertEqual(atlas?.background, true)
        XCTAssertEqual(atlas?.supportsSeeking, false)
        XCTAssertEqual(atlas?.multipleRoutesDetected, true)
        XCTAssertEqual(atlas?.fixtureDatabaseURL?.path, "/tmp/resonance-atlas-tests/resonance-parity-atlas.db")

        let legacy = DeterministicCaptureFixture.configuration(environment: [
            "RESONANCE_CAPTURE_FIXTURE": "now-playing",
            "RESONANCE_CAPTURE_STATE": "playing",
            "RESONANCE_CAPTURE_APPEARANCE": "dark"
        ])
        XCTAssertEqual(legacy?.mode, .nowPlaying)
        XCTAssertEqual(legacy?.route, .footer)
        XCTAssertEqual(legacy?.playbackMode, .playing)
        XCTAssertEqual(legacy?.appearance, .dark)
        XCTAssertEqual(legacy?.supportsSeeking, true)
        XCTAssertEqual(legacy?.multipleRoutesDetected, false)
    }

    func testManifestIsUniqueAndCoversEveryRoute() {
        let manifest = ParityFixtureCatalog.routeManifest
        XCTAssertEqual(Set(manifest.map(\.route)).count, manifest.count)
        XCTAssertEqual(Set(manifest.map(\.route)), Set(ParityFixtureRoute.allCases))
        XCTAssertTrue(manifest.allSatisfy { !$0.productionSurface.isEmpty && !$0.states.isEmpty })

        let expectedStates: [ParityFixtureRoute: Set<ParityFixtureState>] = [
            .shell: [.loaded],
            .home: [.loaded],
            .recentlyAdded: [.loaded],
            .recentlyPlayed: [.loaded],
            .albums: [.loaded],
            .albumDetail: [.loaded],
            .artists: [.loaded],
            .artistDetail: [.loaded],
            .songs: [.loaded],
            .genres: [.loaded],
            .genreDetail: [.loaded],
            .playlists: [.loaded],
            .playlistDetail: [.loaded],
            .smartPlaylist: [.loaded],
            .likedSongs: [.loaded],
            .search: [.empty],
            .searchResults: [.loaded],
            .searchNoResults: [.empty],
            .queue: [.loaded, .empty],
            .lyrics: [.synced, .plain, .noLyrics, .loading, .error],
            .footer: [.paused, .playing],
            .miniPlayerArtwork: [.paused, .playing],
            .miniPlayerQueue: [.paused, .playing],
            .miniPlayerLyrics: [.synced, .plain, .noLyrics, .loading, .error],
            .fullscreenNowPlaying: [.paused, .playing]
        ]
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: manifest.map { ($0.route, Set($0.states)) }),
            expectedStates
        )
    }

    func testRouteDefaultsAreRepresentedByTheManifest() {
        for entry in ParityFixtureCatalog.routeManifest {
            let configuration = DeterministicCaptureFixture.configuration(environment: [
                "RESONANCE_PARITY_FIXTURE": "atlas",
                "RESONANCE_PARITY_ROUTE": entry.route.rawValue
            ])
            XCTAssertNotNil(configuration)
            XCTAssertTrue(
                entry.states.contains(configuration!.state),
                "Default state \(configuration!.state.rawValue) is not listed for \(entry.route.rawValue)"
            )
        }
    }

    @MainActor
    func testHiddenStartupAndRuntimeRoutesFallBackWithoutChangingSavedDefault() throws {
        try withTemporaryUserHome {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: "isOnboardingComplete")
            defaults.set(SidebarItem.albums.rawValue, forKey: "defaultViewOnLaunch")
            defaults.set(false, forKey: "showSidebarAlbums")
            defaults.set(true, forKey: "showSidebarHome")

            let appState = AppState()
            XCTAssertEqual(appState.selectedSidebarItem, .home)
            XCTAssertEqual(defaults.string(forKey: "defaultViewOnLaunch"), SidebarItem.albums.rawValue)

            // New Music has its own Settings-backed visibility preference.
            defaults.set(SidebarItem.newMusic.rawValue, forKey: "defaultViewOnLaunch")
            defaults.set(false, forKey: "showSidebarNewMusic")
            appState.selectedSidebarItem = .newMusic
            appState.reconcileSidebarSelectionWithVisibility()
            XCTAssertEqual(appState.selectedSidebarItem, .home)
            XCTAssertEqual(defaults.string(forKey: "defaultViewOnLaunch"), SidebarItem.newMusic.rawValue)

            defaults.set(false, forKey: "showSidebarHome")
            defaults.set(true, forKey: "showSidebarListen")
            appState.selectedSidebarItem = .home
            appState.reconcileSidebarSelectionWithVisibility()
            XCTAssertEqual(appState.selectedSidebarItem, .listen)

            let configurableVisibilityKeys = [
                "showSidebarListen", "showSidebarHome", "showSidebarWaitingRoom",
                "showSidebarProjects", "showSidebarUnclassified", "showSidebarArtists",
                "showSidebarAlbums", "showSidebarSongs", "showSidebarGenres",
                "showSidebarFolders", "showSidebarFavorites", "showSidebarRecentlyAdded",
                "showSidebarRecentlyPlayed", "showSidebarNewMusic", "showSidebarRadio",
                "showSidebarDownloads", FetcherContractSettings.isEnabledKey, "enableOnePlane"
            ]
            for key in configurableVisibilityKeys {
                defaults.set(false, forKey: key)
            }
            appState.selectedSidebarItem = .listen
            appState.reconcileSidebarSelectionWithVisibility()
            XCTAssertEqual(appState.selectedSidebarItem, .search)
            XCTAssertEqual(defaults.string(forKey: "defaultViewOnLaunch"), SidebarItem.newMusic.rawValue)
        }
    }

    @MainActor
    func testQueueEmptyFixtureClearsEveryQueueSection() {
        let catalog = ParityFixtureCatalog.standard
        let manager = QueueManager()
        manager.installDeterministicFixture(
            baseItems: Array(catalog.queue.prefix(3)),
            currentIndex: 0,
            upNextItems: Array(catalog.queue.dropFirst(3).prefix(1)),
            autoPlayItems: Array(catalog.queue.dropFirst(4).prefix(1)),
            history: catalog.queueHistory
        )

        manager.installDeterministicEmptyFixture()

        XCTAssertTrue(manager.isEmpty)
        XCTAssertNil(manager.currentItem)
        XCTAssertTrue(manager.baseItems.isEmpty)
        XCTAssertTrue(manager.upNextItems.isEmpty)
        XCTAssertTrue(manager.autoPlayItems.isEmpty)
        XCTAssertTrue(manager.history.isEmpty)
        XCTAssertEqual(manager.basePosition, -1)
    }

    func testCatalogHasVariationAndReferentialIntegrity() {
        let catalog = ParityFixtureCatalog.standard
        XCTAssertGreaterThanOrEqual(catalog.artists.count, 4)
        XCTAssertGreaterThanOrEqual(catalog.albums.count, 8)
        XCTAssertGreaterThanOrEqual(catalog.songs.count, 24)
        XCTAssertGreaterThanOrEqual(catalog.playlists.count, 3)
        XCTAssertGreaterThanOrEqual(catalog.genres.count, 5)
        XCTAssertFalse(catalog.smartPlaylists.isEmpty)
        XCTAssertTrue(catalog.songs.contains { $0.discNumber == 2 })
        XCTAssertTrue(catalog.songs.contains { $0.isExplicit })
        XCTAssertTrue(catalog.albums.contains { $0.coverArt == nil })
        XCTAssertTrue(catalog.songs.contains { $0.rating != nil })
        XCTAssertTrue(catalog.songs.contains { $0.starred != nil })
        XCTAssertGreaterThan(catalog.lyricsBySongID.values.filter { $0.syncedLyrics != nil }.count, 0)
        XCTAssertGreaterThan(catalog.lyricsBySongID.values.filter { $0.plainLyrics != nil }.count, 0)
        XCTAssertTrue(catalog.lyricsBySongID.values.contains { $0.source == .notFound })

        let artistIDs = Set(catalog.artists.map(\.id))
        let albumIDs = Set(catalog.albums.map(\.id))
        let songIDs = Set(catalog.songs.map(\.id))
        XCTAssertTrue(catalog.albums.allSatisfy { artistIDs.contains($0.artistId) })
        XCTAssertTrue(catalog.songs.allSatisfy { albumIDs.contains($0.albumId) && artistIDs.contains($0.artistId) })
        XCTAssertTrue(catalog.playlistSongIDsByID.values.flatMap { $0 }.allSatisfy { songIDs.contains($0) })
        XCTAssertTrue(catalog.smartPlaylistSongIDsByID.values.flatMap { $0 }.allSatisfy { songIDs.contains($0) })
        XCTAssertTrue(catalog.likedSongIDs.isSubset(of: songIDs))
        XCTAssertTrue(catalog.starredSongIDs.isSubset(of: songIDs))
    }

    func testArtworkIsGeneratedPNGAndVariesByID() {
        let catalog = ParityFixtureCatalog.standard
        let IDs = catalog.artworkIDs.sorted()
        XCTAssertGreaterThanOrEqual(IDs.count, 5)
        let data = IDs.compactMap { catalog.artworkPNGData(for: $0) }
        XCTAssertEqual(data.count, IDs.count)
        XCTAssertTrue(data.allSatisfy { $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) })
        XCTAssertGreaterThan(Set(data).count, 1)
        XCTAssertTrue(data.allSatisfy {
            guard let source = CGImageSourceCreateWithData($0 as CFData, nil) else { return false }
            return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        })
    }

    func testFixtureNetworkActorReturnsCatalogAndFailsClosed() async throws {
        let actor = NetworkActor(catalog: .standard)
        let artists = try await actor.fetchArtists()
        XCTAssertEqual(artists.count, ParityFixtureCatalog.standard.artists.count)
        let albumSongs = try await actor.fetchAlbumSongs(albumId: ParityFixtureCatalog.standard.albums[0].id)
        XCTAssertFalse(albumSongs.isEmpty)
        let art = try await actor.fetchCoverArt(id: "atlas-art-01", size: 120)
        XCTAssertTrue(art.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        do {
            let _: GenresResponse = try await actor.fetch(.getGenres)
            XCTFail("generic fixture fetch should fail closed")
        } catch {
            // Expected: no URLSession request is made.
        }
        do {
            try await actor.scrobble(id: "atlas-song-01", submission: true)
            XCTFail("fixture scrobble should fail closed")
        } catch {
            // Expected: no URLSession request is made.
        }

        let audit = await actor.auditSnapshot()
        XCTAssertEqual(audit.transportRequestCount, 0)
        XCTAssertGreaterThanOrEqual(audit.blockedCallCount, 2)
        XCTAssertEqual(audit.scrobbleAttemptCount, 1)
        let activeServer = await actor.activeServer
        XCTAssertNil(activeServer)
    }

    func testFixtureAlbumWalkCannotReportSuccessAfterCallbackCancelsTask() async {
        let actor = NetworkActor(catalog: .standard)
        let wasCancelled = await Task { () -> Bool in
            do {
                _ = try await actor.fetchAllAlbums { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        XCTAssertTrue(wasCancelled)
        let audit = await actor.auditSnapshot()
        XCTAssertEqual(audit.transportRequestCount, 0)
    }

    func testFixtureSongWalkCannotReportSuccessAfterCallbackCancelsTask() async {
        let actor = NetworkActor(catalog: .standard)
        let wasCancelled = await Task { () -> Bool in
            do {
                _ = try await actor.fetchAllSongs { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        XCTAssertTrue(wasCancelled)
        let audit = await actor.auditSnapshot()
        XCTAssertEqual(audit.transportRequestCount, 0)
    }

    private func withTemporaryUserHome<T>(_ body: () throws -> T) throws -> T {
        let fileManager = FileManager.default
        let homeURL = fileManager.temporaryDirectory
            .appendingPathComponent("ResonanceSidebarVisibility-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)

        let previousHome = getenv("CFFIXED_USER_HOME").map { String(cString: $0) }
        setenv("CFFIXED_USER_HOME", homeURL.path, 1)
        defer {
            if let previousHome {
                setenv("CFFIXED_USER_HOME", previousHome, 1)
            } else {
                unsetenv("CFFIXED_USER_HOME")
            }
            try? fileManager.removeItem(at: homeURL)
        }

        return try body()
    }
}
