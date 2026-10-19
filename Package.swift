// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VocalizerMac",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "CRing", path: "Sources/CRing"),
        .target(name: "VocalizerObjC", path: "Sources/VocalizerObjC"),
        .target(name: "VocalizerCore", dependencies: ["CRing", "VocalizerObjC"], path: "Sources/VocalizerCore"),
        .executableTarget(name: "VocalizerMac", dependencies: ["VocalizerCore", "CRing", .product(name: "Sparkle", package: "Sparkle")],
                         path: "Sources/VocalizerMac",
                         linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "vocalizer-bench", dependencies: ["VocalizerCore"], path: "Sources/vocalizer-bench"),
        .executableTarget(name: "vocalizer-tap-test", dependencies: ["VocalizerCore"], path: "Sources/vocalizer-tap-test"),
    ]
)
