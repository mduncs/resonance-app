import SwiftUI
import AppKit

// MARK: - Share Content Types

enum ShareContent: Sendable {
    case song(Song)
    case album(Album)
    case playlist(Playlist)
    case artist(Artist)
    case nowPlaying(Song)

    var shareText: String {
        switch self {
        case .song(let song):
            return "\"\(song.title)\" by \(song.artist)"
        case .album(let album):
            return "\(album.name) by \(album.artist)"
        case .playlist(let playlist):
            return "Playlist: \(playlist.name)"
        case .artist(let artist):
            return artist.name
        case .nowPlaying(let song):
            return "Now playing: \"\(song.title)\" by \(song.artist)"
        }
    }

    var copyLabel: String {
        switch self {
        case .song, .nowPlaying:
            return "Copy Song Info"
        case .album:
            return "Copy Album Info"
        case .playlist:
            return "Copy Playlist Name"
        case .artist:
            return "Copy Artist Name"
        }
    }
}

// MARK: - Share Menu for Context Menus

struct ShareMenu: View {
    let content: ShareContent

    var body: some View {
        Menu {
            Button {
                showShareSheet(text: content.shareText)
            } label: {
                Label("Share...", systemImage: "square.and.arrow.up")
            }

            Divider()

            Button {
                copyToClipboard(content.shareText)
            } label: {
                Label(content.copyLabel, systemImage: "doc.on.doc")
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private func showShareSheet(text: String) {
        let picker = NSSharingServicePicker(items: [text])

        // Get the current window and show picker anchored to it
        if let window = NSApp.keyWindow,
           let contentView = window.contentView {
            // Show picker from the center of the window
            let rect = NSRect(
                x: contentView.bounds.midX,
                y: contentView.bounds.midY,
                width: 1,
                height: 1
            )
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Standalone Share Button (for toolbars, etc.)

struct ShareButton: View {
    let content: ShareContent
    var showLabel: Bool = false

    var body: some View {
        Button {
            showShareSheet()
        } label: {
            if showLabel {
                Label("Share", systemImage: "square.and.arrow.up")
            } else {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .help("Share")
    }

    private func showShareSheet() {
        let picker = NSSharingServicePicker(items: [content.shareText])

        if let window = NSApp.keyWindow,
           let contentView = window.contentView {
            let rect = NSRect(
                x: contentView.bounds.midX,
                y: contentView.bounds.midY,
                width: 1,
                height: 1
            )
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }
}

// MARK: - Quick Share Button (copies and shows feedback)

struct QuickCopyButton: View {
    let content: ShareContent
    @State private var copied = false

    var body: some View {
        Button {
            copyToClipboard()
        } label: {
            Label(
                copied ? "Copied!" : content.copyLabel,
                systemImage: copied ? "checkmark" : "doc.on.doc"
            )
        }
        .animation(.easeInOut(duration: 0.2), value: copied)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content.shareText, forType: .string)

        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}

#Preview("Share Menu") {
    VStack(spacing: 20) {
        Text("Right-click for context menu")
            .contextMenu {
                ShareMenu(content: .song(.placeholder))
            }

        Text("Album context menu")
            .contextMenu {
                ShareMenu(content: .album(.placeholder))
            }
    }
    .padding()
    .frame(width: 300, height: 200)
}

#Preview("Share Button") {
    HStack(spacing: 20) {
        ShareButton(content: .song(.placeholder))
        ShareButton(content: .song(.placeholder), showLabel: true)
    }
    .padding()
}
