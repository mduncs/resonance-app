import SwiftUI

enum DesignTokens {
    // MARK: - Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let section: CGFloat = 32
    }

    // MARK: - Corner Radius
    enum CornerRadius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
    }

    // MARK: - Shadows
    enum Shadow {
        static let cardLight = (color: Color.black.opacity(0.08), radius: CGFloat(8), x: CGFloat(0), y: CGFloat(4))
        static let cardInner = (color: Color.black.opacity(0.04), radius: CGFloat(2), x: CGFloat(0), y: CGFloat(1))
        static let cardHover = (color: Color.black.opacity(0.18), radius: CGFloat(12), x: CGFloat(0), y: CGFloat(6))
    }

    // MARK: - Placeholder Colors
    enum Placeholder {
        static let light = Color(white: 0.9)
        static let dark = Color(white: 0.23)

        /// Neutral gray that works in both light and dark modes
        static var adaptive: Color {
            Color(nsColor: NSColor.unemphasizedSelectedContentBackgroundColor)
        }

        /// Icon color for placeholders - subtle gray
        static var iconColor: Color {
            Color(nsColor: NSColor.tertiaryLabelColor)
        }
    }

    // MARK: - Album Art Sizes
    enum ArtworkSize {
        static let nowPlayingBar: CGFloat = 52
        static let listRow: CGFloat = 40
        static let cardSmall: CGFloat = 100
        static let cardLarge: CGFloat = 140
        static let detail: CGFloat = 200
        static let immersive: CGFloat = 400
    }

    // MARK: - Animation
    enum Animation {
        static let quick = SwiftUI.Animation.easeOut(duration: 0.15)
        static let standard = SwiftUI.Animation.easeInOut(duration: 0.25)
        static let slow = SwiftUI.Animation.easeInOut(duration: 0.5)
    }
}
