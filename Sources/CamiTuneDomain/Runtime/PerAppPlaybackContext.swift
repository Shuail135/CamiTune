import Foundation

package struct PerAppPlaybackContext: Hashable, Sendable {
    package var movie: MovieSettings?
    package var showsModeControls: Bool
    package var profileMode: PlaybackMode
    package var visibleModes: [PlaybackMode]
    package var readiness: [PlaybackMode: PlaybackModeReadiness]
    package var availableModes: Set<PlaybackMode>

    package init(profile: DeviceProfile) {
        movie = profile.isPersonalListening && profile.effectivePlaybackMode == .spatialRender
            && profile.personalSpatial.experience == .spatialListening
            && profile.effectivePluginRack.outputMode != .exclusive ? profile.personalSpatial.movie : nil
        showsModeControls = profile.isSectionEnabled(.mode)
        visibleModes = profile.availablePlaybackModes
        readiness = Dictionary(uniqueKeysWithValues: visibleModes.map { ($0, profile.playbackReadiness($0)) })
        profileMode = profile.effectivePlaybackMode
        availableModes = Set(profile.availablePlaybackModes.filter { profile.playbackReadiness($0).isReady })
    }

    package func cohort(for override: PlaybackMode?, applicationID: String) -> ProcessingCohort {
        let mode = effectiveMode(for: override)
        if mode == .spatialRender, let movie, movie.enabled, movie.scope.contains(applicationID) { return .spatialMovie }
        return ProcessingCohort(mode)
    }

    package func effectiveMode(for override: PlaybackMode?) -> PlaybackMode {
        guard let override, availableModes.contains(override) else { return availableModes.contains(profileMode) ? profileMode : .direct }
        return override
    }
}
