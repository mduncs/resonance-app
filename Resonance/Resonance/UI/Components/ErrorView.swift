import SwiftUI

struct ErrorView: View {
    let error: ResonanceError
    var retryAction: (() async -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(error.errorTitle, systemImage: error.systemImage)
        } description: {
            Text(error.errorDescription ?? "An unknown error occurred")
        } actions: {
            if let retryAction {
                Button("Retry") {
                    Task {
                        await retryAction()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            if let recoverySuggestion = error.recoverySuggestion {
                Text(recoverySuggestion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }
}

struct ErrorBanner: View {
    let error: ResonanceError
    var dismissAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: error.systemImage)
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text(error.errorTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                if let description = error.errorDescription {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let dismissAction {
                Button {
                    dismissAction()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(.red.opacity(0.1))
        .cornerRadius(8)
    }
}

struct CompactStatusView: View {
    let title: String
    let systemImage: String
    let message: String?
    var actionTitle: String?
    var actionSystemImage: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)

                    if let message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let actionTitle, let action {
                    Button(action: action) {
                        if let actionSystemImage {
                            Label(actionTitle, systemImage: actionSystemImage)
                        } else {
                            Text(actionTitle)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
    }
}

struct InlineLoadingStatusView: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct FeedbackToastView: View {
    let message: String
    let detail: String?
    let style: FeedbackStyle
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?
    var dismissAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(style.tintColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.callout)
                    .fontWeight(.medium)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            if let actionTitle, let action {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let dismissAction {
                Button {
                    dismissAction()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(style.tintColor.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }
}

extension FeedbackStyle {
    var tintColor: Color {
        switch self {
        case .success:
            return .green
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

// MARK: - Error Extensions

extension ResonanceError {
    var errorTitle: String {
        switch self {
        case .notConfigured:
            return "Not Configured"
        case .invalidURL:
            return "Invalid URL"
        case .publicDemoRequiresLocalServer:
            return "Local Demo Required"
        case .networkUnavailable:
            return "Network Unavailable"
        case .serverUnreachable:
            return "Server Unreachable"
        case .authenticationFailed:
            return "Authentication Failed"
        case .invalidResponse:
            return "Invalid Response"
        case .decodingFailed:
            return "Decoding Error"
        case .audioEngineFailure:
            return "Playback Failed"
        case .unsupportedFormat:
            return "Unsupported Format"
        case .streamingFailed:
            return "Streaming Failed"
        case .cacheFull:
            return "Storage Full"
        case .cacheCorrupted:
            return "Cache Corrupted"
        case .keychainError:
            return "Keychain Error"
        case .subsonicError:
            return "Server Error"
        case .lastFMNotAuthenticated:
            return "Last.fm Not Connected"
        case .lastFMScrobbleFailed:
            return "Scrobble Failed"
        case .unknown:
            return "Error"
        case .networkError:
            return "Network Error"
        }
    }

    var systemImage: String {
        switch self {
        case .notConfigured:
            return "server.rack"
        case .invalidURL:
            return "link.badge.plus"
        case .publicDemoRequiresLocalServer:
            return "music.note.house"
        case .networkUnavailable:
            return "wifi.slash"
        case .serverUnreachable:
            return "wifi.exclamationmark"
        case .authenticationFailed:
            return "key.slash"
        case .invalidResponse:
            return "exclamationmark.triangle"
        case .decodingFailed:
            return "doc.questionmark"
        case .audioEngineFailure:
            return "speaker.slash"
        case .unsupportedFormat:
            return "waveform.badge.exclamationmark"
        case .streamingFailed:
            return "arrow.down.circle.dotted"
        case .cacheFull:
            return "externaldrive.fill.badge.xmark"
        case .cacheCorrupted:
            return "externaldrive.badge.exclamationmark"
        case .keychainError:
            return "lock.trianglebadge.exclamationmark"
        case .subsonicError:
            return "exclamationmark.circle"
        case .lastFMNotAuthenticated:
            return "person.badge.key"
        case .lastFMScrobbleFailed:
            return "music.note.list"
        case .unknown:
            return "exclamationmark.triangle"
        case .networkError:
            return "wifi.exclamationmark"
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ErrorView(error: .serverUnreachable(URL(string: "https://music.example.com")!)) {
            // Retry
        }

        ErrorBanner(error: .networkUnavailable) {
            // Dismiss
        }
        .padding()
    }
}
