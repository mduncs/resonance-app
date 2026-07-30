import SwiftUI

struct RadioView: View {
    @Environment(AppState.self) private var appState

    @State private var stations: [InternetRadioStation] = []
    @State private var viewState: ViewState = .loading
    @State private var playingStationID: String?

    private enum ViewState {
        case loading
        case empty
        case loaded
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Group {
                switch viewState {
                case .loading:
                    InlineLoadingStatusView(title: "Loading radio stations...")
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                case .empty:
                    CompactStatusView(
                        title: "No Radio Stations",
                        systemImage: "antenna.radiowaves.left.and.right",
                        message: "This Navidrome server does not expose any internet radio stations."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .error(let message):
                    CompactStatusView(
                        title: "Couldn’t Load Radio",
                        systemImage: "exclamationmark.triangle",
                        message: message,
                        actionTitle: "Retry",
                        actionSystemImage: "arrow.clockwise",
                        action: {
                            Task { await loadStations() }
                        }
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .loaded:
                    List(stations) { station in
                        RadioStationRow(
                            station: station,
                            isPlaying: isCurrentStation(station),
                            isWorking: playingStationID == station.id,
                            playAction: { play(station) }
                        )
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 300)
                }
            }
        }
        .navigationTitle("")
        .task {
            await loadStations()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Radio")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                if !stations.isEmpty {
                    Text("\(stations.count) station\(stations.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task { await loadStations() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var isLoading: Bool {
        if case .loading = viewState {
            return true
        }
        return false
    }

    private func loadStations() async {
        viewState = .loading

        do {
            let fetchedStations = try await appState.networkActor.fetchInternetRadioStations()
            stations = fetchedStations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            viewState = stations.isEmpty ? .empty : .loaded
        } catch {
            stations = []
            viewState = .error(errorDetail(for: error))
        }
    }

    private func play(_ station: InternetRadioStation) {
        playingStationID = station.id

        Task {
            do {
                try await appState.playbackManager.play(station: station)
            } catch {
                await MainActor.run {
                    appState.showFeedback(
                        message: "Station playback unavailable",
                        detail: errorDetail(for: error),
                        style: .error,
                        systemImage: "xmark.octagon.fill"
                    )
                }
            }

            await MainActor.run {
                if playingStationID == station.id {
                    playingStationID = nil
                }
            }
        }
    }

    private func isCurrentStation(_ station: InternetRadioStation) -> Bool {
        appState.nowPlaying?.id == "radio:\(station.id)" && appState.playbackState == .playing
    }

    private func errorDetail(for error: Error) -> String {
        if let resonanceError = error as? ResonanceError {
            let parts = [resonanceError.errorDescription, resonanceError.recoverySuggestion]
                .compactMap { $0 }
            if !parts.isEmpty {
                return parts.joined(separator: " ")
            }
        }

        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        return error.localizedDescription
    }
}

private struct RadioStationRow: View {
    let station: InternetRadioStation
    let isPlaying: Bool
    let isWorking: Bool
    let playAction: () -> Void

    private var hostLabel: String {
        station.homePageUrl?.host ?? station.streamUrl.host ?? station.streamUrl.absoluteString
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                    .frame(width: 52, height: 52)

                Image(systemName: isPlaying ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(station.name)
                        .font(.headline)
                        .lineLimit(1)

                    if isPlaying {
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text(hostLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(station.streamUrl.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer()

            if let homePageUrl = station.homePageUrl {
                Link(destination: homePageUrl) {
                    Label("Website", systemImage: "safari")
                }
                .buttonStyle(.link)
            }

            Button(action: playAction) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 48)
                } else {
                    Label(isPlaying ? "Playing" : "Play", systemImage: isPlaying ? "speaker.wave.2.fill" : "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    NavigationStack {
        RadioView()
            .environment(AppState())
    }
}
