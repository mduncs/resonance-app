import XCTest
@testable import Resonance

/// Covers the `PlaneFreshness.intensity` decay curve (NM-2 Growing Edge): full at
/// discovery, linear across the window, gone at/after it, and cleared by both a
/// nil timestamp and the seen flag. Pure and database-free.
final class PlaneFreshnessTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60

    func testFreshDiscoveryIsFullIntensity() {
        let now = Date()
        XCTAssertEqual(
            PlaneFreshness.intensity(discoveredAt: now, isSeen: false, now: now),
            1,
            accuracy: 0.0001
        )
    }

    func testMidWindowDecaysLinearly() {
        let now = Date()
        // Halfway through the 7-day window → half intensity.
        let discoveredAt = now.addingTimeInterval(-3.5 * day)
        XCTAssertEqual(
            PlaneFreshness.intensity(discoveredAt: discoveredAt, isSeen: false, now: now),
            0.5,
            accuracy: 0.0001
        )
    }

    func testExpiredDiscoveryIsZero() {
        let now = Date()
        // At the window edge and beyond → gone.
        XCTAssertEqual(
            PlaneFreshness.intensity(discoveredAt: now.addingTimeInterval(-7 * day), isSeen: false, now: now),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PlaneFreshness.intensity(discoveredAt: now.addingTimeInterval(-8 * day), isSeen: false, now: now),
            0,
            accuracy: 0.0001
        )
    }

    func testSeenClearsGlowImmediately() {
        let now = Date()
        // A brand-new-but-seen arrival still reports zero.
        XCTAssertEqual(
            PlaneFreshness.intensity(discoveredAt: now, isSeen: true, now: now),
            0,
            accuracy: 0.0001
        )
    }

    func testNilDiscoveryIsZero() {
        XCTAssertEqual(
            PlaneFreshness.intensity(discoveredAt: nil, isSeen: false),
            0,
            accuracy: 0.0001
        )
    }

    func testFutureDiscoveryClampsToFull() {
        let now = Date()
        // Clock skew across clients must not overshoot past full.
        XCTAssertEqual(
            PlaneFreshness.intensity(discoveredAt: now.addingTimeInterval(day), isSeen: false, now: now),
            1,
            accuracy: 0.0001
        )
    }
}
