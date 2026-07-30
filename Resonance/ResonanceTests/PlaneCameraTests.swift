import XCTest
@testable import Resonance

/// Characterizes the One Plane camera spring (OP-1 camera lane). The integrator
/// These tests pin the camera integrator's
/// behavior: convergence, mid-flight interruptibility, dt clamping, the settle
/// epsilon, gesture rounding, and snap.
@MainActor
final class PlaneCameraTests: XCTestCase {

    private let fps = 60.0

    /// Drive `cam` for `frames` steps at `fps`, returning the `z` after each.
    /// The first `tick` only records the timestamp (per the skeleton contract),
    /// so the returned array has exactly `frames` samples.
    @discardableResult
    private func run(_ cam: PlaneCamera, frames: Int, startTime: TimeInterval = 1_000) -> [Double] {
        let dt = 1.0 / fps
        cam.tick(now: startTime)                 // first tick: records timestamp only
        var zs: [Double] = []
        zs.reserveCapacity(frames)
        for i in 1...frames {
            cam.tick(now: startTime + Double(i) * dt)
            zs.append(cam.z)
        }
        return zs
    }

    // MARK: convergence

    func testConvergesToTargetMonotonicallyAndSettlesExactly() {
        let cam = PlaneCamera(z: 0.35, target: 1)
        let zs = run(cam, frames: 120)           // ~2s, comfortably past settle

        // Critically damped: rises toward the target, no meaningful overshoot.
        var prev = 0.35
        for z in zs {
            XCTAssertGreaterThanOrEqual(z, prev - 1e-12, "z should not move backward")
            XCTAssertLessThanOrEqual(z, 1 + 1e-9, "critically damped spring must not overshoot")
            prev = z
        }

        // Close to the target within ~1s of 60fps ticks.
        XCTAssertEqual(zs[59], 1, accuracy: 0.03, "within ~1s the camera is essentially there")

        // Ends resting exactly on the target with zero velocity.
        XCTAssertTrue(cam.isSettled)
        XCTAssertEqual(cam.z, 1)
        XCTAssertEqual(cam.velocity, 0)
    }

    // MARK: interruptibility

    func testRetargetMidFlightConvergesWithoutDiscontinuity() {
        let cam = PlaneCamera(z: 0, target: 3)
        let dt = 1.0 / fps
        let start = 500.0
        cam.tick(now: start)                     // records timestamp only

        // Fly toward 3 for a while, then retarget mid-flight to 1.
        var frame = 1
        var prev = cam.z
        // The largest plausible single-frame move: peak spring speed ≈ ωΔ/e with
        // ω=√90≈9.49 and Δ=3 → ~10.5 z/s → ~0.18 per 60fps frame. A real
        // discontinuity (teleport on retarget) would be order 1–3, so 0.3 both
        // admits genuine motion and catches a jump.
        let maxPlausibleStep = 0.3
        for _ in 0..<30 {
            cam.tick(now: start + Double(frame) * dt)
            XCTAssertLessThan(abs(cam.z - prev), maxPlausibleStep)
            prev = cam.z
            frame += 1
        }

        cam.setTarget(1)                         // interrupt: z and velocity carry over

        for _ in 0..<300 {
            cam.tick(now: start + Double(frame) * dt)
            XCTAssertLessThan(abs(cam.z - prev), maxPlausibleStep, "no jump across the retarget")
            prev = cam.z
            frame += 1
        }

        XCTAssertTrue(cam.isSettled)
        XCTAssertEqual(cam.z, 1)
        XCTAssertEqual(cam.velocity, 0)
    }

    // MARK: dt clamp

    func testFiveSecondGapDoesNotTeleport() {
        let cam = PlaneCamera(z: 0, target: 3)
        cam.tick(now: 0)                          // records timestamp only
        cam.tick(now: 5)                          // 5s gap → dt clamped to 0.032

        // One clamped step from rest: a=270, v=270·0.032=8.64, z=8.64·0.032≈0.276.
        // Without the clamp (dt=5) z would fly to ~6750 and pin at 3.
        XCTAssertGreaterThan(cam.z, 0)
        XCTAssertLessThan(cam.z, 0.5, "large real-time gap advances by one clamped step, not a teleport")
        XCTAssertFalse(cam.isSettled)
    }

    // MARK: settle epsilon

    func testSettleEpsilonSnapsExactlyToTarget() {
        // Inside |target−z|<0.0006 with a sub-0.002 resulting velocity → exact snap.
        let result = PlaneCamera.step(z: 0.9999, velocity: 0, target: 1, dt: 1.0 / 60.0)
        XCTAssertEqual(result.z, 1)
        XCTAssertEqual(result.velocity, 0)

        // Just outside the position epsilon → keeps integrating, no snap.
        let notYet = PlaneCamera.step(z: 0.997, velocity: 0, target: 1, dt: 1.0 / 60.0)
        XCTAssertNotEqual(notYet.z, 1)
    }

    // MARK: gesture rounding

    func testSettleToNearestRoundsAtHalfBoundaries() {
        let low = PlaneCamera(z: 0, target: 0)
        low.nudgeTarget(by: 1.49)
        low.settleToNearest()
        XCTAssertEqual(low.target, 1, "1.49 rounds down to 1")

        let high = PlaneCamera(z: 0, target: 0)
        high.nudgeTarget(by: 1.51)
        high.settleToNearest()
        XCTAssertEqual(high.target, 2, "1.51 rounds up to 2")

        // nudge also stays clamped to the axis.
        let clamped = PlaneCamera(z: 0, target: 0)
        clamped.nudgeTarget(by: 99)
        XCTAssertEqual(clamped.target, 3)
        clamped.nudgeTarget(by: -99)
        XCTAssertEqual(clamped.target, 0)
    }

    // MARK: snap

    func testSnapResetsStateAndNextTickDoesNotJump() {
        let cam = PlaneCamera(z: 0, target: 3)
        run(cam, frames: 20)                      // build up velocity in flight
        XCTAssertNotEqual(cam.velocity, 0)

        cam.snap(to: 2)
        XCTAssertEqual(cam.z, 2)
        XCTAssertEqual(cam.target, 2)
        XCTAssertEqual(cam.velocity, 0)
        XCTAssertTrue(cam.isSettled)

        // snap cleared lastTick, so the next tick (even after a huge gap) only
        // records the timestamp — no dt is applied, no jump.
        cam.tick(now: 10_000)
        XCTAssertEqual(cam.z, 2)
        XCTAssertEqual(cam.velocity, 0)

        // And the following normal tick continues smoothly (already settled).
        cam.tick(now: 10_000 + 1.0 / fps)
        XCTAssertEqual(cam.z, 2, accuracy: 1e-12)
        XCTAssertEqual(cam.velocity, 0)
    }
}
