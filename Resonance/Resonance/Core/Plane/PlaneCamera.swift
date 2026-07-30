import Foundation
import Observation

/// The One Plane camera: one scalar `z ∈ [0, 3]`, driven toward `target` by a
/// critically-damped spring. No locks anywhere — any input retargets mid-flight
/// The spring is a camera transition, not a physical simulation.
///
/// SEAM SKELETON (OP-1): the camera lane replaces `tick`/`step` with the real
/// spring integrator + settle logic and adds tests. The API surface below is
/// pinned — the UI lane is built against it. Do not rename members.
@MainActor
@Observable
final class PlaneCamera {
    /// Current camera distance, 0 = Constellation … 3 = Player.
    private(set) var z: Double
    /// Where the spring is heading. Clamped to [0, 3].
    private(set) var target: Double
    /// Spring velocity in z-units per second.
    private(set) var velocity: Double = 0

    /// True when the spring has come to rest on its target.
    var isSettled: Bool { z == target && velocity == 0 }

    private var lastTick: TimeInterval?

    init(z: Double = 0.35, target: Double = 1) {
        self.z = min(3, max(0, z))
        self.target = min(3, max(0, target))
    }

    /// Retarget the spring. Callable mid-flight; never blocks or animates.
    func setTarget(_ t: Double) {
        target = min(3, max(0, t))
    }

    /// Continuous input (pinch): move the target by a delta.
    func nudgeTarget(by delta: Double) {
        setTarget(target + delta)
    }

    /// Ease the target to the nearest whole distance (gesture rest).
    func settleToNearest() {
        setTarget(target.rounded())
    }

    /// Jump instantly (reduced motion, or programmatic reset).
    func snap(to t: Double) {
        target = min(3, max(0, t))
        z = target
        velocity = 0
        lastTick = nil
    }

    /// Advance the spring. Drive from the UI (e.g. `TimelineView(.animation)`),
    /// passing a monotonic timestamp. The first tick after `init`/`snap` only
    /// records the timestamp so a long initial gap never teleports the camera.
    func tick(now: TimeInterval) {
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let dt = min(0.032, max(0, now - last))
        let stepped = PlaneCamera.step(z: z, velocity: velocity, target: target, dt: dt)
        z = stepped.z
        velocity = stepped.velocity
    }

    /// Pure critically-damped spring step — unit-testable. Ports the prototype's
    /// Camera integrator: acceleration
    /// `k·(target−z) − 2√k·v`, semi-implicit Euler, and a settle epsilon that
    /// snaps exactly onto the target once `|target−z| < 0.0006` and `|v| < 0.002`.
    ///
    /// Overshoot handling: `z` is clamped into `[0, 3]` after integration so the
    /// camera never renders off the axis, but `velocity` is left untouched. The
    /// spring restoring force then bleeds that carried velocity off on the next
    /// ticks — zeroing it at the wall would instead kill the natural rebound and
    /// read as a hard stop.
    static func step(
        z: Double,
        velocity: Double,
        target: Double,
        dt: Double,
        stiffness: Double = 90
    ) -> (z: Double, velocity: Double) {
        let k = stiffness
        let c = 2 * k.squareRoot()          // critically damped
        let a = k * (target - z) - c * velocity
        let newVelocity = velocity + a * dt
        let integratedZ = z + newVelocity * dt
        if abs(target - integratedZ) < 0.0006 && abs(newVelocity) < 0.002 {
            return (z: target, velocity: 0)
        }
        return (z: min(3, max(0, integratedZ)), velocity: newVelocity)
    }
}
