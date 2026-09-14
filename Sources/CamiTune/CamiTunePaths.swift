import Foundation

enum CamiTunePaths {
    static let supportDirectory: URL = {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let current = applicationSupport.appendingPathComponent("CamiTune", isDirectory: true)
        let legacy = applicationSupport.appendingPathComponent("CamillaApp", isDirectory: true)

        try? fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        migrateLegacySupportDirectory(from: legacy, to: current, fileManager: fileManager)

        return current
    }()

    /// Immutable, app-managed impulse responses referenced by ProcessingProfile.
    /// Keeping these beside profiles prevents security-scoped import URLs from
    /// expiring and gives future profile bundles a stable asset boundary.
    static var impulseResponsesDirectory: URL {
        supportDirectory.appendingPathComponent("ImpulseResponses", isDirectory: true)
    }

    static var perAppPresentationURL: URL {
        supportDirectory.appendingPathComponent("PerAppPresentation.json")
    }

    static var perAppAudioSettingsURL: URL {
        supportDirectory.appendingPathComponent("PerAppAudio.json")
    }

    static func migrateLegacySupportDirectory(
        from legacy: URL,
        to current: URL,
        fileManager: FileManager = .default
    ) {
        // Preserve profiles, the managed CamillaDSP installation, logs, and
        // prepared-update state for users upgrading from CamillaApp. Keep the
        // legacy directory as a recoverable backup and copy only files that do
        // not already exist in the CamiTune directory.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        try? fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        mergeMissingContents(from: legacy, to: current, fileManager: fileManager)
    }

    private static func mergeMissingContents(
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        fileManager: FileManager
    ) {
        guard let children = try? fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for source in children {
            let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            var sourceIsDirectory: ObjCBool = false
            let sourceExists = fileManager.fileExists(
                atPath: source.path,
                isDirectory: &sourceIsDirectory
            )
            guard sourceExists else { continue }

            var destinationIsDirectory: ObjCBool = false
            let destinationExists = fileManager.fileExists(
                atPath: destination.path,
                isDirectory: &destinationIsDirectory
            )
            if !destinationExists {
                try? fileManager.copyItem(at: source, to: destination)
            } else if sourceIsDirectory.boolValue && destinationIsDirectory.boolValue {
                mergeMissingContents(
                    from: source,
                    to: destination,
                    fileManager: fileManager
                )
            }
        }
    }
}
