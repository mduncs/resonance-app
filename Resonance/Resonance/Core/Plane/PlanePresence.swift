import Foundation

/// The three strata of the One Plane surface:
/// Constellation/Shelf are the same stratum (`plane`) at different tile
/// fidelity; Object and Player are nearer distances.
enum PlaneStratum: CaseIterable, Sendable {
    case plane
    case object
    case player
}

/// Scale + opacity of a stratum at a given camera distance.
struct StratumPresence: Equatable, Sendable {
    let scale: Double
    let opacity: Double
}

/// Presence is a pure function of the camera scalar `z ∈ [0, 3]`.
/// Crossfade bands live at z ≈ 1.35–1.75 and
/// z ≈ 2.3–2.9. Do not tune without updating the prototype and decision
/// record together.
enum PlanePresence {
    /// Tile morph parameter: 0 = constellation density, 1 = shelf density.
    static func tz(at z: Double) -> Double {
        min(1, max(0, z))
    }

    static func presence(of stratum: PlaneStratum, at z: Double) -> StratumPresence {
        switch stratum {
        case .plane:
            return StratumPresence(
                scale: z <= 1 ? 1 : 1 + 0.55 * (z - 1),
                opacity: clamped(1 - (z - 1.3) / 0.45)
            )
        case .object:
            return StratumPresence(
                scale: z < 2
                    ? 0.86 + 0.14 * clamped((z - 1.2) / 0.8)
                    : 1 + 0.4 * (z - 2),
                opacity: z < 2
                    ? clamped((z - 1.35) / 0.5)
                    : clamped(1 - (z - 2.3) / 0.45)
            )
        case .player:
            return StratumPresence(
                scale: 0.88 + 0.12 * clamped((z - 2.2) / 0.8),
                opacity: clamped((z - 2.4) / 0.5)
            )
        }
    }

    /// The stratum that should receive pointer/keyboard interaction at `z`:
    /// the one with the greatest opacity (ties resolve toward the nearer
    /// stratum, matching the prototype's iteration order).
    static func interactiveStratum(at z: Double) -> PlaneStratum {
        var best = PlaneStratum.plane
        var bestOpacity = -Double.infinity
        for stratum in PlaneStratum.allCases {
            let opacity = presence(of: stratum, at: z).opacity
            if opacity >= bestOpacity {
                bestOpacity = opacity
                best = stratum
            }
        }
        return best
    }

    private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
