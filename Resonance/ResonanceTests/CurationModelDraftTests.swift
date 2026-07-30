import Foundation
import XCTest
@testable import Resonance

final class CurationModelDraftTests: XCTestCase {
    func testPublicDemoNetworkAllowlistIsExact() {
        XCTAssertTrue(
            PublicDemoConfiguration.allowsNetworkURL(URL(string: "http://127.0.0.1:4534"))
        )

        for rejected in [
            "https://127.0.0.1:4534",
            "http://127.0.0.1:4533",
            "http://localhost:4534",
            "http://127.0.0.1.example.com:4534",
            "http://example.com:4534",
            "http://user:password@127.0.0.1:4534"
        ] {
            XCTAssertFalse(
                PublicDemoConfiguration.allowsNetworkURL(URL(string: rejected)),
                "Public demo unexpectedly allowed \(rejected)"
            )
        }
    }


    func testSerializedEnumRawValuesMatchCurationStorageContract() {
        XCTAssertEqual(LibraryItemType.allCases.map(\.rawValue), ["song", "album", "artist"])
        XCTAssertEqual(
            LibraryAdmissionSource.allCases.map(\.rawValue),
            ["navidrome_library", "manual", "import", "apple_music", "project"]
        )
        XCTAssertEqual(
            AttentionMarkType.allCases.map(\.rawValue),
            ["liked", "loved", "later", "interesting", "hidden", "dismissed", "more_like_this"]
        )
        XCTAssertEqual(
            WaitingRoomState.allCases.map(\.rawValue),
            ["unheard", "partly_heard", "heard", "skipped", "replayed", "interesting", "admitted", "rejected"]
        )
    }

    func testSerializedEnumRawValuesAreUnique() {
        XCTAssertEqual(Set(LibraryItemType.allCases.map(\.rawValue)).count, LibraryItemType.allCases.count)
        XCTAssertEqual(
            Set(LibraryAdmissionSource.allCases.map(\.rawValue)).count,
            LibraryAdmissionSource.allCases.count
        )
        XCTAssertEqual(Set(AttentionMarkType.allCases.map(\.rawValue)).count, AttentionMarkType.allCases.count)
        XCTAssertEqual(Set(WaitingRoomState.allCases.map(\.rawValue)).count, WaitingRoomState.allCases.count)
    }

    func testImportPolicyDefaultRegistryMatchesCurationContract() {
        XCTAssertEqual(
            ImportPolicyDefaults.allKeys,
            [
                "importPolicyAutoAdmitNavidromeLibrary",
                "importPolicyStageServerImports",
                "importPolicyKeepUnclassifiedOutOfLibrary",
                "importPolicyAutoMarkPartialAuditions",
                "importPolicyAutoMarkHeardAuditions"
            ]
        )
        XCTAssertEqual(Set(ImportPolicyDefaults.defaultValues.keys), Set(ImportPolicyDefaults.allKeys))
        XCTAssertEqual(ImportPolicyDefaults.defaultValue(for: ImportPolicyDefaults.autoAdmitNavidromeLibrary), true)
        XCTAssertEqual(ImportPolicyDefaults.defaultValue(for: ImportPolicyDefaults.stageServerImports), false)
        XCTAssertEqual(ImportPolicyDefaults.defaultValue(for: ImportPolicyDefaults.keepUnclassifiedOutOfLibrary), true)
        XCTAssertEqual(ImportPolicyDefaults.defaultValue(for: ImportPolicyDefaults.autoMarkPartialAuditions), true)
        XCTAssertEqual(ImportPolicyDefaults.defaultValue(for: ImportPolicyDefaults.autoMarkHeardAuditions), true)
    }

    @MainActor
    func testCompletedOnboardingCanStartWithoutSavedServer() throws {
        try withTemporaryUserHome {
            try withUserDefaultValues(for: ["isOnboardingComplete", "servers", "defaultViewOnLaunch"]) {
                UserDefaults.standard.set(true, forKey: "isOnboardingComplete")
                UserDefaults.standard.removeObject(forKey: "servers")
                UserDefaults.standard.set(SidebarItem.listen.rawValue, forKey: "defaultViewOnLaunch")

                let appState = AppState()

                XCTAssertTrue(appState.isOnboardingComplete)
                XCTAssertNil(appState.activeServer)
                XCTAssertTrue(appState.servers.isEmpty)
                XCTAssertEqual(appState.selectedSidebarItem, .listen)

                appState.isOnboardingComplete = false
                XCTAssertFalse(UserDefaults.standard.bool(forKey: "isOnboardingComplete"))

                appState.isOnboardingComplete = true
                XCTAssertTrue(UserDefaults.standard.bool(forKey: "isOnboardingComplete"))
            }
        }
    }

