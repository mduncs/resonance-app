import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var currentPage = 0
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var connectionError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    switch currentPage {
                    case 0:
                        WelcomePage()
                    case 1:
                        ServerSetupPage(
                            serverURL: $serverURL,
                            username: $username,
                            password: $password,
                            isConnecting: $isConnecting,
                            connectionError: $connectionError,
                            onConnect: connect
                        )
                    case 2:
                        FinishPage(onFinish: finish)
                    default:
                        WelcomePage()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 430, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Page indicator and navigation - fixed height to prevent layout shift
            ZStack {
                // Page dots - always centered
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { page in
                        Circle()
                            .fill(page == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }

                // Buttons on edges
                HStack {
                    // Back button
                    if currentPage > 0 {
                        Button {
                            withAnimation {
                                currentPage -= 1
                            }
                        } label: {
                            Text("Back")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    Spacer()

                    // Next/Connect button
                    if currentPage < 2 {
                        HStack(spacing: 10) {
                            if currentPage == 1 {
                                Button {
                                    skipServerSetup()
                                } label: {
                                    Text("Add Server Later")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .disabled(isConnecting)
                            }

                            Button {
                                if currentPage == 1 {
                                    connect()
                                } else {
                                    withAnimation {
                                        currentPage += 1
                                    }
                                }
                            } label: {
                                if currentPage == 1 && isConnecting {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Text(currentPage == 1 ? "Connect" : "Next")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(currentPage == 1 && (serverURL.isEmpty || username.isEmpty || password.isEmpty || isConnecting))
                        }
                    }
                }
            }
            .frame(height: 44)
            .padding(.horizontal)
            .padding(.vertical, 20)
        }
        .padding(.vertical, 20)
        .frame(minWidth: 560, idealWidth: 600, maxWidth: 680, minHeight: 550, idealHeight: 580)
        .tint(Color.accentColor)
    }

    private func connect() {
        isConnecting = true
        connectionError = nil

        guard let url = URL(string: serverURL) else {
            connectionError = "Invalid URL format"
            isConnecting = false
            return
        }

        Task {
            do {
                // Create server config
                let server = Server(
                    name: "Navidrome",
                    url: url,
                    username: username
                )

                // Configure network actor
                await appState.networkActor.configure(server: server, password: password)

                // Test connection
                let response = try await appState.networkActor.ping()

                // Update server with actual info from response
                let updatedServer = Server(
                    id: server.id,
                    name: response.serverName,
                    url: url,
                    username: username
                )

                try await MainActor.run {
                    // Save server and password for persistence
                    try appState.saveServer(updatedServer, password: password)
                    appState.connectionStatus = .connected
                    isConnecting = false

                    withAnimation {
                        currentPage = 2
                    }
                }
            } catch {
                await MainActor.run {
                    connectionError = error.localizedDescription
                    isConnecting = false
                }
            }
        }
    }

    private func finish() {
        appState.isOnboardingComplete = true
    }

    private func skipServerSetup() {
        appState.selectedSidebarItem = .home
        appState.isOnboardingComplete = true
    }
}

// MARK: - Welcome Page

struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "music.note.house.fill")
                .font(.system(size: 80))
                .foregroundStyle(Color.accentColor)

            Text("Welcome to Resonance")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("A beautiful music player for your Navidrome server")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            VStack(spacing: 12) {
                FeatureRow(icon: "waveform", title: "High Quality Audio", description: "Gapless playback with optional ReplayGain normalization")
                FeatureRow(icon: "arrow.down.circle", title: "Offline Support", description: "Download your favorites for offline listening")
                FeatureRow(icon: "text.quote", title: "Lyrics", description: "Synced lyrics from your library")
            }
            .padding()

            Spacer()
        }
        .padding()
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

// MARK: - Server Setup Page

struct ServerSetupPage: View {
    @Binding var serverURL: String
    @Binding var username: String
    @Binding var password: String
    @Binding var isConnecting: Bool
    @Binding var connectionError: String?
    var onConnect: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "server.rack")
                .font(.system(size: 80))
                .foregroundStyle(Color.accentColor)

            Text("Connect to Your Server")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Enter your Navidrome server details")
                .font(.title3)
                .foregroundStyle(.secondary)

            Spacer()

            VStack(spacing: 16) {
                TextField("Server URL (e.g., https://music.example.com)", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)

                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onSubmit {
                        if !serverURL.isEmpty && !username.isEmpty && !password.isEmpty {
                            onConnect()
                        }
                    }

                if let error = connectionError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)

                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .padding(.vertical, 8)
                }

                Text("Resonance works with Navidrome and other Subsonic-compatible servers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            .frame(maxWidth: 350)

            Spacer()
        }
        .padding()
    }
}

// MARK: - Finish Page

struct FinishPage: View {
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Your server is connected and ready to go")
                .font(.title3)
                .foregroundStyle(.secondary)

            Spacer()

            VStack(spacing: 12) {
                Text("Quick Tips")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    TipRow(shortcut: "Space", action: "Play/Pause")
                    TipRow(shortcut: "⌘→", action: "Next track")
                    TipRow(shortcut: "⌘←", action: "Previous track")
                    TipRow(shortcut: "⌘L", action: "Show lyrics")
                }
            }
            .padding()
            .background(.quaternary)
            .cornerRadius(12)

            Spacer()

            Button {
                onFinish()
            } label: {
                Text("Start Listening")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: 200)
        }
        .padding()
    }
}

struct TipRow: View {
    let shortcut: String
    let action: String

    var body: some View {
        HStack {
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.tertiary)
                .cornerRadius(4)

            Text(action)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    OnboardingView()
        .environment(AppState())
}
