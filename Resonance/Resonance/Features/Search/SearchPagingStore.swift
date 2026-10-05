import Foundation
import Observation

@MainActor
@Observable
final class SearchPagingStore {
    struct Identity: Equatable, Sendable {
        let query: String
        let scope: String
        let serverID: String
    }

    struct Request: Equatable, Sendable {
        let identity: Identity
        let generation: Int
        fileprivate let operation: Int
        let facets: SearchPaging.Facets
        let artistOffset: Int
        let albumOffset: Int
        let songOffset: Int
    }

    enum Phase: Equatable, Sendable { case initial, more }

    private struct Failure {
        let request: Request
        let phase: Phase
    }

    typealias PageSource = @MainActor @Sendable (Request) async throws -> SearchResults

    private var pageSource: PageSource
    private(set) var identity: Identity?
    private(set) var generation = 0
    private(set) var paging = SearchPaging()
    private(set) var isInitialLoading = false
    private(set) var isLoadingMore = false
    private(set) var initialError: ResonanceError?
    private(set) var moreError: ResonanceError?
    private(set) var completedInitialIdentity: Identity?

    private var operation = 0
    private var failure: Failure?
    @ObservationIgnored
    private var requestTask: Task<Void, Never>?

    init(pageSource: @escaping PageSource = { _ in throw ResonanceError.notConfigured }) {
        self.pageSource = pageSource
    }
    deinit { requestTask?.cancel() }

    var rawResults: SearchResults {
        SearchResults(artists: paging.artists, albums: paging.albums, songs: paging.songs)
    }

    var hasCompletedInitialRequest: Bool {
        completedInitialIdentity == identity
    }

    func begin(
        query: String,
        scope: String,
        serverID: String,
        debounce: Duration? = nil,
        pageSource: PageSource? = nil
    ) {
        invalidateActiveRequest()
        if let pageSource { self.pageSource = pageSource }
        generation += 1
        paging.reset()
        initialError = nil
        moreError = nil
        failure = nil
        completedInitialIdentity = nil
        isInitialLoading = false
        isLoadingMore = false

        let next = Identity(query: query, scope: scope, serverID: serverID)
        identity = next
        guard !query.isEmpty else { return }
        schedule(descriptor(identity: next, facets: .all), phase: .initial, debounce: debounce)
    }

    func loadMore(_ facets: SearchPaging.Facets) {
        guard requestTask == nil, let identity, !isInitialLoading, !isLoadingMore else { return }
        let request = descriptor(identity: identity, facets: facets)
        guard !request.facets.isEmpty else { return }
        moreError = nil
        schedule(request, phase: .more, debounce: nil)
    }

    func retry() {
        guard requestTask == nil, let failure,
              failure.request.generation == generation,
              failure.request.identity == identity else { return }
        let request = Request(
            identity: failure.request.identity,
            generation: generation,
            operation: nextOperation(),
            facets: failure.request.facets,
            artistOffset: failure.request.artistOffset,
            albumOffset: failure.request.albumOffset,
            songOffset: failure.request.songOffset
        )
        switch failure.phase {
        case .initial: initialError = nil
        case .more: moreError = nil
        }
        schedule(request, phase: failure.phase, debounce: nil)
    }

    func cancel() {
        invalidateActiveRequest()
        generation += 1
        failure = nil
        isInitialLoading = false
        isLoadingMore = false
    }

    private func invalidateActiveRequest() {
        requestTask?.cancel()
        requestTask = nil
        operation += 1
    }

    private func nextOperation() -> Int {
        operation += 1
        return operation
    }

    private func descriptor(identity: Identity, facets: SearchPaging.Facets) -> Request {
        let counts = paging.requestCounts(
            artists: facets.contains(.artists),
            albums: facets.contains(.albums),
            songs: facets.contains(.songs)
        )
        var open: SearchPaging.Facets = []
        if counts.0 > 0 { open.insert(.artists) }
        if counts.1 > 0 { open.insert(.albums) }
        if counts.2 > 0 { open.insert(.songs) }
        return Request(
            identity: identity,
            generation: generation,
            operation: nextOperation(),
            facets: open,
            artistOffset: paging.artistOffset,
            albumOffset: paging.albumOffset,
            songOffset: paging.songOffset
        )
    }

    private func schedule(_ request: Request, phase: Phase, debounce: Duration?) {
        switch phase {
        case .initial: isInitialLoading = true
        case .more: isLoadingMore = true
        }
        requestTask = Task { [weak self] in
            if let debounce {
                do {
                    try await Task.sleep(for: debounce)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self?.run(request, phase: phase)
        }
    }

    private func run(_ request: Request, phase: Phase) async {
        defer { finish(request, phase: phase) }
        do {
            try Task.checkCancellation()
            let page = try await pageSource(request)
            try Task.checkCancellation()
            guard isCurrent(request) else { return }
            try paging.consume(page, requested: request.facets)
            failure = nil
            switch phase {
            case .initial:
                initialError = nil
                completedInitialIdentity = request.identity
            case .more:
                moreError = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(request), !Task.isCancelled else { return }
            let mapped = (error as? ResonanceError) ?? .networkError(error)
            failure = Failure(request: request, phase: phase)
            switch phase {
            case .initial: initialError = mapped
            case .more: moreError = mapped
            }
        }
    }

    private func finish(_ request: Request, phase: Phase) {
        guard isCurrent(request) else { return }
        requestTask = nil
        switch phase {
        case .initial: isInitialLoading = false
        case .more: isLoadingMore = false
        }
    }

    private func isCurrent(_ request: Request) -> Bool {
        request.generation == generation
            && request.operation == operation
            && request.identity == identity
    }
}
