import Foundation

enum AudioFormat: String, CaseIterable {
    case mp3
    case aac
    case m4a
    case flac
    case alac
    case ogg
    case opus
    case wav
    case aiff
    case aif

    var isSupported: Bool {
        switch self {
        case .mp3, .aac, .m4a, .flac, .alac, .ogg, .opus, .wav, .aiff, .aif:
            return true
        }
    }

    var mimeType: String {
        switch self {
        case .mp3: return "audio/mpeg"
        case .aac, .m4a, .alac: return "audio/mp4"
        case .flac: return "audio/flac"
        case .ogg: return "audio/ogg"
        case .opus: return "audio/opus"
        case .wav: return "audio/wav"
        case .aiff, .aif: return "audio/aiff"
        }
    }

    static func fromSuffix(_ suffix: String) -> AudioFormat? {
        AudioFormat(rawValue: suffix.lowercased())
    }

    static func fromMimeType(_ mimeType: String) -> AudioFormat? {
        switch mimeType {
        case "audio/mpeg": return .mp3
        case "audio/mp4", "audio/x-m4a": return .m4a
        case "audio/flac": return .flac
        case "audio/ogg", "audio/vorbis": return .ogg
        case "audio/opus": return .opus
        case "audio/wav", "audio/wave": return .wav
        case "audio/aiff": return .aiff
        default: return nil
        }
    }

    static let unsupportedFormats = ["wma", "ape", "wv", "wavpack"]

    static func isSupported(suffix: String) -> Bool {
        guard !unsupportedFormats.contains(suffix.lowercased()) else { return false }
        return fromSuffix(suffix)?.isSupported ?? false
    }

    static func isSupported(mimeType: String) -> Bool {
        fromMimeType(mimeType)?.isSupported ?? false
    }
}

enum TranscodingQuality: String, Codable, CaseIterable, Sendable {
    case original = "Original"
    case high = "High (320 kbps)"
    case medium = "Medium (192 kbps)"
    case low = "Low (128 kbps)"

    var maxBitRate: Int? {
        switch self {
        case .original: return nil
        case .high: return 320
        case .medium: return 192
        case .low: return 128
        }
    }

    var format: String? {
        switch self {
        case .original: return nil
        case .high, .medium, .low: return "mp3"
        }
    }
}
