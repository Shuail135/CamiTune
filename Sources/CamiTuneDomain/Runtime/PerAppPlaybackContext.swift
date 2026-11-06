import Foundation

package struct PerAppPlaybackContext: Hashable, Sendable {
    package let preservesHeadphoneMix: Bool
    package let isPersonalSpatial: Bool
    package let movieScope: MovieApplicationScope?
    package let showsModeControls: Bool
    package let profileMode: PlaybackMode
    package let visibleModes: [PlaybackMode]
    package let readiness: [PlaybackMode: PlaybackModeReadiness]
    package var availableModes: Set<PlaybackMode> { Set(readiness.compactMap { $0.value.isReady ? $0.key : nil }) }

    package init(profile: DeviceProfile) {
        isPersonalSpatial = profile.isPersonalListening && profile.effectivePluginRack.outputMode != .exclusive
        preservesHeadphoneMix = isPersonalSpatial && profile.personalSpatial.experience == .gaming
            && profile.personalSpatial.gamingRendering == .headphones
        movieScope = isPersonalSpatial && profile.effectivePlaybackMode == .spatialRender
            && profile.personalSpatial.experience == .movie
            ? profile.personalSpatial.movie.scope : nil
        showsModeControls = profile.isSectionEnabled(.mode)
        visibleModes = profile.availablePlaybackModes
        readiness = Dictionary(uniqueKeysWithValues: visibleModes.map { ($0, profile.playbackReadiness($0)) })
        profileMode = profile.effectivePlaybackMode
    }

    package func cohort(for override: PlaybackMode?, applicationID: String, alreadyBinaural: Bool = false) -> ProcessingCohort {
        let mode = effectiveMode(for: override)
        if mode == .spatialRender, isPersonalSpatial, alreadyBinaural || preservesHeadphoneMix { return .direct }
        if mode == .spatialRender, let movieScope, movieScope.contains(applicationID) { return .spatialMovie }
        return ProcessingCohort(mode)
    }

    package func effectiveMode(for override: PlaybackMode?) -> PlaybackMode {
        guard let override, readiness[override]?.isReady == true else {
            return readiness[profileMode]?.isReady == true ? profileMode : .direct
        }
        return override
    }
}