    func testServerSettingsTabContractSupportsDeferredServerSetup() {
        XCTAssertEqual(SettingsTab.storageKey, "settingsSelectedTab")
        XCTAssertEqual(SettingsTab.general.rawValue, "general")
        XCTAssertEqual(SettingsTab.server.rawValue, "server")
        XCTAssertEqual(SettingsTab.general.title, "General")
        XCTAssertEqual(SettingsTab.server.title, "Server")
        XCTAssertEqual(SettingsTab.allCases.map(\.rawValue), [
            "general",
            "playback",
            "library",
            "importing",
            "appearance",
            "storage",
            "server",
            "privacy",
            "shortcuts",
            "advanced"
        ])
    }

    func testImportPolicyBoolUsesRegisteredDefaultUntilStoredOverrideExists() throws {
        let suiteName = "CurationModelDraftTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(ImportPolicyDefaults.bool(for: ImportPolicyDefaults.autoAdmitNavidromeLibrary, in: defaults))
        XCTAssertFalse(ImportPolicyDefaults.bool(for: ImportPolicyDefaults.stageServerImports, in: defaults))
        XCTAssertFalse(ImportPolicyDefaults.bool(for: "unknownPolicy", in: defaults))
        XCTAssertTrue(ImportPolicyDefaults.bool(for: "unknownPolicy", in: defaults, default: true))

        defaults.set(false, forKey: ImportPolicyDefaults.autoAdmitNavidromeLibrary)
        defaults.set(true, forKey: ImportPolicyDefaults.stageServerImports)
        defaults.set(true, forKey: "unknownPolicy")

        XCTAssertFalse(ImportPolicyDefaults.bool(for: ImportPolicyDefaults.autoAdmitNavidromeLibrary, in: defaults))
        XCTAssertTrue(ImportPolicyDefaults.bool(for: ImportPolicyDefaults.stageServerImports, in: defaults))
        XCTAssertTrue(ImportPolicyDefaults.bool(for: "unknownPolicy", in: defaults))
    }

    func testImportPolicyRegistrationExposesDefaultsToUserDefaults() throws {
        let suiteName = "CurationModelDraftTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        ImportPolicyDefaults.register(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: ImportPolicyDefaults.autoAdmitNavidromeLibrary))
        XCTAssertFalse(defaults.bool(forKey: ImportPolicyDefaults.stageServerImports))
        XCTAssertTrue(defaults.bool(forKey: ImportPolicyDefaults.keepUnclassifiedOutOfLibrary))
        XCTAssertTrue(defaults.bool(forKey: ImportPolicyDefaults.autoMarkPartialAuditions))
        XCTAssertTrue(defaults.bool(forKey: ImportPolicyDefaults.autoMarkHeardAuditions))
    }

    func testImportPolicyDerivedImportDecisionsMatchApplyContract() throws {
        let suiteName = "CurationModelDraftTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(ImportPolicyDefaults.shouldAdmitImportedMedia(in: defaults))
        XCTAssertFalse(ImportPolicyDefaults.shouldStageImportedSongs(in: defaults))

        defaults.set(false, forKey: ImportPolicyDefaults.autoAdmitNavidromeLibrary)

        XCTAssertFalse(ImportPolicyDefaults.shouldAdmitImportedMedia(in: defaults))
        XCTAssertFalse(ImportPolicyDefaults.shouldStageImportedSongs(in: defaults))

        defaults.set(true, forKey: ImportPolicyDefaults.stageServerImports)

        XCTAssertFalse(ImportPolicyDefaults.shouldAdmitImportedMedia(in: defaults))
        XCTAssertTrue(ImportPolicyDefaults.shouldStageImportedSongs(in: defaults))

        defaults.set(false, forKey: ImportPolicyDefaults.keepUnclassifiedOutOfLibrary)

        XCTAssertTrue(ImportPolicyDefaults.shouldAdmitImportedMedia(in: defaults))
        XCTAssertFalse(ImportPolicyDefaults.shouldStageImportedSongs(in: defaults))
    }

