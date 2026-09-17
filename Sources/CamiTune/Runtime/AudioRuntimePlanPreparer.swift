import AVFoundation
import CryptoKit
import Foundation

struct PreparedRuntimeAssets: Hashable, Sendable {
    struct Asset: Hashable, Sendable {
        let metadata: ImpulseResponseAsset
        let url: URL
        let sha256: String
    }
    let impulseResponses: [UUID: Asset]
    static let empty = Self(impulseResponses: [:])

    static func prepare(profile: DeviceProfile, directory: URL) throws -> Self {
        let processing = try profile.resolvedProcessing()
        let activeChannels = Set(profile.configuredProcessingChannels.map(\.index))
        let activeGroups = Set(profile.configuredSpeakerGroups.map(\.id))
        let chains = [processing.global]
            + processing.channels.filter { !profile.hasPhysicalSpeakerRoute || activeChannels.contains($0.index) }.map(\.chain)
            + processing.groups.filter { activeGroups.contains($0.id) }.map(\.chain)
        var prepared: [UUID: Asset] = [:]
        for stage in chains.flatMap(\.stages) where stage.isEnabled {
            guard case .convolution(let convolution) = stage.processor else { continue }
            let asset = convolution.asset
            guard asset.fileName == "\(asset.id.uuidString.lowercased()).wav" else {
                throw ProcessingGraphError.invalidImpulseResponseReference(asset.fileName)
            }
            guard asset.sampleRate == profile.sampleRate else {
                throw ProcessingGraphError.impulseResponseSampleRateMismatch(asset.sampleRate, profile.sampleRate)
            }
            guard asset.frameCount > 0, asset.channelCount > 0,
                  asset.frameCount <= ImpulseResponseStore.maximumTotalSamples / asset.channelCount,
                  asset.maximumMagnitudeDBByChannel.count == asset.channelCount,
                  asset.maximumMagnitudeDBByChannel.allSatisfy(\.isFinite),
                  (0..<asset.channelCount).contains(convolution.impulseChannel) else {
                throw ProcessingGraphError.invalidImpulseResponseMetadata
            }
            if let existing = prepared[asset.id] {
                guard existing.metadata == asset else { throw ProcessingGraphError.invalidImpulseResponseMetadata }
                continue
            }
            let url = directory.appendingPathComponent(asset.fileName)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw ProcessingGraphError.impulseResponseMissing(asset.displayName)
            }
            let file: AVAudioFile
            do { file = try AVAudioFile(forReading: url) }
            catch { throw ImpulseResponseImportError.unreadableWAV(error.localizedDescription) }
            guard file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
                  Int(file.processingFormat.channelCount) == asset.channelCount,
                  file.length == asset.frameCount,
                  file.processingFormat.sampleRate == Double(asset.sampleRate) else {
                throw ProcessingGraphError.invalidImpulseResponseMetadata
            }
            prepared[asset.id] = .init(metadata: asset, url: url, sha256: try contentSHA256(at: url))
        }
        return .init(impulseResponses: prepared)
    }

    /// Streams the entire file through SHA-256 with at most 64 KiB per read.
    /// No chunk list or whole-file Data is retained, including on worker threads.
    static func contentSHA256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 64 * 1024) }),
              !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Resolves external evidence without owning sessions or performing runtime mutations.
struct AudioRuntimePlanPreparer {
    @MainActor
    func prepare(profile original: DeviceProfile, revision: RuntimeIntentRevision,
                 services: AudioRuntimeServices,
                 phase: (String) -> Void = { _ in }) async throws -> AudioRuntimePlan {
        let profile = try await Task.detached(priority: .userInitiated) { try Self.normalize(original) }.value
        phase("intent normalized")
        let needsTopology = try profile.validatedPhysicalSpeakerTopology() != nil || profile.validatedInterfaceConfiguration() != nil
        let hardware = try await evidence(output: profile.outputDevice, sampleRate: profile.sampleRate,
            needsTopology: needsTopology, services: services, phase: phase)
        phase("hardware evidence")
        let directory = CamiTunePaths.impulseResponsesDirectory
        let assets = try await Task.detached(priority: .userInitiated) {
            try PreparedRuntimeAssets.prepare(profile: profile, directory: directory)
        }.value
        phase("assets prepared")
        let input = PreparedRuntimeInputs(revision: revision, preparedAt: Date(), profile: profile, hardware: hardware, assets: assets)
        let plan = try await Task.detached(priority: .userInitiated) { try AudioRuntimePlanCompiler().compile(input) }.value
        phase("pure compile")
        return plan
    }

