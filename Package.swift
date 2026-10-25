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
            .copy("CHANGELOG.md"),
            .copy("icon.png"),
            .copy("DeviceCorrectionTargets"),
            .copy("SpatialAssets")
        ]
    )
]

// All regression sources and fixtures stay in the ignored, local-only Tests folder.
// Published checkouts have no test targets or dependencies on test support.
let localTests = ProcessInfo.processInfo.environment["CAMITUNE_LOCAL_TESTS"] ?? ""
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let supportPath = "Tests/CamiTuneTestSupport"
let hasTestSupport = FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent(supportPath).path)
if ["1", "room", "correction", "diagnostics", "profile-ui", "multichannel", "fir"].contains(localTests), hasTestSupport {
    packageTargets.append(.target(name: "CamiTuneTestSupport",
        dependencies: ["CamiTune", "CamiTuneDomain", "CamiTuneAudio", "SystemAudioBridgeC"], path: supportPath))
}
let localSuites: [(name: String, modes: [String], excludes: [String])] = [
    ("RoomCorrectionRegression", ["1", "room"], ["Fixtures", "README.md"]),
    ("DeviceCorrectionRegression", ["1", "correction"], ["Fixtures", "SpeakerEQCoreTests.rs"]),
    ("MultichannelTests", ["1", "multichannel"], []),
    ("CamiTuneTests", ["1", "fir"], []),
    ("ProfileUIRegression", ["1", "profile-ui"], []),
    ("DiagnosticsRegression", ["1", "diagnostics"], [])
]
for suite in localSuites where suite.modes.contains(localTests) && hasTestSupport {
    let path = "Tests/\(suite.name)"
    guard FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent(path).path) else { continue }
    packageTargets.append(.testTarget(name: suite.name,
        dependencies: ["CamiTune", "CamiTuneDomain", "CamiTuneAudio", "SystemAudioBridgeC", "CamiTuneTestSupport"],
        path: path, exclude: suite.excludes))
}
for (name, modes, dependency) in [
    ("CamiTuneDomainTests", ["1", "domain", "modules", "fir"], "CamiTuneDomain"),
    ("CamiTuneAudioTests", ["1", "audio", "modules"], "CamiTuneAudio")
] where modes.contains(localTests) {
    let path = "Tests/\(name)"
    guard FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent(path).path) else { continue }
    let dependencies: [Target.Dependency] = dependency == "CamiTuneDomain" ? ["CamiTuneDomain"] : ["CamiTuneDomain", "CamiTuneAudio"]
    packageTargets.append(.testTarget(name: name, dependencies: dependencies, path: path))
}

let package = Package(
    name: "CamiTune",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CamiTune", targets: ["CamiTune"])
    ],
    targets: packageTargets
)
