import XCTest
@testable import Resonance

@MainActor
final class FolderBrowserTests: XCTestCase {
    func testProjectionSearchesAllChildrenBeyondInitialWindowAndKeepsFoldersFirst() {
        let folders = [MusicFolder(id: "z", name: "zebra"), MusicFolder(id: "a", name: "Alpha")]
        let songs = (0..<350).map { makeSong(id: "song-\($0)", title: "Track \($0)") }
            + [makeSong(id: "needle", title: "Needle in the last child", artist: "Needle Artist")]
        let directory = MusicDirectory(id: "root", name: "Root", parent: nil,
            children: folders.map(DirectoryChild.folder) + songs.map(DirectoryChild.song))

        let all = FolderBrowserProjection(directory: directory, query: "", hiddenSongIDs: [])
        XCTAssertEqual(all.displayed(limit: 300).folders.map(\.id), ["a", "z"])
        XCTAssertEqual(all.displayed(limit: 300).songs.count, 298)

        let match = FolderBrowserProjection(directory: directory, query: "needle", hiddenSongIDs: [])
        XCTAssertEqual(match.songs.map(\.id), ["needle"])
        XCTAssertEqual(match.folders, [])
    }

    func testProjectionHasStableNameTieBreakAndFiltersHiddenSongs() {
        let directory = MusicDirectory(id: "root", name: "Root", parent: nil, children: [
            .folder(MusicFolder(id: "b", name: "Same")),
            .folder(MusicFolder(id: "a", name: "same")),
            .song(makeSong(id: "b-song", title: "Same")),
            .song(makeSong(id: "a-song", title: "same"))
        ])
        let projection = FolderBrowserProjection(directory: directory, query: "", hiddenSongIDs: ["a-song"])
        XCTAssertEqual(projection.folders.map(\.id), ["a", "b"])
        XCTAssertEqual(projection.songs.map(\.id), ["b-song"])
    }

    func testDirectoryCacheIsServerScopedBoundedAndRefreshCanEvict() {
        let store = FolderBrowserStore(capacity: 2)
        let one = directory(id: "one")
        let two = directory(id: "two")
        let three = directory(id: "three")
        store.cache(one, serverID: "server-a")
        store.cache(two, serverID: "server-a")
        XCTAssertEqual(store.cachedDirectory(serverID: "server-a", id: "one")?.id, "one")
        store.cache(three, serverID: "server-a")
        XCTAssertNil(store.cachedDirectory(serverID: "server-a", id: "two"))
        XCTAssertNil(store.cachedDirectory(serverID: "server-b", id: "one"))
        store.remove(serverID: "server-a", id: "one")
        XCTAssertNil(store.cachedDirectory(serverID: "server-a", id: "one"))
    }

    func testActionLifecycleCancellationCannotLeaveOrClearTheWrongBusyState() {
        var lifecycle = FolderBrowserActionLifecycle()
        let first = lifecycle.begin()
        XCTAssertTrue(lifecycle.isBusy)

        // Navigation/server departure cancels the first request synchronously.
        lifecycle.cancel()
        XCTAssertFalse(lifecycle.isBusy)
        XCTAssertFalse(lifecycle.isCurrent(first))

        let second = lifecycle.begin()
        lifecycle.finish(first) // late first completion must not touch second's UI state
        XCTAssertTrue(lifecycle.isBusy)
        XCTAssertTrue(lifecycle.isCurrent(second))

        lifecycle.finish(second)
        XCTAssertFalse(lifecycle.isBusy)
    }

    private func directory(id: String) -> MusicDirectory {
        MusicDirectory(id: id, name: id, parent: nil, children: [])
    }

    private func makeSong(id: String, title: String, artist: String = "Artist") -> Song {
        Song(id: id, title: title, album: "Album", albumId: "album", artist: artist, artistId: "artist",
             track: nil, discNumber: nil, year: nil, genre: nil, duration: 180, bitRate: nil,
             contentType: "audio/mpeg", suffix: "mp3", coverArt: nil, starred: nil, rating: nil, replayGain: nil)
    }
}
