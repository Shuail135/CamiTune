import Foundation

package struct ImpulseResponseAssignment: Identifiable, Hashable, Sendable {
    package var impulseChannel: Int
    package var outputChannel: Int
    package var id: Int { impulseChannel }

    package init(impulseChannel: Int, outputChannel: Int) {
        self.impulseChannel = impulseChannel
        self.outputChannel = outputChannel
    }
}

/// Assignments refer to configured physical outputs, never an assumed dense bus.
package struct ImpulseResponseAssignmentPlanner {
    package init() {}

    package func defaultAssignments(asset: ImpulseResponseAsset,
                                    channels: [ConfiguredProcessingChannel]) -> [ImpulseResponseAssignment] {
        zip(0..<max(0, asset.channelCount), channels.sorted { $0.physicalOutputID.channelIndex < $1.physicalOutputID.channelIndex })
            .map { .init(impulseChannel: $0.0, outputChannel: $0.1.index) }
    }

    package func validate(_ assignments: [ImpulseResponseAssignment], asset: ImpulseResponseAsset,
                          channels: [ConfiguredProcessingChannel], sampleRate: Int) throws {
        guard asset.sampleRate == sampleRate else {
            throw ProcessingGraphError.impulseResponseSampleRateMismatch(asset.sampleRate, sampleRate)
        }
        guard asset.channelCount > 0, asset.frameCount > 0,
              asset.maximumMagnitudeDBByChannel.count == asset.channelCount,
              asset.maximumMagnitudeDBByChannel.allSatisfy(\.isFinite) else {
            throw ProcessingGraphError.invalidImpulseResponseMetadata
        }
        guard !assignments.isEmpty else { throw ProfileSettingsError.runtime("Choose at least one speaker for this impulse response.") }
        guard Set(assignments.map(\.outputChannel)).count == assignments.count else {
            throw ProfileSettingsError.runtime("Each speaker can receive only one WAV channel in an assignment.")
        }
        guard Set(assignments.map(\.impulseChannel)).count == assignments.count else {
            throw ProfileSettingsError.runtime("Each WAV channel can appear only once in an assignment.")
        }
        let available = Set(channels.map(\.index))
        for assignment in assignments {
            guard (0..<asset.channelCount).contains(assignment.impulseChannel) else {
                throw ProcessingGraphError.impulseResponseChannelOutOfRange(assignment.impulseChannel, asset.channelCount)
            }
            guard available.contains(assignment.outputChannel) else {
                throw ProfileSettingsError.runtime("An assigned speaker is no longer configured. Choose its destination again.")
            }
        }
    }

    package func apply(_ assignments: [ImpulseResponseAssignment], asset: ImpulseResponseAsset,
                       channels: [ConfiguredProcessingChannel], sampleRate: Int,
                       to processing: inout ProcessingProfile) throws {
        try validate(assignments, asset: asset, channels: channels, sampleRate: sampleRate)
        for assignment in assignments {
            let channel = channels.first { $0.index == assignment.outputChannel }!
            if !processing.channels.contains(where: { $0.index == channel.index }) {
                processing.channels.append(ChannelProcessing(index: channel.index, role: channel.role))
            }
            processing.setConvolution(.init(asset: asset, impulseChannel: assignment.impulseChannel), forChannel: channel.index)
        }
        processing.channels.sort { $0.index < $1.index }
    }
}
