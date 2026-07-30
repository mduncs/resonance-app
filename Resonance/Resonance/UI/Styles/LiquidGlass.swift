import SwiftUI
import AppKit

/// LiquidGlass provides Apple-style vibrancy and blur effects
/// inspired by macOS's visual design language

// MARK: - Glass Materials

struct GlassMaterial: ViewModifier {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State

    func body(content: Content) -> some View {
        content
            .background(
                VisualEffectView(
                    material: material,
                    blendingMode: blendingMode,
                    state: state
                )
            )
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - View Extensions

extension View {
    /// Apply a glass-like frosted blur effect
    func glassBackground(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) -> some View {
        modifier(GlassMaterial(
            material: material,
            blendingMode: blendingMode,
            state: .active
        ))
    }

    /// Sidebar-style blur
    func sidebarGlass() -> some View {
        glassBackground(material: .sidebar, blendingMode: .behindWindow)
    }

    /// Content background blur (lighter)
    func contentGlass() -> some View {
        glassBackground(material: .contentBackground, blendingMode: .behindWindow)
    }

    /// Popover-style blur
    func popoverGlass() -> some View {
        glassBackground(material: .popover, blendingMode: .behindWindow)
    }

    /// Full window blur (for immersive views)
    func fullScreenGlass() -> some View {
        glassBackground(material: .fullScreenUI, blendingMode: .behindWindow)
    }

    /// Menu-style blur
    func menuGlass() -> some View {
        glassBackground(material: .menu, blendingMode: .behindWindow)
    }

    /// Ultra dark glass for player bar
    func playerBarGlass() -> some View {
        glassBackground(material: .titlebar, blendingMode: .withinWindow)
    }
}

// MARK: - Glass Card

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - Liquid Glass Button Style

struct LiquidGlassButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(.white.opacity(0.2), lineWidth: 0.5)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == LiquidGlassButtonStyle {
    static var liquidGlass: LiquidGlassButtonStyle { LiquidGlassButtonStyle() }
}

// MARK: - Glow Effect

struct GlowModifier: ViewModifier {
    var color: Color
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.5), radius: radius / 2)
            .shadow(color: color.opacity(0.3), radius: radius)
            .shadow(color: color.opacity(0.1), radius: radius * 2)
    }
}

extension View {
    func glow(color: Color, radius: CGFloat = 10) -> some View {
        modifier(GlowModifier(color: color, radius: radius))
    }
}

// MARK: - Simple Animated Gradient Background

struct SimpleAnimatedGradientBackground: View {
    var colors: [Color]
    @State private var animateGradient = false

    var body: some View {
        LinearGradient(
            colors: colors,
            startPoint: animateGradient ? .topLeading : .bottomLeading,
            endPoint: animateGradient ? .bottomTrailing : .topTrailing
        )
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 5.0).repeatForever(autoreverses: true)) {
                animateGradient = true
            }
        }
    }
}

// MARK: - Mesh Gradient (iOS 18+ style)

struct MeshGradientBackground: View {
    var primaryColor: Color
    var secondaryColor: Color

    var body: some View {
        ZStack {
            // Background base
            primaryColor.opacity(0.3)

            // Animated blobs
            GeometryReader { geometry in
                let size = geometry.size

                Circle()
                    .fill(primaryColor.opacity(0.5))
                    .frame(width: size.width * 0.8)
                    .blur(radius: 80)
                    .offset(x: -size.width * 0.2, y: -size.height * 0.1)

                Circle()
                    .fill(secondaryColor.opacity(0.4))
                    .frame(width: size.width * 0.6)
                    .blur(radius: 60)
                    .offset(x: size.width * 0.3, y: size.height * 0.3)

                Circle()
                    .fill(primaryColor.opacity(0.3))
                    .frame(width: size.width * 0.5)
                    .blur(radius: 50)
                    .offset(x: size.width * 0.1, y: size.height * 0.6)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        Text("Glass Background")
            .padding()
            .glassBackground()
            .cornerRadius(10)

        GlassCard {
            Text("Glass Card")
                .padding()
        }

        Button("Liquid Glass Button") {}
            .buttonStyle(.liquidGlass)

        Text("Glow Effect")
            .font(.title)
            .foregroundStyle(.white)
            .padding()
            .glow(color: .blue, radius: 20)
    }
    .padding()
    .frame(width: 300, height: 400)
    .background(
        MeshGradientBackground(
            primaryColor: .purple,
            secondaryColor: .blue
        )
    )
}
