import Foundation

/// Canonical identity used to join Fetcher's absolute paths to Navidrome's
/// music-folder-relative paths without depending on either side's root.
enum PathMatchKey {
    /// Three trailing components retain the usual `album/artist/file`-shaped
    /// context while tolerating a moved or retired library root. Fewer
    /// components make unrelated trees collide too easily; more make ordinary
    /// reorganization needlessly brittle.
    static let defaultComponentCount = 3

    /// Returns a stable, case-insensitive NFC key for the final path components.
    ///
    /// Only `/` is a separator because Resonance and Fetcher are POSIX-only.
    /// Backslashes can be literal title characters in Navidrome-synthesized
    /// paths and must remain inside a component. Splitting drops repeated and
    /// trailing separators, and `.` components are ignored as lexical no-ops.
    static func canonical(
        _ path: String,
        components: Int = defaultComponentCount
    ) -> String? {
        guard components > 0 else { return nil }

        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        guard !parts.isEmpty else { return nil }

        // Normalize before and after locale-stable case folding: the inputs can
        // come from filesystem enumeration (often NFD) or JSON (usually NFC),
        // and folding itself is not promised to preserve normalization form.
        let selected = parts.suffix(components).map { component in
            component
                .precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .precomposedStringWithCanonicalMapping
        }
        guard selected.contains(where: { !$0.isEmpty }) else { return nil }
        return selected.joined(separator: "/")
    }
}