    func testWaitingRoomDecisionStatesAreTerminalOnlyForAdmissionChoices() {
        XCTAssertFalse(WaitingRoomState.unheard.isDecided)
        XCTAssertFalse(WaitingRoomState.partlyHeard.isDecided)
        XCTAssertFalse(WaitingRoomState.heard.isDecided)
        XCTAssertFalse(WaitingRoomState.skipped.isDecided)
        XCTAssertFalse(WaitingRoomState.replayed.isDecided)
        XCTAssertFalse(WaitingRoomState.interesting.isDecided)
        XCTAssertTrue(WaitingRoomState.admitted.isDecided)
        XCTAssertTrue(WaitingRoomState.rejected.isDecided)
    }

    func testProjectCodableRoundTripPreservesIdentityAndMetadata() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_700_003_600)
        let archivedAt = Date(timeIntervalSince1970: 1_700_007_200)
        let project = Project(
            id: "project-1",
            serverId: "server-1",
            name: "Blue Note Deep Dive",
            kind: "collection",
            createdAt: createdAt,
            updatedAt: updatedAt,
            archivedAt: archivedAt,
            notes: "Start with late-night jazz records."
        )

        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: encoded)

        XCTAssertEqual(decoded, project)
    }

    func testProjectDefaultsAreStableForNewCurationWorkspaces() {
        let project = Project(serverId: "server-1", name: "Label Batch")

        XCTAssertFalse(project.id.isEmpty)
        XCTAssertEqual(project.serverId, "server-1")
        XCTAssertEqual(project.name, "Label Batch")
        XCTAssertEqual(project.kind, "collection")
        XCTAssertNil(project.archivedAt)
        XCTAssertNil(project.notes)
        XCTAssertLessThanOrEqual(project.createdAt, project.updatedAt)
    }

    func testProjectItemIDIncludesProjectTypeAndItemIdentity() {
        let item = ProjectItem(
            projectId: "project-1",
            itemId: "album-42",
            itemType: .album,
            serverId: "server-1",
            position: 3,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            addedBy: "manual",
            note: "Compare deluxe edition."
        )

        XCTAssertEqual(item.id, "project-1:album:album-42")
    }

    func testProjectSongItemIdentityDelegatesToProjectItem() {
        let projectItem = ProjectItem(
            projectId: "project-1",
            itemId: "song-1",
            itemType: .song,
            serverId: "server-1",
            position: 0,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            addedBy: "manual",
            note: nil
        )
        let item = ProjectSongItem(projectItem: projectItem, song: makeSong(id: "song-1"))

        XCTAssertEqual(item.id, projectItem.id)
        XCTAssertEqual(item.song?.id, "song-1")
    }

    func testFetcherSourceProjectReferencesDoNotAdmitOrStageSongs() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let serverId = "server-fetcher-source-project"
            let project = Project(
                serverId: serverId,
                name: "Source Current",
                kind: "collection",
                notes: "Fetcher source: source:alpha"
            )

            let insertResult = try database.saveProjectWithSongReferences(
                project,
                songIds: [" nav-song-first ", "nav-song-second", "nav-song-first", ""],
                addedBy: "fetcher_source",
                note: "Fetcher source: source:alpha"
            )

            let items = try database.loadProjectItems(projectId: project.id, serverId: serverId)

            XCTAssertEqual(insertResult.requestedCount, 4)
            XCTAssertEqual(insertResult.uniqueRequestedCount, 2)
            XCTAssertEqual(insertResult.addedItemIds, ["nav-song-first", "nav-song-second"])
            XCTAssertEqual(items.map(\.itemId), ["nav-song-first", "nav-song-second"])
            XCTAssertEqual(items.map(\.position), [0, 1])
            XCTAssertEqual(Set(items.map(\.addedBy)), ["fetcher_source"])
            XCTAssertTrue(try database.loadProjectSongs(projectId: project.id, serverId: serverId).isEmpty)
            XCTAssertFalse(try database.isInLibrary(id: "nav-song-first", type: .song, serverId: serverId))
            XCTAssertTrue(try database.loadWaitingRoomItems(serverId: serverId, includeDecided: true).isEmpty)
        }
    }

    func testFetcherSourceProjectReferenceBatchSkipsExistingSongsAndPreservesOrder() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let serverId = "server-fetcher-source-project-batch"
            let project = Project(
                serverId: serverId,
                name: "Source Batch",
                kind: "collection",
                notes: "Fetcher source: source:alpha"
            )

            let firstInsert = try database.saveProjectWithSongReferences(
                project,
                songIds: ["song-a", "song-b"],
                addedBy: "fetcher_source",
                note: "initial source insert"
            )
            let secondInsert = try database.addProjectSongReferences(
                projectId: project.id,
                songIds: ["song-b", "song-c", "song-a", "song-d"],
                serverId: serverId,
                addedBy: "fetcher_source",
                note: "second source insert"
            )
            let items = try database.loadProjectItems(projectId: project.id, serverId: serverId)

            XCTAssertEqual(firstInsert.addedItemIds, ["song-a", "song-b"])
            XCTAssertEqual(secondInsert.addedItemIds, ["song-c", "song-d"])
            XCTAssertEqual(secondInsert.skippedExistingItemIds, ["song-b", "song-a"])
            XCTAssertEqual(items.map(\.itemId), ["song-a", "song-b", "song-c", "song-d"])
            XCTAssertEqual(items.map(\.position), [0, 1, 2, 3])
            XCTAssertEqual(items.map(\.note), [
                "initial source insert",
                "initial source insert",
                "second source insert",
                "second source insert"
            ])
            XCTAssertTrue(try database.loadProjectSongs(projectId: project.id, serverId: serverId).isEmpty)
            XCTAssertFalse(try database.isInLibrary(id: "song-c", type: .song, serverId: serverId))
            XCTAssertTrue(try database.loadWaitingRoomItems(serverId: serverId, includeDecided: true).isEmpty)
        }
    }

    func testWaitingRoomItemCodableRoundTripPreservesAuditionContract() throws {
        let item = WaitingRoomItem(
            song: makeSong(id: "song-1"),
            serverId: "server-1",
            state: .partlyHeard,
            source: "server_import",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            firstAuditionedAt: Date(timeIntervalSince1970: 1_700_000_010),
            lastAuditionedAt: Date(timeIntervalSince1970: 1_700_000_090),
            auditionCount: 2,
            auditionSeconds: 120,
            lastPositionSeconds: 95,
            admittedAt: nil,
            rejectedAt: nil,
            notes: "Needs another listen"
        )

        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(WaitingRoomItem.self, from: encoded)

        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.id, "song-1")
    }

    func testImportPolicyStagesServerImportsWhenAutoAdmitIsDisabled() throws {
        try withTemporaryUserHome {
            try withImportPolicyDefaults([
                ImportPolicyDefaults.autoAdmitNavidromeLibrary: false,
                ImportPolicyDefaults.keepUnclassifiedOutOfLibrary: true,
                ImportPolicyDefaults.stageServerImports: true
            ]) {
                let database = try DatabaseManager()
                let serverId = "server-policy-stage"
                let song = makeSong(id: "song-stage")

                try database.saveSongs([song], serverId: serverId)

                XCTAssertFalse(try database.isInLibrary(id: song.id, type: .song, serverId: serverId))
                let waitingItems = try database.loadWaitingRoomItems(serverId: serverId, includeDecided: true)
                XCTAssertEqual(waitingItems.map(\.song.id), [song.id])
                XCTAssertEqual(waitingItems.first?.state, .unheard)
            }
        }
    }

    func testCachedSongCanBeLoadedByServerScopedId() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let firstServer = "server-fetcher-candidate"
            let secondServer = "server-other"
            let song = makeSong(id: "song-fetcher-candidate")

            try database.saveSongs([song], serverId: firstServer)

            XCTAssertEqual(try database.loadCachedSong(id: song.id, serverId: firstServer)?.id, song.id)
            XCTAssertNil(try database.loadCachedSong(id: song.id, serverId: secondServer))
        }
    }

    func testImportPolicyAdmitsServerImportsWhenUnclassifiedBoundaryIsDisabled() throws {
        try withTemporaryUserHome {
            try withImportPolicyDefaults([
                ImportPolicyDefaults.autoAdmitNavidromeLibrary: false,
                ImportPolicyDefaults.stageServerImports: true,
                ImportPolicyDefaults.keepUnclassifiedOutOfLibrary: false
            ]) {
                let database = try DatabaseManager()
                let serverId = "server-policy-admit-unclassified"
                let song = makeSong(id: "song-admitted-by-policy")

                try database.saveArtists([makeArtist(id: song.artistId)], serverId: serverId)
                try database.saveAlbums([makeAlbum(id: song.albumId, artistId: song.artistId)], serverId: serverId)
                try database.saveSongs([song], serverId: serverId)

                XCTAssertTrue(try database.isInLibrary(id: song.id, type: .song, serverId: serverId))
                XCTAssertTrue(try database.isInLibrary(id: song.albumId, type: .album, serverId: serverId))
                XCTAssertTrue(try database.isInLibrary(id: song.artistId, type: .artist, serverId: serverId))
                XCTAssertTrue(try database.loadWaitingRoomItems(serverId: serverId, includeDecided: true).isEmpty)
            }
        }
    }

    func testSongAdmissionIncludesRelatedAlbumAndArtistMembership() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let serverId = "server-song-related-admission"
            let song = makeSong(id: "song-related-admission")

            try database.admitSongAndRelated(
                song,
                serverId: serverId,
                admittedBy: .manual,
                sourceDetail: "test"
            )

            XCTAssertTrue(try database.isInLibrary(id: song.id, type: .song, serverId: serverId))
            XCTAssertTrue(try database.isInLibrary(id: song.albumId, type: .album, serverId: serverId))
            XCTAssertTrue(try database.isInLibrary(id: song.artistId, type: .artist, serverId: serverId))
            XCTAssertEqual(try database.loadAdmittedSongs(serverId: serverId).map(\.id), [song.id])
            XCTAssertEqual(try database.loadAdmittedAlbums(serverId: serverId).map(\.id), [song.albumId])
            XCTAssertEqual(try database.loadAdmittedArtists(serverId: serverId).map(\.id), [song.artistId])
        }
    }

    func testSongAdmissionUnhideClearsRelatedSongAlbumAndArtistRows() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let serverId = "server-song-related-unhide"
            let song = makeSong(id: "song-related-unhide")

            try database.hideItem(id: song.id, type: "song", serverId: serverId)
            try database.hideItem(id: song.albumId, type: "album", serverId: serverId)
            try database.hideItem(id: song.artistId, type: "artist", serverId: serverId)

            try database.unhideSongAndRelated(song, serverId: serverId)

            XCTAssertFalse(try database.isHidden(id: song.id, type: "song", serverId: serverId))
            XCTAssertFalse(try database.isHidden(id: song.albumId, type: "album", serverId: serverId))
            XCTAssertFalse(try database.isHidden(id: song.artistId, type: "artist", serverId: serverId))
        }
    }

    func testPlayHistoryCanBeScopedToActiveServer() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let firstServer = "server-history-one"
            let secondServer = "server-history-two"
            let firstSong = makeSong(id: "song-history-one")
            let secondSong = makeSong(id: "song-history-two")

            _ = try database.recordPlay(song: firstSong, serverId: firstServer)
            _ = try database.recordPlay(song: secondSong, serverId: secondServer)

            let allHistory = try database.loadPlayHistory(limit: 10)
            XCTAssertEqual(Set(allHistory.map(\.serverId)), [firstServer, secondServer])
            XCTAssertEqual(
                try database.loadPlayHistory(serverId: firstServer, limit: 10).map(\.songId),
                [firstSong.id]
            )
            XCTAssertEqual(
                try database.loadPlayHistory(serverId: secondServer, limit: 10).map(\.songId),
                [secondSong.id]
            )
            XCTAssertTrue(try database.loadPlayHistory(serverId: "unknown-server", limit: 10).isEmpty)
        }
    }

    @MainActor
    func testPlaybackManagerQueueInsertionFiltersHiddenSongs() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let serverId = "server-playback-hidden"
            let visibleSong = makeSong(id: "song-visible")
            let hiddenSong = makeSong(id: "song-hidden")
            let queueManager = QueueManager()
            let networkActor = NetworkActor()
            let cacheActor = CacheActor()
            let playbackManager = PlaybackManager(
                audioActor: AudioActor(),
                networkActor: networkActor,
                cacheActor: cacheActor,
                queueManager: queueManager,
                databaseManager: database,
                lyricsService: LyricsService(networkActor: networkActor, cacheActor: cacheActor)
            )
            playbackManager.activeServerId = serverId

            try database.hideItem(id: hiddenSong.id, type: "song", serverId: serverId)

            playbackManager.addToQueue([visibleSong, hiddenSong])
            playbackManager.playNext(hiddenSong)

            XCTAssertEqual(queueManager.upNextItems.map(\.song.id), [visibleSong.id])
            XCTAssertNil(queueManager.currentItem)
            XCTAssertFalse(queueManager.needsPlaybackStart)
        }
    }

    func testWaitingRoomDecisionRowsAreExcludedUnlessRequested() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let serverId = "server-decisions"
            let admittedSong = makeSong(id: "song-admitted")
            let rejectedSong = makeSong(id: "song-rejected")

            try database.upsertWaitingRoomItem(song: admittedSong, serverId: serverId, state: .unheard)
            try database.upsertWaitingRoomItem(song: rejectedSong, serverId: serverId, state: .unheard)
            try database.setWaitingRoomState(songId: admittedSong.id, serverId: serverId, state: .admitted)
            try database.setWaitingRoomState(songId: rejectedSong.id, serverId: serverId, state: .rejected)

            XCTAssertTrue(try database.loadWaitingRoomItems(serverId: serverId).isEmpty)

            let decidedItems = try database.loadWaitingRoomItems(serverId: serverId, includeDecided: true)
            XCTAssertEqual(Set(decidedItems.map(\.song.id)), [admittedSong.id, rejectedSong.id])
            XCTAssertEqual(try waitingRoomItem(in: database, songId: admittedSong.id, serverId: serverId).state, .admitted)
            XCTAssertEqual(try waitingRoomItem(in: database, songId: rejectedSong.id, serverId: serverId).state, .rejected)
        }
    }

    func testWaitingRoomNonTerminalUpsertDoesNotOverwriteTerminalDecisionMetadata() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let serverId = "server-terminal-fetcher-stage"
            let song = makeSong(id: "song-terminal-fetcher-stage")

            try database.upsertWaitingRoomItem(
                song: song,
                serverId: serverId,
                state: .rejected,
                source: "manual_reject",
                notes: "keep this decision"
            )
            let original = try waitingRoomItem(in: database, songId: song.id, serverId: serverId)

            try database.upsertWaitingRoomItem(
                song: song,
                serverId: serverId,
                state: .unheard,
                source: "fetcher_contract",
                notes: "new Fetcher staging note"
            )

            let staged = try waitingRoomItem(in: database, songId: song.id, serverId: serverId)
            XCTAssertEqual(staged.state, .rejected)
            XCTAssertEqual(staged.source, "manual_reject")
            XCTAssertEqual(staged.notes, "keep this decision")
            XCTAssertEqual(staged.updatedAt, original.updatedAt)
        }
    }

    func testWaitingRoomAuditionsAdvanceCountsAndStates() throws {
        try withTemporaryUserHome {
            try withImportPolicyDefaults([
                ImportPolicyDefaults.autoMarkPartialAuditions: true,
                ImportPolicyDefaults.autoMarkHeardAuditions: true
            ]) {
                let database = try DatabaseManager()
                let serverId = "server-auditions"
                let partialSong = makeSong(id: "song-partial")
                let heardSong = makeSong(id: "song-heard")

                try database.upsertWaitingRoomItem(song: partialSong, serverId: serverId, state: .unheard)
                try database.incrementWaitingRoomAudition(
                    songId: partialSong.id,
                    serverId: serverId,
                    seconds: 30,
                    lastPositionSeconds: 30
                )

                var partialItem = try waitingRoomItem(in: database, songId: partialSong.id, serverId: serverId)
                XCTAssertEqual(partialItem.state, .partlyHeard)
                XCTAssertEqual(partialItem.auditionCount, 1)
                XCTAssertEqual(partialItem.auditionSeconds, 30)
                XCTAssertEqual(partialItem.lastPositionSeconds, 30)

                try database.incrementWaitingRoomAudition(songId: partialSong.id, serverId: serverId, seconds: 15)
                partialItem = try waitingRoomItem(in: database, songId: partialSong.id, serverId: serverId)
                XCTAssertEqual(partialItem.state, .replayed)
                XCTAssertEqual(partialItem.auditionCount, 2)
                XCTAssertEqual(partialItem.auditionSeconds, 45)

                try database.upsertWaitingRoomItem(song: heardSong, serverId: serverId, state: .unheard)
                try database.incrementWaitingRoomAudition(songId: heardSong.id, serverId: serverId, seconds: 120)

                let heardItem = try waitingRoomItem(in: database, songId: heardSong.id, serverId: serverId)
                XCTAssertEqual(heardItem.state, .heard)
                XCTAssertEqual(heardItem.auditionCount, 1)
                XCTAssertEqual(heardItem.auditionSeconds, 120)
            }
        }
    }

    func testAuditionPolicyCanCountWithoutChangingWaitingRoomState() throws {
        try withTemporaryUserHome {
            try withImportPolicyDefaults([
                ImportPolicyDefaults.autoMarkPartialAuditions: false,
                ImportPolicyDefaults.autoMarkHeardAuditions: false
            ]) {
                let database = try DatabaseManager()
                let serverId = "server-audition-policy"
                let song = makeSong(id: "song-policy")

                try database.upsertWaitingRoomItem(song: song, serverId: serverId, state: .unheard)
                try database.incrementWaitingRoomAudition(songId: song.id, serverId: serverId, seconds: 180)

                let item = try waitingRoomItem(in: database, songId: song.id, serverId: serverId)
                XCTAssertEqual(item.state, .unheard)
                XCTAssertEqual(item.auditionCount, 1)
                XCTAssertEqual(item.auditionSeconds, 180)
            }
        }
    }

    private func makeSong(id: String) -> Song {
        Song(
            id: id,
            title: "Test Song",
            album: "Test Album",
            albumId: "album-1",
            artist: "Test Artist",
            artistId: "artist-1",
            track: 1,
            discNumber: 1,
            year: 2026,
            genre: "Ambient",
            duration: 180,
            bitRate: 320,
            contentType: "audio/mpeg",
            suffix: "mp3",
            coverArt: nil,
            starred: nil,
            rating: nil,
            replayGain: nil
        )
    }

    private func makeAlbum(id: String, artistId: String) -> Album {
        Album(
            id: id,
            name: "Test Album",
            artist: "Test Artist",
            artistId: artistId,
            songCount: 1,
            duration: 180,
            year: 2026,
            genre: "Ambient",
            coverArt: nil,
            starred: nil,
            rating: nil
        )
    }

    private func makeArtist(id: String) -> Artist {
        Artist(
            id: id,
            name: "Test Artist",
            albumCount: 1,
            coverArt: nil,
            starred: nil
        )
    }

    private func waitingRoomItem(
        in database: DatabaseManager,
        songId: String,
        serverId: String
    ) throws -> WaitingRoomItem {
        try XCTUnwrap(
            database.loadWaitingRoomItems(serverId: serverId, includeDecided: true)
                .first { $0.song.id == songId }
        )
    }

    private func withTemporaryUserHome<T>(_ body: () throws -> T) throws -> T {
        let fileManager = FileManager.default
        let homeURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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

    private func withImportPolicyDefaults<T>(
        _ values: [String: Bool],
        body: () throws -> T
    ) throws -> T {
        let defaults = UserDefaults.standard
        let keys = Set(values.keys).union(ImportPolicyDefaults.allKeys)
        var previousValues: [String: Any] = [:]

        for key in keys {
            if let previousValue = defaults.object(forKey: key) {
                previousValues[key] = previousValue
            }
        }

        for key in keys {
            if let value = values[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defer {
            for key in keys {
                if let previousValue = previousValues[key] {
                    defaults.set(previousValue, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        return try body()
    }

    private func withUserDefaultValues<T>(
        for keys: [String],
        body: () throws -> T
    ) throws -> T {
        let defaults = UserDefaults.standard
        var previousValues: [String: Any] = [:]

        for key in keys {
            if let previousValue = defaults.object(forKey: key) {
                previousValues[key] = previousValue
            }
            defaults.removeObject(forKey: key)
        }

        defer {
            for key in keys {
                if let previousValue = previousValues[key] {
                    defaults.set(previousValue, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        return try body()
    }
}
