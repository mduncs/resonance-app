import Foundation

struct EQPreset: Identifiable, Codable, Sendable, Hashable, Equatable {
    let id: String
    let name: String
    let gains: [Float]  // 10 bands

    var isCustom: Bool {
        !EQPreset.builtInIds.contains(id)
    }

    static let builtInIds = Set(builtIn.map(\.id))

    static let flat = EQPreset(
        id: "flat",
        name: "Flat",
        gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    )

    static let bassBoost = EQPreset(
        id: "bass_boost",
        name: "Bass Boost",
        gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
    )

    static let trebleBoost = EQPreset(
        id: "treble_boost",
        name: "Treble Boost",
        gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]
    )

    static let vocal = EQPreset(
        id: "vocal",
        name: "Vocal",
        gains: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]
    )

    static let electronic = EQPreset(
        id: "electronic",
        name: "Electronic",
        gains: [4, 3, 0, -2, -1, 1, 0, 2, 4, 5]
    )

    static let rock = EQPreset(
        id: "rock",
        name: "Rock",
        gains: [4, 3, 2, 0, -1, 0, 1, 3, 4, 4]
    )

    static let acoustic = EQPreset(
        id: "acoustic",
        name: "Acoustic",
        gains: [3, 2, 1, 0, 1, 1, 2, 3, 2, 1]
    )

    static let lateNight = EQPreset(
        id: "late_night",
        name: "Late Night",
        gains: [-3, -2, 0, 1, 2, 2, 1, 0, -2, -4]
    )

    static let builtIn: [EQPreset] = [
        .flat,
        .bassBoost,
        .trebleBoost,
        .vocal,
        .electronic,
        .rock,
        .acoustic,
        .lateNight
    ]

    static let frequencies = [
        "32", "64", "125", "250", "500",
        "1K", "2K", "4K", "8K", "16K"
    ]
}

// MARK: - EQ Manager

@MainActor
final class EQManager: ObservableObject {
    @Published var isEnabled: Bool = false {
        didSet { saveSettings() }
    }

    @Published var currentPreset: EQPreset = .flat {
        didSet { saveSettings() }
    }

    @Published var customPresets: [EQPreset] = [] {
        didSet { saveCustomPresets() }
    }

    var allPresets: [EQPreset] {
        EQPreset.builtIn + customPresets
    }

    init() {
        loadSettings()
        loadCustomPresets()
    }

    func saveCustomPreset(name: String, gains: [Float]) {
        let preset = EQPreset(
            id: UUID().uuidString,
            name: name,
            gains: gains
        )
        customPresets.append(preset)
    }

    func deleteCustomPreset(_ preset: EQPreset) {
        customPresets.removeAll { $0.id == preset.id }
        if currentPreset.id == preset.id {
            currentPreset = .flat
        }
    }

    private func saveSettings() {
        UserDefaults.standard.set(isEnabled, forKey: "eq.enabled")
        UserDefaults.standard.set(currentPreset.id, forKey: "eq.presetId")
    }

    private func loadSettings() {
        isEnabled = UserDefaults.standard.bool(forKey: "eq.enabled")
        if let presetId = UserDefaults.standard.string(forKey: "eq.presetId"),
           let preset = allPresets.first(where: { $0.id == presetId }) {
            currentPreset = preset
        }
    }

    private func saveCustomPresets() {
        if let data = try? JSONEncoder().encode(customPresets) {
            UserDefaults.standard.set(data, forKey: "eq.customPresets")
        }
    }

    private func loadCustomPresets() {
        if let data = UserDefaults.standard.data(forKey: "eq.customPresets"),
           let presets = try? JSONDecoder().decode([EQPreset].self, from: data) {
            customPresets = presets
        }
    }
}
