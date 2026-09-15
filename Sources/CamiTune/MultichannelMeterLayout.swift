import Foundation

/// Meter indices describe their actual boundary: compact DSP input vs hardware output.
struct MultichannelMeterLayout: Equatable {
    struct Row: Identifiable, Equatable {
        var id: String
        var label: String
        var captureIndices: [Int]
        var playbackIndices: [Int]

        func level(peak: [Double], rms: [Double], capture: Bool) -> (peak: Double, rms: Double) {
            let indices = capture ? captureIndices : playbackIndices
            let peaks = indices.map { peak.indices.contains($0) && peak[$0].isFinite ? peak[$0] : -150 }
            let powers = indices.map { rms.indices.contains($0) && rms[$0].isFinite ? pow(10, max(-150, rms[$0]) / 10) : 0 }
            // Independent speakers do not sum in a meter. Peak is the loudest
            // member; RMS is mean power, never the arithmetic mean of dB values.
            let meanPower = powers.reduce(0, +) / Double(max(1, indices.count))
            return (peaks.max() ?? -150, meanPower > 0 ? max(-150, 10 * log10(meanPower)) : -150)
        }
    }

    var sourceChannels: [Row]?
    var groups: [Row]
    var channels: [Row]
    var usesGroups: Bool
    var requiresDSPCapture: Bool

    init(profile: DeviceProfile) {
        let configured = profile.configuredProcessingChannels
        let route = try? ActiveAudioRoute(profile: profile)
        let inputs = route?.dspInputFormat.channels ?? []
        if route?.usesSourceProcessingBus == true {
            sourceChannels = inputs.enumerated().map { index, channel in
                Row(id: "source:\(index)", label: channel.role == .unknown ? "Source \(index + 1)" : (channel.role?.displayName ?? "Source \(index + 1)"), captureIndices: [index], playbackIndices: [])
            }
        }
        func captureIndex(_ channel: ConfiguredProcessingChannel) -> Int? {
            if route?.usesPhysicalSpeakerBus == true {
                return inputs.firstIndex { $0.physicalOutputID == channel.physicalOutputID }
            }
            return inputs.indices.contains(channel.index) ? channel.index : nil
        }
        let usesGroups = profile.usesGroupedProcessingPresentation
        self.usesGroups = usesGroups
        requiresDSPCapture = profile.hasPhysicalSpeakerRoute && (usesGroups || inputs.map(\.role) != [.left, .right])
        channels = configured.map { channel in
            let label: String
            if !usesGroups && configured.count == 2, channel.role == .left { label = "L" }
            else if !usesGroups && configured.count == 2, channel.role == .right { label = "R" }
            else { label = channel.displayName }
            return Row(id: "output:\(channel.physicalOutputID.deviceUID):\(channel.physicalOutputID.channelIndex)",
                label: label, captureIndices: captureIndex(channel).map { [$0] } ?? [],
                playbackIndices: [channel.physicalOutputID.channelIndex])
        }
        groups = profile.configuredSpeakerGroups.map { group in
            let members = configured.filter { group.members.contains($0.physicalOutputID) }
            return Row(id: "group:\(group.id.rawValue)", label: group.name,
                captureIndices: members.compactMap(captureIndex), playbackIndices: members.map { $0.physicalOutputID.channelIndex })
        }
    }
}
