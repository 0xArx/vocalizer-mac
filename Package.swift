// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VocalizerMac",
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "CRing", path: "Sources/CRing"),
        .target(name: "VocalizerCore", dependencies: ["CRing"], path: "Sources/VocalizerCore"),
        .executableTarget(name: "VocalizerMac", dependencies: ["VocalizerCore", "CRing"], path: "Sources/VocalizerMac"),
        .executableTarget(name: "vocalizer-bench", dependencies: ["VocalizerCore"], path: "Sources/vocalizer-bench"),
        .executableTarget(name: "vocalizer-tap-test", dependencies: ["VocalizerCore"], path: "Sources/vocalizer-tap-test"),
    ]
)
