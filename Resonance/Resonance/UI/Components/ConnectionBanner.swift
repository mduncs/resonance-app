import SwiftUI

struct ConnectionBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.connectionStatus {
        case .connected:
            EmptyView()

        case .connecting:
            BannerView(
                icon: "arrow.triangle.2.circlepath",
                message: "Connecting to server...",
                style: .info
            )

        case .disconnected:
            BannerView(
                icon: "wifi.slash",
                message: "No connection to server",
                style: .warning
            ) {
                Button("Reconnect") {
                    Task {
                        await appState.connect()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case .offline:
            BannerView(
                icon: "icloud.slash",
                message: "Offline mode — playing cached music",
                style: .info
            )

        case .error(let error):
            BannerView(
                icon: "exclamationmark.triangle",
                message: error.localizedDescription,
                style: .error
            ) {
                Button("Retry") {
                    Task {
                        await appState.connect()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

struct BannerView<Actions: View>: View {
    let icon: String
    let message: String
    let style: BannerStyle
    @ViewBuilder let actions: () -> Actions

    enum BannerStyle {
        case info
        case warning
        case error

        var backgroundColor: Color {
            switch self {
            case .info: return .blue.opacity(0.1)
            case .warning: return .orange.opacity(0.1)
            case .error: return .red.opacity(0.1)
            }
        }

        var iconColor: Color {
            switch self {
            case .info: return .blue
            case .warning: return .orange
            case .error: return .red
            }
        }
    }

    init(
        icon: String,
        message: String,
        style: BannerStyle,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.icon = icon
        self.message = message
        self.style = style
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(style.iconColor)

            Text(message)
                .font(.subheadline)

            Spacer()

            actions()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(style.backgroundColor)
    }
}

struct NetworkStatusIndicator: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch appState.connectionStatus {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        case .offline: return .gray
        case .error: return .red
        }
    }

    private var statusText: String {
        switch appState.connectionStatus {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Disconnected"
        case .offline: return "Offline"
        case .error: return "Error"
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        BannerView(
            icon: "wifi.slash",
            message: "No connection to server",
            style: .warning
        ) {
            Button("Reconnect") {}
                .buttonStyle(.bordered)
                .controlSize(.small)
        }

        BannerView(
            icon: "icloud.slash",
            message: "Offline mode",
            style: .info
        )

        BannerView(
            icon: "exclamationmark.triangle",
            message: "Connection failed",
            style: .error
        ) {
            Button("Retry") {}
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
    .frame(width: 400)
}