    @MainActor
    private func evidence(output identity: PhysicalOutputIdentity, sampleRate: Int, needsTopology: Bool,
                          services: AudioRuntimeServices, phase: (String) -> Void = { _ in }) async throws -> RuntimeHardwareEvidence {
        guard let output = await services.resolveOutput(identity.uid) else {
            throw AppState.AppError.outputMissing(identity.name)
        }
        guard !output.isRoutingDevice else { throw AppState.AppError.invalidTarget }
        phase("physical output resolved")
        guard await services.supportsRate(output.id, Double(sampleRate)) else {
            throw AppState.AppError.unsupportedSampleRate(sampleRate, output.name)
        }
        if let bridge = await services.resolveBridge() {
            guard await services.supportsRate(bridge.id, Double(sampleRate)) else {
                throw AppState.AppError.unsupportedSampleRate(sampleRate, bridge.name)
            }
        } else { throw AppState.AppError.missingRoutingDriver }
        let topology: SpeakerTopology?
        if needsTopology { topology = try await services.probeTopology(output) }
        else { topology = nil }
        let count: Int
        if let topology { count = topology.declaredChannelCount }
        else { count = try await services.outputChannelCount(output) }
        return .init(output: .init(uid: output.id, name: output.name), sampleRate: sampleRate,
            physicalChannelCount: count, speakerTopology: topology,
            fingerprint: try topology.map { try HardwareTopologyFingerprint(topology: $0) }
                ?? .init(deviceUID: output.id, channelCount: count), simulated: false)
    }

    /// Rechecks only execution-critical hardware evidence, never recompiles or
    /// silently substitutes a different rollback configuration.
    @MainActor
    func validateCurrent(_ plan: AudioRuntimePlan, services: AudioRuntimeServices) async throws {
        guard !plan.hardwareEvidence.simulated else { throw AppState.AppError.invalidTarget }
        let expected = plan.hardwareEvidence
        let current = try await evidence(output: expected.output, sampleRate: expected.sampleRate,
            needsTopology: expected.speakerTopology != nil, services: services)
        guard current.fingerprint == plan.hardwareFingerprint else { throw SpeakerTopologyError.hardwareLayoutChanged }
    }

    static func normalize(_ original: DeviceProfile) throws -> DeviceProfile {
        var profile = original
        try profile.migrateInterfaceTopology()
        // Freeze generated/legacy processing identities before pure compilation.
        profile.replaceProcessing(try profile.resolvedProcessing())
        return profile
    }

    static func prepare(profile: DeviceProfile, hardware: any AudioHardwareTopologyProvider) throws -> AudioRuntimePlan {
        try prepare(profile: profile, detectedHardware: hardware.topology(for: profile.outputDeviceUID,
            sampleRate: Double(profile.sampleRate)).speakerTopology)
    }

    /// Inactive persistence validation uses declared channel evidence. It does
    /// not query absent hardware and cannot authorize execution of the result.
    static func prepareForStorage(profile: DeviceProfile, revision: RuntimeIntentRevision) throws -> AudioRuntimePlan {
        let profile = try normalize(profile)
        guard (1...SpeakerTopology.maximumOutputChannels).contains(profile.configuredPhysicalChannelCount) else {
            throw SpeakerTopologyError.unsupportedChannelCount(profile.configuredPhysicalChannelCount)
        }
        let topology = (profile.hasPhysicalSpeakerRoute ? profile.speakerTopology : nil) ?? SpeakerTopology(deviceUID: profile.outputDeviceUID,
            sampleRate: Double(profile.sampleRate), declaredChannelCount: profile.configuredPhysicalChannelCount,
            endpoints: (0..<profile.configuredPhysicalChannelCount).map {
                .init(id: .init(deviceUID: profile.outputDeviceUID, channelIndex: $0), displayName: "Output \($0 + 1)")
            })
        return try prepare(profile: profile, detectedHardware: topology, revision: revision)
    }

    /// Explicit supplied evidence for previews and isolated developer fixtures.
    /// This path never discovers hardware and cannot be used to activate a device.
    static func prepare(profile: DeviceProfile, detectedHardware: SpeakerTopology,
                        revision: RuntimeIntentRevision? = nil,
                        assetDirectory: URL = CamiTunePaths.impulseResponsesDirectory) throws -> AudioRuntimePlan {
        let profile = try normalize(profile)
        let hardware = RuntimeHardwareEvidence(output: .init(uid: detectedHardware.deviceUID, name: profile.outputDeviceName),
            sampleRate: profile.sampleRate, physicalChannelCount: detectedHardware.declaredChannelCount,
            speakerTopology: detectedHardware, fingerprint: try .init(topology: detectedHardware), simulated: true)
        return try AudioRuntimePlanCompiler().compile(.init(revision: revision ?? .init(profileID: profile.id, generation: 0),
            preparedAt: Date(), profile: profile, hardware: hardware,
            assets: PreparedRuntimeAssets.prepare(profile: profile, directory: assetDirectory)))
    }
}
