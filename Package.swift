// swift-tools-version: 5.9
import PackageDescription
import Foundation

var packageTargets: [Target] = [
    .target(name: "CamiTuneDomain", path: "Sources/CamiTuneDomain"),
    .target(name: "CamiTuneAtomics", path: "Sources/CamiTuneAtomics", publicHeadersPath: "include"),
    .target(name: "CamiTuneAudio", dependencies: ["CamiTuneDomain", "CamiTuneAtomics"], path: "Sources/CamiTuneAudio"),
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
        dependencies: ["CamiTuneDomain", "CamiTuneAudio", "SystemAudioBridgeC"],
        path: "Sources/CamiTune",
        exclude: ["UI/README.md"],
        resources: [
            .copy("icon.png"),
            .copy("DeviceCorrectionTargets"),
            .copy("SpatialAssets")
        ]
    )
]

// Device Correction tests remain local and follow the existing opt-in policy.
if ProcessInfo.processInfo.environment["CAMITUNE_LOCAL_TESTS"] == "1" {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let path = "Tests/DeviceCorrectionRegression"
    if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
        packageTargets.append(.testTarget(name: "DeviceCorrectionRegression", dependencies: ["CamiTune", "CamiTuneDomain", "CamiTuneAudio"], path: path, exclude: ["Fixtures", "SpeakerEQCoreTests.rs"]))
    }
}

// Test sources stay local. Clean GitHub checkouts build without the ignored
// Tests directory; opt in to the suites available in this working copy.
if ["1", "domain", "modules"].contains(ProcessInfo.processInfo.environment["CAMITUNE_LOCAL_TESTS"] ?? "") {
    let path = "Tests/CamiTuneDomainTests"
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
        packageTargets.append(.testTarget(name: "CamiTuneDomainTests", dependencies: ["CamiTuneDomain"], path: path))
    }
}
if ["1", "audio", "modules"].contains(ProcessInfo.processInfo.environment["CAMITUNE_LOCAL_TESTS"] ?? "") {
    let path = "Tests/CamiTuneAudioTests"
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
        packageTargets.append(.testTarget(name: "CamiTuneAudioTests", dependencies: ["CamiTuneDomain", "CamiTuneAudio"], path: path))
    }
}
if ProcessInfo.processInfo.environment["CAMITUNE_LOCAL_TESTS"] == "1" {
    let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for name in ["MultichannelTests", "CamiTuneTests"] {
        let path = "Tests/\(name)"
        guard FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent(path).path) else { continue }
        packageTargets.append(
            .testTarget(
                name: name,
                dependencies: ["CamiTune", "CamiTuneDomain", "CamiTuneAudio", "SystemAudioBridgeC"],
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
