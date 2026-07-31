import Foundation
import XCTest
@testable import Resonance

/// Locks the showcase-release contract: the product presents itself as
/// "Resonance", while the isolation identity underneath (bundle namespaces,
/// storage directories, keychain service, loopback-only network policy)
/// keeps its distinct "Public" names so the build can never collide with a
/// private Resonance installation.
final class PublicShowcaseIdentityTests: XCTestCase {

    // MARK: - Internal isolation identity must keep its "Public" names

    func testIsolationNamespacesArePreserved() {
        XCTAssertEqual(PublicDemoConfiguration.appSupportDirectoryName, "Resonance Public")
        XCTAssertEqual(PublicDemoConfiguration.keychainService, "com.resonance.public.server")
    }

    func testDemoServerIsPinnedToLoopback() {
        XCTAssertEqual(PublicDemoConfiguration.serverURL.absoluteString, "http://127.0.0.1:4534")
        XCTAssertEqual(PublicDemoConfiguration.server.url, PublicDemoConfiguration.serverURL)
        XCTAssertEqual(PublicDemoConfiguration.server.name, "Forty")
        XCTAssertEqual(PublicDemoConfiguration.serverUsername, "admin")
        XCTAssertEqual(PublicDemoConfiguration.serverPassword, "demo")
        XCTAssertTrue(PublicDemoConfiguration.isReadOnly)
    }

    func testNetworkAllowlistOnlyAcceptsTheDemoEndpoint() {
        XCTAssertTrue(
            PublicDemoConfiguration.allowsNetworkURL(URL(string: "http://127.0.0.1:4534/rest/ping"))
        )

        for rejected in [
            "http://127.0.0.1",
            "http://127.0.0.2:4534",
            "http://[::1]:4534",
            "http://0.0.0.0:4534",
            "https://demo.navidrome.org",
            "file:///tmp/music"
        ] {
            XCTAssertFalse(
                PublicDemoConfiguration.allowsNetworkURL(URL(string: rejected)),
                "Public demo unexpectedly allowed \(rejected)"
            )
        }

        XCTAssertFalse(PublicDemoConfiguration.allowsNetworkURL(nil))
    }

    // MARK: - User-facing copy must say "Resonance", never "Resonance Public"

    func testLockedServerErrorCopyUsesPlainProductName() throws {
        let error = ResonanceError.publicDemoRequiresLocalServer

        let description = try XCTUnwrap(error.errorDescription)
        XCTAssertEqual(
            description, "This showcase build of Resonance only connects to its local demo library"
        )
        XCTAssertFalse(description.contains("Resonance Public"))

        let suggestion = try XCTUnwrap(error.recoverySuggestion)
        XCTAssertEqual(suggestion, "Start the bundled local demo service on port 4534")
    }
}
