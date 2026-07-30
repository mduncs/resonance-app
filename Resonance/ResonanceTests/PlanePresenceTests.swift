import XCTest
@testable import Resonance

/// Characterization tests for `PlanePresence` — its implementation is FINAL and
/// These tests pin the exact scale and
/// opacity of every stratum, the crossfade bands, and the interactive-stratum
/// (max-opacity, ties-toward-nearer) rule so a future edit that drifts from the
/// prototype fails loudly. Expected values are derived by hand from the
/// constants in `PlanePresence.swift`.
final class PlanePresenceTests: XCTestCase {

    private let acc = 1e-12

    private func opacity(_ stratum: PlaneStratum, _ z: Double) -> Double {
        PlanePresence.presence(of: stratum, at: z).opacity
    }
    private func scale(_ stratum: PlaneStratum, _ z: Double) -> Double {
        PlanePresence.presence(of: stratum, at: z).scale
    }

    // MARK: exact values at the whole distances

    func testPlanePresenceAtWholeDistances() {
        // scale: z<=1 → 1, else 1 + 0.55·(z−1). op: clamped(1 − (z−1.3)/0.45).
        XCTAssertEqual(scale(.plane, 0), 1, accuracy: acc)
        XCTAssertEqual(opacity(.plane, 0), 1, accuracy: acc)     // 1+2.888 → clamp 1
        XCTAssertEqual(scale(.plane, 1), 1, accuracy: acc)
        XCTAssertEqual(opacity(.plane, 1), 1, accuracy: acc)     // 1+0.667 → clamp 1
        XCTAssertEqual(scale(.plane, 2), 1.55, accuracy: acc)
        XCTAssertEqual(opacity(.plane, 2), 0, accuracy: acc)     // 1−1.556 → clamp 0
        XCTAssertEqual(scale(.plane, 3), 2.10, accuracy: acc)
        XCTAssertEqual(opacity(.plane, 3), 0, accuracy: acc)
    }

    func testObjectPresenceAtWholeDistances() {
        // z<2: scale 0.86 + 0.14·clamp((z−1.2)/0.8), op clamp((z−1.35)/0.5).
        // z>=2: scale 1 + 0.4·(z−2),           op clamp(1 − (z−2.3)/0.45).
        XCTAssertEqual(scale(.object, 0), 0.86, accuracy: acc)   // clamp(−1.5)=0
        XCTAssertEqual(opacity(.object, 0), 0, accuracy: acc)
        XCTAssertEqual(scale(.object, 1), 0.86, accuracy: acc)   // clamp(−0.25)=0
        XCTAssertEqual(opacity(.object, 1), 0, accuracy: acc)
        XCTAssertEqual(scale(.object, 2), 1, accuracy: acc)      // 1+0.4·0
        XCTAssertEqual(opacity(.object, 2), 1, accuracy: acc)    // 1+0.667 → clamp 1
        XCTAssertEqual(scale(.object, 3), 1.4, accuracy: acc)    // 1+0.4·1
        XCTAssertEqual(opacity(.object, 3), 0, accuracy: acc)    // 1−1.556 → clamp 0
    }

    func testPlayerPresenceAtWholeDistances() {
        // scale 0.88 + 0.12·clamp((z−2.2)/0.8). op clamp((z−2.4)/0.5).
        XCTAssertEqual(scale(.player, 0), 0.88, accuracy: acc)   // clamp(−2.75)=0
        XCTAssertEqual(opacity(.player, 0), 0, accuracy: acc)
        XCTAssertEqual(scale(.player, 1), 0.88, accuracy: acc)
        XCTAssertEqual(opacity(.player, 1), 0, accuracy: acc)
        XCTAssertEqual(scale(.player, 2), 0.88, accuracy: acc)   // clamp(−0.25)=0
        XCTAssertEqual(opacity(.player, 2), 0, accuracy: acc)    // clamp(−0.8)=0
        XCTAssertEqual(scale(.player, 3), 1.0, accuracy: acc)    // 0.88+0.12·1
        XCTAssertEqual(opacity(.player, 3), 1, accuracy: acc)    // clamp(1.2)=1
    }

    // MARK: crossfade bands

