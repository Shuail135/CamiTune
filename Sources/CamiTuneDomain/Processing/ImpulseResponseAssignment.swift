import Foundation

package struct ImpulseResponseAssignment: Identifiable, Codable, Hashable, Sendable {
    package var impulseChannel: Int
    package var outputChannel: Int
    package var isEnabled: Bool
    package var id: Int { outputChannel }

    package init(impulseChannel: Int, outputChannel: Int, isEnabled: Bool = true) {
        self.impulseChannel = impulseChannel
        self.outputChannel = outputChannel
        self.isEnabled = isEnabled
    }
}

/// Assignments refer to configured physical outputs, never an assumed dense bus.
package struct ImpulseResponseAssignmentPlanner {
    package init() {}

    /// Explicit mappings remain attached to output identities as the topology changes.
    /// Missing outputs are skipped; new outputs receive no IR until enabled by the user.
    package func resolvedAssignments(for processor: ConvolutionProcessor,
                                     channels: [ConfiguredProcessingChannel],
                                     sampleRate: Int) throws -> [ImpulseResponseAssignment] {
        guard let mappings = processor.channelAssignments else {
            return try correspondingAssignments(asset: processor.asset, channels: channels, sampleRate: sampleRate)
        }
        guard Set(mappings.map(\.outputChannel)).count == mappings.count,
              mappings.allSatisfy({ $0.outputChannel >= 0 }) else {
            throw ProfileSettingsError.runtime("Each output can have only one impulse response assignment.")
        }
        let available = Set(channels.map(\.index))
        let active = mappings.filter { $0.isEnabled && available.contains($0.outputChannel) }
            .sorted { $0.outputChannel < $1.outputChannel }
        guard !active.isEmpty else { return [] }
        try validate(active, asset: processor.asset, channels: channels, sampleRate: sampleRate,
                     allowsSharedSource: true)
        return active
    }

    package func editableAssignments(for processor: ConvolutionProcessor,
                                     channels: [ConfiguredProcessingChannel]) -> [ImpulseResponseAssignment] {
        let saved = processor.channelAssignments ?? defaultAssignments(asset: processor.asset, channels: channels)
        return channels.sorted { $0.physicalOutputID.channelIndex < $1.physicalOutputID.channelIndex }.map { channel in
            saved.first { $0.outputChannel == channel.index }
                ?? .init(impulseChannel: 0, outputChannel: channel.index, isEnabled: false)
        }
    }

    package func correspondingAssignments(asset: ImpulseResponseAsset,
                                          channels: [ConfiguredProcessingChannel],
                                          sampleRate: Int) throws -> [ImpulseResponseAssignment] {
        guard asset.channelCount == channels.count else {
            throw ProfileSettingsError.runtime("Corresponding WAV channels requires one source channel per configured output (\(asset.channelCount) WAV channels, \(channels.count) outputs).")
        }
        let assignments = defaultAssignments(asset: asset, channels: channels)
        try validate(assignments, asset: asset, channels: channels, sampleRate: sampleRate)
        return assignments
    }

    package func defaultAssignments(asset: ImpulseResponseAsset,
                                    channels: [ConfiguredProcessingChannel]) -> [ImpulseResponseAssignment] {
        zip(0..<max(0, asset.channelCount), channels.sorted { $0.physicalOutputID.channelIndex < $1.physicalOutputID.channelIndex })
            .map { .init(impulseChannel: $0.0, outputChannel: $0.1.index) }
    }

    package func validate(_ assignments: [ImpulseResponseAssignment], asset: ImpulseResponseAsset,
                          channels: [ConfiguredProcessingChannel], sampleRate: Int,
                          allowsSharedSource: Bool = false) throws {
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
        guard allowsSharedSource || Set(assignments.map(\.impulseChannel)).count == assignments.count else {
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
