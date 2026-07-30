import AVKit
import SwiftUI

/// NSViewRepresentable wrapper for AVRoutePickerView to show AirPlay device picker
struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false

        // Style the button to match our UI
        if let button = picker.subviews.first(where: { $0 is NSButton }) as? NSButton {
            button.image = NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: "AirPlay")
        }

        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        // No dynamic updates needed
    }
}

#Preview {
    AirPlayButton()
        .frame(width: 24, height: 24)
}
