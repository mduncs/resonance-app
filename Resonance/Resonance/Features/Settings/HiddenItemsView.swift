import SwiftUI

struct HiddenItemsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var hiddenItems: [(itemId: String, itemType: String, name: String, subtitle: String, hiddenAt: Date)] = []
    @State private var filter: String = "all" // all, album, artist, song

    private var filteredItems: [(itemId: String, itemType: String, name: String, subtitle: String, hiddenAt: Date)] {
        if filter == "all" { return hiddenItems }
        return hiddenItems.filter { $0.itemType == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Hidden Items")
                    .font(.headline)
                Text("(\(hiddenItems.count))")
                    .foregroundStyle(.secondary)
                Spacer()

                Picker("Filter", selection: $filter) {
                    Text("All").tag("all")
                    Text("Albums").tag("album")
                    Text("Artists").tag("artist")
                    Text("Songs").tag("song")
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            if filteredItems.isEmpty {
                CompactStatusView(
                    title: "No Hidden Items",
                    systemImage: "eye",
                    message: "Items you hide from your library will appear here."
                )
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List {
                    ForEach(filteredItems, id: \.itemId) { item in
                        HStack {
                            Image(systemName: iconForType(item.itemType))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .lineLimit(1)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            Text(item.hiddenAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.tertiary)

                            Button("Unhide") {
                                unhide(item)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 260)
            }
        }
        .frame(minWidth: 500, minHeight: 300)
        .task {
            loadItems()
        }
    }

    private func iconForType(_ type: String) -> String {
        switch type {
        case "album": return "square.stack"
        case "artist": return "music.mic"
        case "song": return "music.note"
        default: return "questionmark"
        }
    }

    private func unhide(_ item: (itemId: String, itemType: String, name: String, subtitle: String, hiddenAt: Date)) {
        guard let serverId = appState.activeServerId else { return }
        do {
            try appState.databaseManager.unhideItem(id: item.itemId, type: item.itemType, serverId: serverId)

            // Re-add to runtime arrays
            if item.itemType == "album" {
                if let album = try? appState.databaseManager.loadAlbums(serverId: serverId).first(where: { $0.id == item.itemId }) {
                    if !appState.albums.contains(where: { $0.id == album.id }) {
                        appState.albums.append(album)
                        appState.albums.sort { $0.name < $1.name }
                    }
                }
            } else if item.itemType == "artist" {
                if let artist = try? appState.databaseManager.loadArtists(serverId: serverId).first(where: { $0.id == item.itemId }) {
                    if !appState.artists.contains(where: { $0.id == artist.id }) {
                        appState.artists.append(artist)
                        appState.artists.sort { $0.name < $1.name }
                    }
                }
            }

            // Refresh list
            loadItems()
        } catch {
            print("Failed to unhide item: \(error)")
        }
    }

    private func loadItems() {
        guard let serverId = appState.activeServerId else { return }
        hiddenItems = (try? appState.databaseManager.loadHiddenItemsWithNames(serverId: serverId)) ?? []
    }
}
