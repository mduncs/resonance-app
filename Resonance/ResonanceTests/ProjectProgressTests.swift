import XCTest
@testable import Resonance

final class ProjectProgressTests: XCTestCase {
    private let serverId = "srv-1"

    // MARK: - 1. Empty project

    func testEmptyProjectHasNoProgressStatesOrNextUp() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let project = Project(serverId: serverId, name: "Empty")
            try database.saveProject(project)

            let progress = try database.projectProgress(projectId: project.id, serverId: serverId)

            XCTAssertEqual(progress.totalSongs, 0)
            XCTAssertEqual(progress.heardCount, 0)
            XCTAssertEqual(progress.markedCount, 0)
            XCTAssertEqual(progress.remainingCount, 0)
            XCTAssertTrue(
                try database.projectItemListenStates(projectId: project.id, serverId: serverId).isEmpty
            )
            XCTAssertTrue(
                try database.projectNextUp(projectId: project.id, serverId: serverId, limit: 10).isEmpty
            )
        }
    }

    // MARK: - 2. Mixed progress

    func testMixedProgressCountsAndListenStates() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let project = Project(serverId: serverId, name: "Mixed")
            let songs = (1...4).map { makeSong(id: "s\($0)") }
            try seed(project: project, songs: songs, database: database)

            try database.recordPlay(song: songs[0], serverId: serverId)
            try database.recordPlay(song: songs[1], serverId: serverId)
            try database.markAttention(
                id: songs[1].id,
                type: .song,
                serverId: serverId,
                markType: .interesting
            )
            try database.markAttention(
                id: songs[2].id,
                type: .song,
                serverId: serverId,
                markType: .interesting
            )

            let progress = try database.projectProgress(projectId: project.id, serverId: serverId)
            XCTAssertEqual(progress.totalSongs, 4)
            XCTAssertEqual(progress.heardCount, 2)
            XCTAssertEqual(progress.markedCount, 2)
            XCTAssertEqual(progress.remainingCount, 2)

            let states = try database.projectItemListenStates(
                projectId: project.id,
                serverId: serverId
            )
            XCTAssertEqual(states.count, 4)
            assertState(states[songs[0].id], is: .heard)
            assertState(states[songs[1].id], is: .marked)
            assertState(states[songs[2].id], is: .marked)
            assertState(states[songs[3].id], is: .unheard)
        }
    }

    // MARK: - 3. Next-up ordering

    func testNextUpOrdersUnheardBeforeHeardAndHonorsLimit() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let project = Project(serverId: serverId, name: "Ordered")
            let songs = (1...4).map { makeSong(id: "s\($0)") }
            try seed(project: project, songs: songs, database: database, firstPosition: 1)

            try database.recordPlay(song: songs[1], serverId: serverId)
            try database.recordPlay(song: songs[2], serverId: serverId)

            let all = try database.projectNextUp(
                projectId: project.id,
                serverId: serverId,
                limit: 10
            )
            XCTAssertEqual(all.map(\.id), ["s1", "s4", "s2", "s3"])

            let limited = try database.projectNextUp(
                projectId: project.id,
                serverId: serverId,
                limit: 3
            )
            XCTAssertEqual(limited.map(\.id), ["s1", "s4", "s2"])
        }
    }

    // MARK: - 4. Mark sources and cleared state

    func testLikedAndStarredAreMarkedButUnstarredAndClearedAreNot() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let project = Project(serverId: serverId, name: "Marks")
            let songs = (1...4).map { makeSong(id: "s\($0)") }
            try seed(project: project, songs: songs, database: database)

            try database.likeItem(id: songs[0].id, type: "song", serverId: serverId)
            try database.starItem(id: songs[1].id, type: "song", serverId: serverId)

            try database.starItem(id: songs[2].id, type: "song", serverId: serverId)
            try database.unstarItem(id: songs[2].id, type: "song", serverId: serverId)

            try database.markAttention(
                id: songs[3].id,
                type: .song,
                serverId: serverId,
                markType: .later
            )
            try database.clearAttention(
                id: songs[3].id,
                type: .song,
                serverId: serverId,
                markType: .later
            )

            let progress = try database.projectProgress(projectId: project.id, serverId: serverId)
            XCTAssertEqual(progress.totalSongs, 4)
            XCTAssertEqual(progress.heardCount, 0)
            XCTAssertEqual(progress.markedCount, 2)
            XCTAssertEqual(progress.remainingCount, 4)

            let states = try database.projectItemListenStates(
                projectId: project.id,
                serverId: serverId
            )
            assertState(states[songs[0].id], is: .marked)
            assertState(states[songs[1].id], is: .marked)
            assertState(states[songs[2].id], is: .unheard)
            assertState(states[songs[3].id], is: .unheard)
        }
    }

    // MARK: - 5. Unresolvable references

    func testUnresolvableReferencesAreExcluded() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let project = Project(serverId: serverId, name: "References")
            let song = makeSong(id: "resolved")
            try seed(project: project, songs: [song], database: database)
            try database.addProjectItem(
                projectId: project.id,
                itemId: "not-cached",
                itemType: .song,
                serverId: serverId,
                position: 2
            )

            let progress = try database.projectProgress(projectId: project.id, serverId: serverId)
            XCTAssertEqual(progress.totalSongs, 1)
            XCTAssertEqual(progress.heardCount, 0)
            XCTAssertEqual(progress.markedCount, 0)
            XCTAssertEqual(progress.remainingCount, 1)

            let states = try database.projectItemListenStates(
                projectId: project.id,
                serverId: serverId
            )
            XCTAssertEqual(Set(states.keys), [song.id])
            assertState(states[song.id], is: .unheard)

            let nextUp = try database.projectNextUp(
                projectId: project.id,
                serverId: serverId,
                limit: 10
            )
            XCTAssertEqual(nextUp.map(\.id), [song.id])
        }
    }

    // MARK: - 6. Server scoping

    func testProgressExcludesItemsSeededUnderAnotherServer() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let project = Project(serverId: serverId, name: "Scoped")
            let localSong = makeSong(id: "local")
            try seed(project: project, songs: [localSong], database: database)

            let otherServerId = "srv-other"
            let foreignSong = makeSong(id: "foreign")
            try database.saveSongs([foreignSong], serverId: otherServerId)
            try database.addProjectItem(
                projectId: project.id,
                itemId: foreignSong.id,
                itemType: .song,
                serverId: otherServerId,
                position: 1
            )
            try database.recordPlay(song: foreignSong, serverId: otherServerId)
            try database.markAttention(
                id: foreignSong.id,
                type: .song,
                serverId: otherServerId,
                markType: .interesting
            )

            let progress = try database.projectProgress(projectId: project.id, serverId: serverId)
            XCTAssertEqual(progress.totalSongs, 1)
            XCTAssertEqual(progress.heardCount, 0)
            XCTAssertEqual(progress.markedCount, 0)
            XCTAssertEqual(progress.remainingCount, 1)

            let states = try database.projectItemListenStates(
                projectId: project.id,
                serverId: serverId
            )
            XCTAssertEqual(Set(states.keys), [localSong.id])
            assertState(states[localSong.id], is: .unheard)

            let nextUp = try database.projectNextUp(
                projectId: project.id,
                serverId: serverId,
                limit: 10
            )
            XCTAssertEqual(nextUp.map(\.id), [localSong.id])
        }
    }

    // MARK: - Helpers

    private func seed(
        project: Project,
        songs: [Song],
        database: DatabaseManager,
        firstPosition: Int = 0
    ) throws {
        try database.saveProject(project)
        try database.saveSongs(songs, serverId: project.serverId)
        for (offset, song) in songs.enumerated() {
            try database.addProjectItem(
                projectId: project.id,
                itemId: song.id,
                itemType: .song,
                serverId: project.serverId,
                position: firstPosition + offset
            )
        }
    }

    private func assertState(
        _ actual: ProjectItemListenState?,
        is expected: ProjectItemListenState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("Expected listen state, got nil", file: file, line: line)
            return
        }

        switch (actual, expected) {
        case (.unheard, .unheard), (.heard, .heard), (.marked, .marked):
            break
        default:
            XCTFail(
                "Expected \(String(describing: expected)), got \(String(describing: actual))",
                file: file,
                line: line
            )
        }
    }

    private func makeSong(id: String) -> Song {
        Song(
            id: id,
            title: "Title \(id)",
            album: "Album",
            albumId: "album-1",
            artist: "Artist",
            artistId: "artist-1",
            track: 1,
            discNumber: 1,
            year: 2026,
            genre: "Rock",
            duration: 200,
            bitRate: 320,
            contentType: "audio/flac",
            suffix: "flac",
            coverArt: nil,
            path: nil
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
}
