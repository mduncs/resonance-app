import XCTest
@testable import Resonance

/// Regression cover for response-cache filename derivation.
///
/// The bug these exist to prevent: the filename was `base64(key).prefix(50)`,
/// which is not a hash. Base64 maps each 3 input bytes to 4 output characters,
/// so any two keys sharing a 36-byte plaintext prefix produce an identical
/// 48-character encoded prefix — and truncating at 50 threw away everything
/// that distinguished them.
///
/// The paginated library keys have exactly that shape. The offset, the only
/// varying part, began at character 49 and was sliced off, so every page of the
/// album walk read back page one from disk. A 28,072-album library cached as
/// 618 albums, and no error was ever raised: the cache returned a *valid*
/// response, just the wrong one.
final class ResponseCacheKeyTests: XCTestCase {

    private func filename(_ key: String) -> String {
        CacheActor.responseCacheFilename(for: key)
    }

    // MARK: - The regression

    func testPaginatedAlbumKeysDoNotCollide() {
        let offsets = [0, 500, 1000, 1500, 2000, 2500, 3000]
        let names = offsets.map { filename("getAlbumList2:alphabeticalByName:500:\($0):all") }

        XCTAssertEqual(
            Set(names).count, offsets.count,
            "every page offset must map to its own cache file; collisions make page N read back page 1"
        )
    }

    func testLongSharedPrefixKeysDoNotCollide() {
        // The precise failure shape: identical for far more than 50 base64
        // characters, differing only at the very end.
        let shared = String(repeating: "getAlbumList2:alphabeticalByName:", count: 4)
        XCTAssertNotEqual(filename(shared + "0:all"), filename(shared + "500:all"))
    }

    func testPaginatedSongKeysDoNotCollide() {
        let names = (0..<12).map { filename("search3::0:0:0:0:500:\($0 * 500)") }
        XCTAssertEqual(Set(names).count, 12)
    }

    // MARK: - General properties

    func testFilenameIsStableForTheSameKey() {
        // Write path and read path must agree across calls, or nothing is ever
        // a cache hit.
        XCTAssertEqual(
            filename("getAlbumList2:alphabeticalByName:500:1000:all"),
            filename("getAlbumList2:alphabeticalByName:500:1000:all")
        )
    }

    func testFilenameIsFilesystemSafeAndBounded() {
        // Keys can contain '/' (artist names, paths). The name must stay a
        // single path component and stay well under the 255-byte limit.
        for key in [
            "getCoverArt:AC/DC:600",
            "getAlbumList2:alphabeticalByName:500:0:all",
            String(repeating: "x/y:", count: 500)
        ] {
            let name = filename(key)
            XCTAssertFalse(name.contains("/"), "cache filename must not contain a path separator")
            XCTAssertEqual(name.count, 64 + ".json".count, "SHA-256 hex is fixed length")
            XCTAssertLessThan(name.utf8.count, 255)
        }
    }

    func testDistinctKeysGetDistinctFilenames() {
        let keys = [
            "getAlbumList2:alphabeticalByName:500:0:all",
            "getAlbumList2:alphabeticalByName:500:0:folder-1",
            "getAlbumList2:newest:500:0:all",
            "getAlbumList2:alphabeticalByName:250:0:all",
            "getArtists:all"
        ]
        XCTAssertEqual(Set(keys.map(filename)).count, keys.count)
    }
}
