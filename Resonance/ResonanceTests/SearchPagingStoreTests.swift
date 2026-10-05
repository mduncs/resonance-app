import XCTest
@testable import Resonance

@MainActor
final class SearchPagingStoreTests: XCTestCase {
    func testInitialRequestIsSingleBoundedAllFacetRequest() async {
        let source = SearchStoreFake()
        let store = SearchPagingStore { request in await source.page(for: request) }
        store.begin(query: "q", scope: "library", serverID: "s")
        await settle()
        let calls = await source.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].facets, .all)
    }

    func testDoubleMoreOnlyStartsOneRequest() async {
        let source = SearchStoreFake()
        let store = SearchPagingStore { request in await source.page(for: request) }
        store.begin(query: "q", scope: "library", serverID: "s"); await settle()
        store.loadMore(.artists); store.loadMore(.artists); await settle()
        let calls = await source.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testMoreFailurePreservesResultsAndRetryClearsError() async {
        let source = SearchStoreFake(failMore: true)
        let store = SearchPagingStore { request in try await source.throwingPage(for: request) }
        store.begin(query: "q", scope: "library", serverID: "s"); await settle()
        let offset = store.paging.artistOffset
        store.loadMore(.artists); await settle()
        XCTAssertEqual(store.paging.artistOffset, offset)
        XCTAssertNotNil(store.moreError)
        XCTAssertTrue(store.hasCompletedInitialRequest)
        await source.allowRetry()
        store.retry(); await settle()
        XCTAssertNil(store.moreError)
        XCTAssertEqual(store.paging.artistOffset, offset + 1)
    }

    func testEmptyBeginResetsOldLoadingAndResults() async {
        let source = SearchStoreFake()
        let store = SearchPagingStore { request in await source.page(for: request) }
        store.begin(query: "old", scope: "library", serverID: "s")
        await settle()

        store.begin(query: "", scope: "library", serverID: "s")

        XCTAssertFalse(store.isInitialLoading)
        XCTAssertFalse(store.isLoadingMore)
        XCTAssertTrue(store.rawResults.isEmpty)
        XCTAssertFalse(store.hasCompletedInitialRequest)
    }

    func testDelayedAIsDiscardedAfterBCompletes() async {
        let source = ControlledSearchStoreSource()
        let store = SearchPagingStore { request in try await source.page(for: request) }
        store.begin(query: "A", scope: "library", serverID: "s")
        await source.waitForCallCount(1)
        store.begin(query: "B", scope: "library", serverID: "s")
        await source.waitForCallCount(2)

        await source.resume(query: "B", artistID: "b")
        await settle()
        await source.resume(query: "A", artistID: "a")
        await settle()

        XCTAssertEqual(store.identity?.query, "B")
        XCTAssertEqual(store.paging.artists.map(\.id), ["b"])
        XCTAssertFalse(store.isInitialLoading)
    }

    func testCancelThenNewRequestOldCompletionCannotClearNewBusyState() async {
        let source = ControlledSearchStoreSource()
        let store = SearchPagingStore { request in try await source.page(for: request) }
        store.begin(query: "A", scope: "library", serverID: "s")
        await source.waitForCallCount(1)
        store.cancel()
        store.begin(query: "B", scope: "global", serverID: "s2")
        await source.waitForCallCount(2)

        await source.resume(query: "A", artistID: "a")
        await settle()
        XCTAssertTrue(store.isInitialLoading)

        await source.resume(query: "B", artistID: "b")
        await settle()
        XCTAssertFalse(store.isInitialLoading)
        XCTAssertEqual(store.paging.artists.map(\.id), ["b"])
    }

    func testCanceledDebounceNeverInvokesSource() async {
        let source = SearchStoreFake()
        let store = SearchPagingStore { request in await source.page(for: request) }
        store.begin(query: "A", scope: "library", serverID: "s", debounce: .milliseconds(100))
        store.begin(query: "B", scope: "global", serverID: "s2", debounce: .milliseconds(1))
        try? await Task.sleep(for: .milliseconds(130))

        let calls = await source.calls
        XCTAssertEqual(calls.map(\.identity.query), ["B"])
        XCTAssertEqual(store.identity, .init(query: "B", scope: "global", serverID: "s2"))
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(30)) }
}

private actor ControlledSearchStoreSource {
    private var calls: [SearchPagingStore.Request] = []
    private var continuations: [String: CheckedContinuation<SearchResults, Error>] = [:]

    func page(for request: SearchPagingStore.Request) async throws -> SearchResults {
        calls.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[request.identity.query] = continuation
        }
    }

    func waitForCallCount(_ expected: Int) async {
        while calls.count < expected { await Task.yield() }
    }

    func resume(query: String, artistID: String) {
        continuations.removeValue(forKey: query)?.resume(returning: SearchResults(
            artists: [Artist(id: artistID, name: artistID, albumCount: 0, coverArt: nil, starred: nil)],
            albums: [],
            songs: []
        ))
    }
}

actor SearchStoreFake {
    private var storedCalls: [SearchPagingStore.Request] = []
    private var failMore: Bool
    init(failMore: Bool = false) { self.failMore = failMore }
    var calls: [SearchPagingStore.Request] { storedCalls }
    func page(for request: SearchPagingStore.Request) -> SearchResults {
        storedCalls.append(request); return result(request.artistOffset)
    }
    func throwingPage(for request: SearchPagingStore.Request) throws -> SearchResults {
        storedCalls.append(request)
        if failMore && request.artistOffset > 0 { throw ResonanceError.notConfigured }
        return result(request.artistOffset)
    }
    func allowRetry() { failMore = false }
    private func result(_ offset: Int) -> SearchResults {
        SearchResults(artists: [Artist(id: "a\(offset)", name: "a", albumCount: 0, coverArt: nil, starred: nil)], albums: [], songs: [])
    }
}
