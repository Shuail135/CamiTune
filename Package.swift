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
            .copy("DeviceCorrectionTargets")
        ]
    )
]

// Tests are intentionally local-only. Opt in when running the local test
// suite so a clean GitHub checkout does not require the ignored Tests folder.
if ProcessInfo.processInfo.environment["CAMITUNE_LOCAL_TESTS"] == "1" {
    packageTargets.append(
        .testTarget(
            name: "CamiTuneTests",
            dependencies: ["CamiTune", "SystemAudioBridgeC"],
            path: "Tests/CamiTuneTests"
        )
    )
}

let package = Package(
    name: "CamiTune",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CamiTune", targets: ["CamiTune"])
    ],
    targets: packageTargets
)
