import AVFoundation
import AVKit
import Combine
import SwiftUI

@MainActor
final class AirPlayRouteAvailability: NSObject, ObservableObject {
    @Published private(set) var multipleRoutesDetected = false

    private let detector = AVRouteDetector()
    private var observation: NSKeyValueObservation?

    override init() {
        super.init()
        guard !DeterministicCaptureFixture.isEnabled else { return }

        detector.isRouteDetectionEnabled = true
        observation = detector.observe(
            \.multipleRoutesDetected,
            options: [.initial, .new]
        ) { [weak self] detector, change in
            let detected = change.newValue ?? detector.multipleRoutesDetected
            Task { @MainActor [weak self] in
                self?.multipleRoutesDetected = detected
            }
        }
    }
}

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
