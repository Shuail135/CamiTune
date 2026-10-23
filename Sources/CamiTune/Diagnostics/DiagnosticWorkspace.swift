import Foundation

/// Temporary storage for measurements; never replaces the user’s saved settings.
@MainActor
final class DiagnosticWorkspace {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let profiles: ProfileStore
    let perApp: PerAppAudioController

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CamiTune-Diagnostics-\(UUID().uuidString)", isDirectory: true)
        suite = "CamiTune.Diagnostics.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw DiagnosticFailure(message: "Cannot create isolated preferences") }
        self.defaults = defaults
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        profiles = ProfileStore(storageURL: directory.appendingPathComponent("profiles.json"), userDefaults: defaults)
        perApp = PerAppAudioController(settingsURL: directory.appendingPathComponent("per-app.json"),
            audioHistoryURL: directory.appendingPathComponent("history.json"), monitorsRunningApplications: false)
    }

    func cleanUp() {
        profiles.flushPendingSaveSynchronously()
        perApp.resetRuntime()
        perApp.flushPendingSaveSynchronously()
        perApp.presentationStore.flushPendingSaveSynchronously()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

}
