import Foundation

/// Per-facet raw pagination state for Search3. Offsets advance by server rows,
/// before filtering or deduplication, so Library admission cannot skip matches.
struct SearchPaging {
    struct Facets: OptionSet, Sendable {
        let rawValue: Int
        static let artists = Facets(rawValue: 1)
        static let albums = Facets(rawValue: 2)
        static let songs = Facets(rawValue: 4)
        static let all: Facets = [.artists, .albums, .songs]
    }
    private(set) var artists: [Artist] = []
    private(set) var albums: [Album] = []
    private(set) var songs: [Song] = []
    private(set) var artistOffset = 0
    private(set) var albumOffset = 0
    private(set) var songOffset = 0
    private(set) var artistsExhausted = false
    private(set) var albumsExhausted = false
    private(set) var songsExhausted = false
    private var artistIDs = Set<String>()
    private var albumIDs = Set<String>()
    private var songIDs = Set<String>()
    private var artistRepeats = 0
    private var albumRepeats = 0
    private var songRepeats = 0

    var hasMoreArtists: Bool { !artistsExhausted }
    var hasMoreAlbums: Bool { !albumsExhausted }
    var hasMoreSongs: Bool { !songsExhausted }
    var hasMore: Bool { hasMoreArtists || hasMoreAlbums || hasMoreSongs }

    mutating func reset() { self = SearchPaging() }

    mutating func consume(_ page: SearchResults, requested: Facets = .all) throws {
        // Commit all three facets together only after repeat validation passes.
        var candidate = self
        if requested.contains(.artists) { try Self.consume(page.artists, items: &candidate.artists, ids: &candidate.artistIDs, offset: &candidate.artistOffset,
                    exhausted: &candidate.artistsExhausted, repeats: &candidate.artistRepeats, facet: "artists")
        }
        if requested.contains(.albums) { try Self.consume(page.albums, items: &candidate.albums, ids: &candidate.albumIDs, offset: &candidate.albumOffset,
                    exhausted: &candidate.albumsExhausted, repeats: &candidate.albumRepeats, facet: "albums")
        }
        if requested.contains(.songs) { try Self.consume(page.songs, items: &candidate.songs, ids: &candidate.songIDs, offset: &candidate.songOffset,
                    exhausted: &candidate.songsExhausted, repeats: &candidate.songRepeats, facet: "songs")
        }
        self = candidate
    }

    private static func consume<T: Identifiable>(
        _ page: [T], items: inout [T], ids: inout Set<String>, offset: inout Int,
        exhausted: inout Bool, repeats: inout Int, facet: String
    ) throws where T.ID == String {
        guard !exhausted else { return }
        guard !page.isEmpty else { exhausted = true; return }
        offset += page.count
        let fresh = page.filter { ids.insert($0.id).inserted }
        repeats = fresh.isEmpty ? repeats + 1 : 0
        guard repeats < 3 else {
            throw ResonanceError.networkError(NSError(domain: "Resonance.SearchPagination", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Search results could not be completed for \(facet)."] ))
        }
        items.append(contentsOf: fresh)
    }

    func requestCounts(artists: Bool, albums: Bool, songs: Bool, pageSize: Int = 100) -> (Int, Int, Int) {
        (artists && !artistsExhausted ? pageSize : 0,
         albums && !albumsExhausted ? pageSize : 0,
         songs && !songsExhausted ? pageSize : 0)
    }
}

/// Projects bounded raw Search3 pages through the current Library admission
/// and three-level hidden-item policy. Keeping raw pages in `SearchPaging`
/// lets policy changes re-project immediately without another server request.
struct SearchResultVisibility {
    let libraryOnly: Bool
    let admittedArtistIDs: Set<String>
    let admittedAlbumIDs: Set<String>
    let admittedSongIDs: Set<String>
    let hiddenArtistIDs: Set<String>
    let hiddenAlbumIDs: Set<String>
    let hiddenSongIDs: Set<String>

    func project(_ raw: SearchResults) -> SearchResults {
        SearchResults(
            artists: raw.artists.filter {
                !hiddenArtistIDs.contains($0.id)
                    && (!libraryOnly || admittedArtistIDs.contains($0.id))
            },
            albums: raw.albums.filter {
                !hiddenAlbumIDs.contains($0.id)
                    && !hiddenArtistIDs.contains($0.artistId)
                    && (!libraryOnly || admittedAlbumIDs.contains($0.id))
            },
            songs: raw.songs.filter {
                !hiddenSongIDs.contains($0.id)
                    && !hiddenAlbumIDs.contains($0.albumId)
                    && !hiddenArtistIDs.contains($0.artistId)
                    && (!libraryOnly || admittedSongIDs.contains($0.id))
            }
        )
    }
}
