import SwiftUI
import AppKit

// MARK: - Color Blending Extension

extension Color {
    /// Blend this color with another color
    func blended(with other: Color, ratio: CGFloat = 0.5) -> Color {
        let nsColor = NSColor(self)
        let otherNS = NSColor(other)

        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0

        nsColor.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        otherNS.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)

        return Color(
            red: r1 * (1 - ratio) + r2 * ratio,
            green: g1 * (1 - ratio) + g2 * ratio,
            blue: b1 * (1 - ratio) + b2 * ratio,
            opacity: a1 * (1 - ratio) + a2 * ratio
        )
    }
}

/// Animated mesh gradient background that uses EmotionEngine colors
/// Creates slowly moving, organic blob-like gradients
struct EmotionGradientBackground: View {
    let primaryColor: Color
    let secondaryColor: Color
    let backgroundColor: Color

    /// Whether playback is active (enables subtle pulse)
    var isPlaying: Bool = false

    @State private var phase: CGFloat = 0
    @State private var breathe: CGFloat = 1.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/60, paused: false)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                drawGradientBlobs(context: context, size: size, time: time)
            }
        }
        .blur(radius: 80)
        .saturation(1.1)
        .onChange(of: isPlaying) { _, playing in
            withAnimation(.easeInOut(duration: 0.5)) {
                breathe = playing ? 1.0 : 0.95
            }
        }
    }

    private func drawGradientBlobs(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let slowTime = time * 0.15 // Slow movement

        // Base layer - dark background
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(backgroundColor.opacity(0.8))
        )

        // Blob 1 - Primary color, large, slow orbit
        let blob1Center = CGPoint(
            x: size.width * (0.3 + 0.2 * sin(slowTime * 0.7)),
            y: size.height * (0.4 + 0.15 * cos(slowTime * 0.5))
        )
        let blob1Radius = min(size.width, size.height) * 0.5 * breathe
        drawBlob(
            context: context,
            center: blob1Center,
            radius: blob1Radius,
            color: primaryColor,
            opacity: 0.6
        )

        // Blob 2 - Secondary color, medium, different phase
        let blob2Center = CGPoint(
            x: size.width * (0.7 + 0.15 * cos(slowTime * 0.6 + 2)),
            y: size.height * (0.6 + 0.2 * sin(slowTime * 0.4 + 1))
        )
        let blob2Radius = min(size.width, size.height) * 0.45 * breathe
        drawBlob(
            context: context,
            center: blob2Center,
            radius: blob2Radius,
            color: secondaryColor,
            opacity: 0.5
        )

        // Blob 3 - Primary darker, smaller accent
        let blob3Center = CGPoint(
            x: size.width * (0.5 + 0.25 * sin(slowTime * 0.8 + 3)),
            y: size.height * (0.3 + 0.1 * cos(slowTime * 0.9 + 2))
        )
        let blob3Radius = min(size.width, size.height) * 0.3 * breathe
        drawBlob(
            context: context,
            center: blob3Center,
            radius: blob3Radius,
            color: primaryColor.opacity(0.8),
            opacity: 0.4
        )

        // Blob 4 - Bottom accent
        let blob4Center = CGPoint(
            x: size.width * (0.4 + 0.2 * cos(slowTime * 0.5 + 4)),
            y: size.height * (0.8 + 0.1 * sin(slowTime * 0.6))
        )
        let blob4Radius = min(size.width, size.height) * 0.35 * breathe
        drawBlob(
            context: context,
            center: blob4Center,
            radius: blob4Radius,
            color: secondaryColor.opacity(0.7),
            opacity: 0.35
        )
    }

    private func drawBlob(
        context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        color: Color,
        opacity: Double
    ) {
        let gradient = Gradient(colors: [
            color.opacity(opacity),
            color.opacity(opacity * 0.5),
            color.opacity(0)
        ])

        context.fill(
            Circle().path(in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )),
            with: .radialGradient(
                gradient,
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
    }
}

/// MeshGradient version for macOS 15+ with smoother interpolation
@available(macOS 15.0, *)
struct EmotionMeshGradientBackground: View {
    let primaryColor: Color
    let secondaryColor: Color
    let backgroundColor: Color
    var isPlaying: Bool = false

    @State private var phase: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/60, paused: false)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate * 0.1

            MeshGradient(
                width: 3,
                height: 3,
                points: meshPoints(time: time),
                colors: meshColors
            )
        }
        .blur(radius: 40)
    }

    private func meshPoints(time: TimeInterval) -> [SIMD2<Float>] {
        // 3x3 grid of control points with subtle movement
        let drift: Float = 0.08

        return [
            // Top row
            SIMD2(0.0, 0.0),
            SIMD2(0.5 + drift * Float(sin(time * 1.1)), 0.0),
            SIMD2(1.0, 0.0),

            // Middle row
            SIMD2(0.0, 0.5 + drift * Float(cos(time * 0.9))),
            SIMD2(0.5 + drift * Float(sin(time * 1.3)), 0.5 + drift * Float(cos(time * 1.2))),
            SIMD2(1.0, 0.5 + drift * Float(sin(time * 0.8))),

            // Bottom row
            SIMD2(0.0, 1.0),
            SIMD2(0.5 + drift * Float(cos(time * 1.0)), 1.0),
            SIMD2(1.0, 1.0)
        ]
    }

    private var meshColors: [Color] {
        [
            backgroundColor,
            primaryColor.opacity(0.7),
            backgroundColor,

            secondaryColor.opacity(0.6),
            primaryColor.opacity(0.8),
            secondaryColor.opacity(0.6),

            backgroundColor,
            primaryColor.opacity(0.5),
            backgroundColor
        ]
    }
}

#Preview("Emotion Gradient") {
    EmotionGradientBackground(
        primaryColor: .purple,
        secondaryColor: .blue,
        backgroundColor: .black,
        isPlaying: true
    )
    .ignoresSafeArea()
}

@available(macOS 15.0, *)
#Preview("Emotion Mesh Gradient") {
    EmotionMeshGradientBackground(
        primaryColor: .purple,
        secondaryColor: .blue,
        backgroundColor: .black,
        isPlaying: true
    )
    .ignoresSafeArea()
}
