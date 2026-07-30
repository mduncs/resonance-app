import Foundation

/// Termination logic for a paginated library walk, extracted so it can be
/// tested without a server.
///
/// This exists because the rule it encodes is easy to get subtly, silently
/// wrong. The original loops ended the walk when a page contributed no unseen
/// ids, which conflates two very different situations:
///
///   * a short page — the server genuinely has nothing more, and
///   * a full page of rows we happen to have seen already — which merely means
///     the server reordered rows between requests (trivially produced by
///     unstable ordering across ties in `alphabeticalByName`).
///
/// Treating the second as the end truncated a real 28,992-album library to 618
/// albums while still reporting success. Only a short page ends a walk. A
/// duplicate page advances the offset and keeps going, bounded so that a server
/// which repeats forever cannot spin us — and if that bound trips, the walk
/// reports `.truncated` rather than passing a partial result off as complete.
struct LibraryPageWalker {
    enum Step: Equatable {
        /// Advance the offset and request another page.
        case advance
        /// Stop; the payload says whether the walk actually reached the end.
        case stop(LibraryWalkOutcome)
    }

    /// Consecutive all-duplicate full pages tolerated before giving up.
    static let maxConsecutiveNoProgressPages = 5
    /// Hard ceiling on pages per walk, as a backstop against pathological servers.
    static let maxPages = 2_000

    private let pageSize: Int
    private let label: String
    private var consecutiveNoProgressPages = 0
    private var pagesWalked = 0

    init(pageSize: Int, label: String) {
        self.pageSize = pageSize
        self.label = label
    }

    /// Record one fetched page and decide whether to keep walking.
    ///
    /// - Parameters:
    ///   - batchCount: rows the server returned for this page.
    ///   - newItemCount: how many of those were previously unseen.
    ///   - offset: the offset this page was requested at (for diagnostics).
    ///   - totalSoFar: items accumulated so far (for diagnostics).
    mutating func step(
        batchCount: Int,
        newItemCount: Int,
        offset: Int,
        totalSoFar: Int
    ) -> Step {
        pagesWalked += 1

        // The only clean end-of-library signal.
        if batchCount < pageSize {
            return .stop(.complete)
        }

        if newItemCount == 0 {
            consecutiveNoProgressPages += 1
            if consecutiveNoProgressPages >= Self.maxConsecutiveNoProgressPages {
                return .stop(.truncated(
                    reason: "\(label) walk stopped after \(Self.maxConsecutiveNoProgressPages) "
                        + "consecutive full pages of duplicates at offset \(offset); "
                        + "enumerated \(totalSoFar)"
                ))
            }
        } else {
            consecutiveNoProgressPages = 0
        }

        if pagesWalked >= Self.maxPages {
            return .stop(.truncated(
                reason: "\(label) walk hit the \(Self.maxPages)-page ceiling; enumerated \(totalSoFar)"
            ))
        }

        return .advance
    }
}
