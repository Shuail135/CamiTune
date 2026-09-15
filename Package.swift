// swift-tools-version: 5.9
import PackageDescription
import Foundation

var packageTargets: [Target] = [
    .target(
        name: "SystemAudioBridgeC",
        path: "Sources/SystemAudioBridgeC",
        publicHeadersPath: "include",
        linkerSettings: [
            .linkedFramework("CoreAudio"),
            .linkedFramework("CoreFoundation")
        ]
    ),
    .executableTarget(
        name: "CamiTune",
        dependencies: ["SystemAudioBridgeC"],
        path: "Sources/CamiTune",
        resources: [
            .copy("icon.png"),
            .copy("DeviceCorrectionTargets"),
            .copy("SpatialAssets")
        ]
    )
]

// Test sources stay local. Clean GitHub checkouts build without the ignored
// Tests directory; opt in to the suites available in this working copy.
if ProcessInfo.processInfo.environment["CAMITUNE_LOCAL_TESTS"] == "1" {
    let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for name in ["MultichannelTests", "CamiTuneTests"] {
        let path = "Tests/\(name)"
        guard FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent(path).path) else { continue }
        packageTargets.append(
            .testTarget(
                name: name,
                dependencies: ["CamiTune", "SystemAudioBridgeC"],
                path: path
            )
        )
    }
}

let package = Package(
    name: "CamiTune",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CamiTune", targets: ["CamiTune"])
    ],
    targets: packageTargets
)
