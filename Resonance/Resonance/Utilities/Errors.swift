import Foundation

enum ResonanceError: Error, LocalizedError, Sendable {
    // Configuration
    case notConfigured
    case invalidURL
    case publicDemoRequiresLocalServer

    // Network
    case networkUnavailable
    case serverUnreachable(URL)
    case authenticationFailed(reason: String)
    case invalidResponse(statusCode: Int)
    case decodingFailed(type: String, underlying: Error)

    // Audio
    case audioEngineFailure(underlying: Error)
    case unsupportedFormat(String)
    case streamingFailed(songId: String, underlying: Error)

    // Cache
    case cacheFull(required: Int64, available: Int64)
    case cacheCorrupted(path: String)

    // Keychain
    case keychainError(OSStatus)

    // Subsonic API
    case subsonicError(code: Int, message: String)
    // Known codes:
    // 0  = generic
    // 10 = missing parameter
    // 20 = version mismatch
    // 30 = deprecated
    // 40 = wrong credentials
    // 50 = unauthorized
    // 60 = trial expired
    // 70 = not found

    // Last.fm
    case lastFMNotAuthenticated
    case lastFMScrobbleFailed

    // Generic
    case unknown(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No server configured"
        case .invalidURL:
            return "Invalid server URL"
        case .publicDemoRequiresLocalServer:
            return "Resonance Public only connects to its local Forty demo library"
        case .networkUnavailable:
            return "Network unavailable"
        case .serverUnreachable(let url):
            return "Cannot reach server at \(url.host ?? "unknown")"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .invalidResponse(let statusCode):
            return "Server returned error \(statusCode)"
        case .decodingFailed(let type, _):
            return "Failed to parse \(type) response"
        case .audioEngineFailure:
            return "Audio playback error"
        case .unsupportedFormat(let format):
            return "Unsupported audio format: \(format)"
        case .streamingFailed(let songId, _):
            return "Failed to stream song \(songId)"
        case .cacheFull:
            return "Cache storage full"
        case .cacheCorrupted:
            return "Cache data corrupted"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .subsonicError(_, let message):
            return message
        case .lastFMNotAuthenticated:
            return "Not logged in to Last.fm"
        case .lastFMScrobbleFailed:
            return "Failed to scrobble to Last.fm"
        case .unknown(let error):
            return error.localizedDescription
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notConfigured:
            return "Add a server in Settings"
        case .invalidURL:
            return "Check the server URL format"
        case .publicDemoRequiresLocalServer:
            return "Start the bundled local demo service on port 4534"
        case .networkUnavailable:
            return "Check your internet connection"
        case .serverUnreachable:
            return "Verify the server is running and accessible"
        case .authenticationFailed:
            return "Check your username and password"
        case .invalidResponse(let statusCode) where statusCode >= 500:
            return "The server is experiencing issues. Try again later."
        case .invalidResponse:
            return "Try again or contact support"
        case .decodingFailed:
            return "The server response was unexpected. Try updating the app."
        case .audioEngineFailure:
            return "Try restarting playback"
        case .unsupportedFormat:
            return "This audio format is not supported on macOS"
        case .streamingFailed:
            return "Check your connection and try again"
        case .cacheFull:
            return "Clear some cached data in Settings"
        case .cacheCorrupted:
            return "Clear the cache in Settings"
        case .keychainError:
            return "Try removing and re-adding the server"
        case .subsonicError(let code, _):
            switch code {
            case 40: return "Check your username and password"
            case 50: return "You don't have permission for this action"
            case 70: return "The requested item was not found"
            default: return nil
            }
        case .lastFMNotAuthenticated:
            return "Connect your Last.fm account in Settings"
        case .lastFMScrobbleFailed:
            return "Check your Last.fm connection"
        case .unknown, .networkError:
            return "Try again"
        }
    }

    var isRecoverable: Bool {
        switch self {
        case .networkUnavailable, .serverUnreachable, .invalidResponse, .streamingFailed:
            return true
        default:
            return false
        }
    }
}
