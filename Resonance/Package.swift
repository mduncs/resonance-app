// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Resonance",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Resonance", targets: ["Resonance"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Resonance",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Resonance",
            exclude: [
                "Resources/Info.plist",
                "Resources/Resonance.entitlements"
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/EQPresets.json")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ResonanceTests",
            dependencies: ["Resonance"],
            path: "ResonanceTests"
        )
    ]
)