    func testPlaneOpaqueUntil1_3AndTransparentBy1_75() {
        XCTAssertEqual(opacity(.plane, 1.2), 1, accuracy: acc)
        XCTAssertEqual(opacity(.plane, 1.3), 1, accuracy: acc)   // band start
        XCTAssertEqual(opacity(.plane, 1.525), 0.5, accuracy: 1e-9)  // midpoint
        XCTAssertEqual(opacity(.plane, 1.75), 0, accuracy: acc)  // band end
        XCTAssertEqual(opacity(.plane, 1.8), 0, accuracy: acc)
    }

    func testObjectOpacityRampsInOver1_35To1_85AndOutOver2_3To2_75() {
        // ramp in
        XCTAssertEqual(opacity(.object, 1.35), 0, accuracy: acc)
        XCTAssertEqual(opacity(.object, 1.6), 0.5, accuracy: 1e-9)
        XCTAssertEqual(opacity(.object, 1.85), 1, accuracy: acc)
        // plateau across the object distance
        XCTAssertEqual(opacity(.object, 2.3), 1, accuracy: acc)
        // ramp out
        XCTAssertEqual(opacity(.object, 2.525), 0.5, accuracy: 1e-9)
        XCTAssertEqual(opacity(.object, 2.75), 0, accuracy: acc)
    }

    func testPlayerOpacityRampsInOver2_4To2_9() {
        XCTAssertEqual(opacity(.player, 2.4), 0, accuracy: acc)
        XCTAssertEqual(opacity(.player, 2.65), 0.5, accuracy: 1e-9)
        XCTAssertEqual(opacity(.player, 2.9), 1, accuracy: acc)
    }

    // MARK: interactive stratum

    func testInteractiveStratumAtWholeDistances() {
        XCTAssertEqual(PlanePresence.interactiveStratum(at: 0), .plane)
        XCTAssertEqual(PlanePresence.interactiveStratum(at: 1), .plane)
        XCTAssertEqual(PlanePresence.interactiveStratum(at: 2), .object)
        XCTAssertEqual(PlanePresence.interactiveStratum(at: 3), .player)
    }

    func testInteractiveStratumSwitchesInsideCrossfadeBands() {
        // plane→object band: plane still dominant early, object dominant late.
        XCTAssertEqual(PlanePresence.interactiveStratum(at: 1.5), .plane)
        XCTAssertEqual(PlanePresence.interactiveStratum(at: 1.7), .object)
        // object→player band.
        XCTAssertEqual(PlanePresence.interactiveStratum(at: 2.5), .object)
        XCTAssertEqual(PlanePresence.interactiveStratum(at: 2.8), .player)
    }

    /// The interactive stratum must equal the max-opacity stratum across the
    /// whole axis, with ties resolved toward the nearer stratum (later in
    /// `allCases` order), exactly as the prototype iterates.
    func testInteractiveStratumMatchesMaxOpacityRuleAcrossAxis() {
        let order = PlaneStratum.allCases   // plane, object, player
        var z = 0.0
        while z <= 3.0 {
            var best = order[0]
            var bestOp = -Double.infinity
            for stratum in order {
                let op = opacity(stratum, z)
                if op >= bestOp {           // >= → ties go to the nearer stratum
                    bestOp = op
                    best = stratum
                }
            }
            XCTAssertEqual(
                PlanePresence.interactiveStratum(at: z), best,
                "interactive stratum disagrees with max-opacity rule at z=\(z)"
            )
            z += 0.01
        }
    }

    // MARK: tz clamp

    func testTzClampsToUnitInterval() {
        XCTAssertEqual(PlanePresence.tz(at: -1), 0, accuracy: acc)
        XCTAssertEqual(PlanePresence.tz(at: 0), 0, accuracy: acc)
        XCTAssertEqual(PlanePresence.tz(at: 0.5), 0.5, accuracy: acc)
        XCTAssertEqual(PlanePresence.tz(at: 1), 1, accuracy: acc)
        XCTAssertEqual(PlanePresence.tz(at: 2), 1, accuracy: acc)
        XCTAssertEqual(PlanePresence.tz(at: 3), 1, accuracy: acc)
    }
}
