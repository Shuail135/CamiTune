import Foundation

package struct PerAppPlaybackContext: Hashable, Sendable {
    package var profileMode: PlaybackMode
    package var visibleModes: [PlaybackMode]
    package var readiness: [PlaybackMode: PlaybackModeReadiness]
    package var availableModes: Set<PlaybackMode>

    package init(profile: DeviceProfile) {
        visibleModes = profile.availablePlaybackModes
        readiness = Dictionary(uniqueKeysWithValues: visibleModes.map { ($0, profile.playbackReadiness($0)) })
        profileMode = profile.playbackMode
        availableModes = Set(profile.availablePlaybackModes.filter { profile.playbackReadiness($0).isReady })
    }

    package func effectiveMode(for override: PlaybackMode?) -> PlaybackMode {
        guard let override, availableModes.contains(override) else { return availableModes.contains(profileMode) ? profileMode : .direct }
        return override
    }
}
