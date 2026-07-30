import SwiftUI

/// Shimmer effect for loading states and visual polish

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    var duration: Double = 1.5
    var bounce: Bool = false

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let gradientWidth = width * 0.5

                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.3),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: gradientWidth)
                    .offset(x: phase * (width + gradientWidth) - gradientWidth)
                }
            )
            .clipped()
            .onAppear {
                let animation: Animation = bounce
                    ? .easeInOut(duration: duration).repeatForever(autoreverses: true)
                    : .linear(duration: duration).repeatForever(autoreverses: false)

                withAnimation(animation) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer(duration: Double = 1.5, bounce: Bool = false) -> some View {
        modifier(ShimmerModifier(duration: duration, bounce: bounce))
    }
}

// MARK: - Pulse Animation

struct PulseModifier: ViewModifier {
    @State private var isPulsing = false
    var minScale: CGFloat = 0.95
    var maxScale: CGFloat = 1.05
    var duration: Double = 1.0

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? maxScale : minScale)
            .animation(
                .easeInOut(duration: duration).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
            }
    }
}

extension View {
    func pulse(min: CGFloat = 0.95, max: CGFloat = 1.05, duration: Double = 1.0) -> some View {
        modifier(PulseModifier(minScale: min, maxScale: max, duration: duration))
    }
}

// MARK: - Breathing Opacity

struct BreathingModifier: ViewModifier {
    @State private var isBreathing = false
    var minOpacity: Double = 0.3
    var maxOpacity: Double = 1.0
    var duration: Double = 2.0

    func body(content: Content) -> some View {
        content
            .opacity(isBreathing ? maxOpacity : minOpacity)
            .animation(
                .easeInOut(duration: duration).repeatForever(autoreverses: true),
                value: isBreathing
            )
            .onAppear {
                isBreathing = true
            }
    }
}

extension View {
    func breathing(min: Double = 0.3, max: Double = 1.0, duration: Double = 2.0) -> some View {
        modifier(BreathingModifier(minOpacity: min, maxOpacity: max, duration: duration))
    }
}

// MARK: - Waveform Animation (for playing indicator)

struct WaveformView: View {
    var barCount: Int = 3
    var isAnimating: Bool = true

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                WaveformBar(
                    isAnimating: isAnimating,
                    delay: Double(index) * 0.15
                )
            }
        }
    }
}

struct WaveformBar: View {
    var isAnimating: Bool
    var delay: Double

    @State private var height: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.primary)
            .frame(width: 3, height: height)
            .animation(
                isAnimating
                    ? .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(delay)
                    : .default,
                value: height
            )
            .onAppear {
                if isAnimating {
                    height = CGFloat.random(in: 8...16)
                }
            }
            .onChange(of: isAnimating) { _, newValue in
                height = newValue ? CGFloat.random(in: 8...16) : 4
            }
    }
}

// MARK: - Spinning Vinyl Animation

struct SpinningVinylView: View {
    var image: NSImage?
    var isSpinning: Bool = true
    var size: CGFloat = 200

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            // Vinyl base
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.black, .gray.opacity(0.8), .black],
                        center: .center,
                        startRadius: size * 0.1,
                        endRadius: size * 0.5
                    )
                )
                .frame(width: size, height: size)

            // Grooves
            ForEach(0..<8, id: \.self) { index in
                Circle()
                    .stroke(.white.opacity(0.05), lineWidth: 1)
                    .frame(
                        width: size * (0.3 + CGFloat(index) * 0.08),
                        height: size * (0.3 + CGFloat(index) * 0.08)
                    )
            }

            // Center label (album art)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size * 0.4, height: size * 0.4)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: size * 0.4, height: size * 0.4)
            }

            // Center hole
            Circle()
                .fill(.black)
                .frame(width: size * 0.05, height: size * 0.05)
        }
        .rotationEffect(.degrees(rotation))
        .onAppear {
            guard isSpinning else { return }
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
        .onChange(of: isSpinning) { _, spinning in
            if spinning {
                withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                    rotation += 360
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 30) {
        Text("Shimmer")
            .font(.title)
            .padding()
            .background(.quaternary)
            .shimmer()
            .cornerRadius(8)

        HStack(spacing: 20) {
            WaveformView(isAnimating: true)
            WaveformView(isAnimating: false)
        }

        Text("Pulse")
            .font(.title)
            .pulse()

        Text("Breathing")
            .font(.title)
            .breathing()

        SpinningVinylView(isSpinning: true, size: 100)
    }
    .padding()
    .frame(width: 300, height: 500)
}
