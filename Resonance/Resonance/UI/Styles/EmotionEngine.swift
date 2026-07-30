import SwiftUI
import AppKit

/// EmotionEngine extracts dominant colors from album artwork
/// to create dynamic, mood-based color schemes
@Observable
final class EmotionEngine: @unchecked Sendable {
    // Current extracted colors
    var primaryColor: Color = .accentColor
    var secondaryColor: Color = .secondary
    var backgroundColor: Color = .clear
    var textColor: Color = .primary

    // Color vibrancy
    var isVibrant: Bool = true

    // Current artwork being analyzed
    private var currentArtworkId: String?

    /// Update colors based on album artwork
    func updateColors(from artwork: NSImage?) {
        guard let artwork else {
            resetToDefaults()
            return
        }

        Task {
            let colors = await extractColors(from: artwork)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.5)) {
                    self.primaryColor = colors.primary
                    self.secondaryColor = colors.secondary
                    self.backgroundColor = colors.background
                    self.textColor = colors.text
                }
            }
        }
    }

    func updateColors(fromArtworkId artworkId: String?, using appState: AppState) {
        guard let artworkId, artworkId != currentArtworkId else { return }
        currentArtworkId = artworkId

        Task {
            // Fast path: check in-memory cache first
            if let image = await appState.cacheActor.getArtworkImage(for: artworkId, size: .small) {
                updateColors(from: image)
                return
            }

            // Fetch from network
            do {
                let data = try await appState.networkActor.fetchCoverArt(id: artworkId, size: 100)
                if let image = NSImage(data: data) {
                    updateColors(from: image)
                }
            } catch {
                resetToDefaults()
            }
        }
    }

    func resetToDefaults() {
        withAnimation(.easeInOut(duration: 0.3)) {
            primaryColor = .accentColor
            secondaryColor = .secondary
            backgroundColor = .clear
            textColor = .primary
        }
        currentArtworkId = nil
    }

    // MARK: - Color Extraction

    private struct ExtractedColors {
        let primary: Color
        let secondary: Color
        let background: Color
        let text: Color
    }

    private func extractColors(from image: NSImage) async -> ExtractedColors {
        // Resize for faster processing
        let targetSize = CGSize(width: 50, height: 50)
        guard let resized = resize(image: image, to: targetSize),
              let cgImage = resized.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return defaultColors
        }

        // Get pixel data
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8

        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return defaultColors
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sample colors using k-means-like clustering
        let colors = sampleColors(from: pixelData, width: width, height: height)
        let sorted = colors.sorted { $0.saturation > $1.saturation }

        guard sorted.count >= 2 else {
            return defaultColors
        }

        let primary = sorted[0]
        let secondary = sorted.count > 1 ? sorted[1] : sorted[0].adjustedBrightness(by: -0.2)

        // Determine text color based on background luminance
        let background = primary.adjustedBrightness(by: -0.4)
        let textColor = background.luminance > 0.5 ? Color.black : Color.white

        return ExtractedColors(
            primary: Color(nsColor: primary),
            secondary: Color(nsColor: secondary),
            background: Color(nsColor: background),
            text: textColor
        )
    }

    private func resize(image: NSImage, to size: CGSize) -> NSImage? {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }

    private func sampleColors(from pixelData: [UInt8], width: Int, height: Int) -> [NSColor] {
        var colorBuckets: [String: (r: Int, g: Int, b: Int, count: Int)] = [:]

        let step = 4 // Sample every 4th pixel for speed
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = (y * width + x) * 4
                let r = Int(pixelData[offset])
                let g = Int(pixelData[offset + 1])
                let b = Int(pixelData[offset + 2])

                // Quantize to reduce unique colors
                let qr = (r / 32) * 32
                let qg = (g / 32) * 32
                let qb = (b / 32) * 32
                let key = "\(qr)-\(qg)-\(qb)"

                if var bucket = colorBuckets[key] {
                    bucket.r += r
                    bucket.g += g
                    bucket.b += b
                    bucket.count += 1
                    colorBuckets[key] = bucket
                } else {
                    colorBuckets[key] = (r, g, b, 1)
                }
            }
        }

        // Get top colors by frequency
        let sorted = colorBuckets.values
            .sorted { $0.count > $1.count }
            .prefix(5)
            .map { bucket -> NSColor in
                NSColor(
                    red: CGFloat(bucket.r / bucket.count) / 255,
                    green: CGFloat(bucket.g / bucket.count) / 255,
                    blue: CGFloat(bucket.b / bucket.count) / 255,
                    alpha: 1.0
                )
            }

        return Array(sorted)
    }

    private var defaultColors: ExtractedColors {
        ExtractedColors(
            primary: .accentColor,
            secondary: .secondary,
            background: .clear,
            text: .primary
        )
    }
}

// MARK: - NSColor Extensions

extension NSColor {
    var saturation: CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return s
    }

    var luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    func adjustedBrightness(by amount: CGFloat) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(
            hue: h,
            saturation: s,
            brightness: max(0, min(1, b + amount)),
            alpha: a
        )
    }
}

// MARK: - Environment

private struct EmotionEngineKey: EnvironmentKey {
    static let defaultValue = EmotionEngine()
}

extension EnvironmentValues {
    var emotionEngine: EmotionEngine {
        get { self[EmotionEngineKey.self] }
        set { self[EmotionEngineKey.self] = newValue }
    }
}
