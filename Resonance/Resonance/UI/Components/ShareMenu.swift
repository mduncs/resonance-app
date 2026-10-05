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

// MARK: - Sharing Picker Presentation

/// Zero-size AppKit view planted directly beneath a share control so the
/// sharing picker can anchor to the real control instead of a synthetic
/// window-center rectangle.
private final class ShareAnchorView: NSView {}

private struct ShareAnchorReader: NSViewRepresentable {
    @Binding var anchor: ShareAnchorView?

    func makeNSView(context: Context) -> ShareAnchorView {
        ShareAnchorView()
    }

    func updateNSView(_ nsView: ShareAnchorView, context: Context) {
        if anchor !== nsView {
            anchor = nsView
        }
    }
}

/// Anchors the picker to real geometry: the recorded control's own bounds
/// while it is live on screen (toolbar/button placements), otherwise a
/// one-point rect at the current pointer location — a context-menu item's
/// transient host window is gone by action time, and the pointer is where the
/// user invoked Share. A window-center rect is never synthesized.
@MainActor
private enum ShareSheetPresenter {
    static func show(items: [Any], anchor: ShareAnchorView?) {
        let picker = NSSharingServicePicker(items: items)

        if let anchor, anchor.window != nil {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            return
        }

        guard let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: \.isVisible),
              let contentView = window.contentView else { return }

        let pointerInWindow = window.convertFromScreen(
            NSRect(origin: NSEvent.mouseLocation, size: .zero)
        ).origin
        let point = contentView.convert(pointerInWindow, from: nil)
        picker.show(
            relativeTo: NSRect(origin: point, size: CGSize(width: 1, height: 1)),
            of: contentView,
            preferredEdge: .minY
        )
    }
}

// MARK: - Share Menu for Context Menus

struct ShareMenu: View {
    @Environment(AppState.self) private var appState

    let content: ShareContent

    var body: some View {
        Menu {
            Button {
                ShareSheetPresenter.show(items: [content.shareText], anchor: nil)
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


    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            appState.showFeedback(
                message: "Couldn't copy to clipboard",
                style: .error,
                systemImage: "exclamationmark.triangle"
            )
            return
        }
        appState.showFeedback(message: "Copied to clipboard", style: .success, systemImage: "doc.on.doc")
    }
}

// MARK: - Standalone Share Button (for toolbars, etc.)

struct ShareButton: View {
    let content: ShareContent
    var showLabel: Bool = false
    @State private var anchor: ShareAnchorView?

    var body: some View {
        Button {
            ShareSheetPresenter.show(items: [content.shareText], anchor: anchor)
        } label: {
            if showLabel {
                Label("Share", systemImage: "square.and.arrow.up")
            } else {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .help("Share")
        .background(ShareAnchorReader(anchor: $anchor))
    }

}

// MARK: - Quick Share Button (copies and shows feedback)

struct QuickCopyButton: View {
    let content: ShareContent
    @State private var copyState: CopyState = .idle

    private enum CopyState: Equatable {
        case idle
        case copied
        case failed

        var title: String {
            switch self {
            case .idle: return "Copy"
            case .copied: return "Copied!"
            case .failed: return "Copy Failed"
            }
        }

        var systemImage: String {
            switch self {
            case .idle: return "doc.on.doc"
            case .copied: return "checkmark"
            case .failed: return "exclamationmark.triangle"
            }
        }
    }

    var body: some View {
        Button {
            copyToClipboard()
        } label: {
            Label(copyState == .idle ? content.copyLabel : copyState.title, systemImage: copyState.systemImage)
        }
        .animation(.easeInOut(duration: 0.2), value: copyState)
        .task(id: copyState) {
            guard copyState != .idle else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copyState = .idle
        }
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copyState = pasteboard.setString(content.shareText, forType: .string) ? .copied : .failed
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
    .environment(AppState())
}

#Preview("Share Button") {
    HStack(spacing: 20) {
        ShareButton(content: .song(.placeholder))
        ShareButton(content: .song(.placeholder), showLabel: true)
    }
    .padding()
}
