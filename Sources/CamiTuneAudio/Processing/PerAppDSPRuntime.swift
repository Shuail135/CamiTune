import CamiTuneDomain
import Foundation

package struct PerAppTransportClientKey: Hashable, Sendable {
    package init(deviceObjectID: UInt32, clientID: UInt32) {
        self.deviceObjectID = deviceObjectID
        self.clientID = clientID
    }

    package var deviceObjectID: UInt32
    package var clientID: UInt32
}

/// Owns filter, gain-ramp, and source-detection history by transport stream.
/// The caller serializes processing and maintenance with its existing audio lock.
/// Interval completion does not reset DSP history; stream epoch changes do.
package final class PerAppDSPRuntime {
    package init() {}
    private struct SourceDetector {
        var processID: Int32
        var generation: UInt64
        var detector = EffectiveLayoutDetector()
    }
    private var sourceDetectors: [PerAppTransportClientKey: SourceDetector] = [:]
    private var filterBanks: [PerAppTransportClientKey: PerAppFilterBank] = [:]
    private var gainsByClientKey: [PerAppTransportClientKey: Float] = [:]

    package func process(
        _ samples: inout [Float], packet: PerAppTimelinePacket,
        clientKey: PerAppTransportClientKey, processID: Int32, generation: UInt64,
        settings: PerAppAudioSettings, settingsRevision: UInt64, targetGain: Float
    ) -> SpatialInputDiagnostics? {
        if sourceDetectors[clientKey]?.processID != processID ||
            sourceDetectors[clientKey]?.generation != generation {
            if sourceDetectors.count >= 256, let oldest = sourceDetectors.keys.first {
                sourceDetectors.removeValue(forKey: oldest)
            }
            sourceDetectors[clientKey] = SourceDetector(processID: processID, generation: generation)
        }
        sourceDetectors[clientKey]?.detector.ingest(PCMFrame(interleaved: samples,
            channelCount: packet.channelCount, sampleRate: packet.sampleRate, channelLayout: packet.channelLayout),
            sampleTime: packet.startSampleTime)
        let sourceDiagnostics = sourceDetectors[clientKey]?.detector.diagnostics
        if !settings.isMuted && !settings.eqBypassed && settings.hasEqualizerProcessing {
            var bank = filterBanks[clientKey] ?? PerAppFilterBank()
            bank.process(
                &samples,
                channelCount: packet.channelCount,
                sampleRate: packet.sampleRate,
                bands: settings.equalizerBands,
                settingsRevision: settingsRevision, tone: settings.simpleTone
            )
            filterBanks[clientKey] = bank
        }
        applyGainRamp(
            to: &samples,
            channelCount: packet.channelCount,
            clientKey: clientKey,
            targetGain: targetGain
        )

        return sourceDiagnostics
    }

    package func retain(only keys: Set<PerAppTransportClientKey>) {
        sourceDetectors = sourceDetectors.filter { keys.contains($0.key) }
        filterBanks = filterBanks.filter { keys.contains($0.key) }
        gainsByClientKey = gainsByClientKey.filter { keys.contains($0.key) }
    }

    package func reset(deviceObjectID: UInt32) {
        sourceDetectors = sourceDetectors.filter { $0.key.deviceObjectID != deviceObjectID }
        filterBanks = filterBanks.filter { $0.key.deviceObjectID != deviceObjectID }
        gainsByClientKey = gainsByClientKey.filter { $0.key.deviceObjectID != deviceObjectID }
    }

    package func reset() {
        sourceDetectors.removeAll()
        filterBanks.removeAll()
        gainsByClientKey.removeAll()
    }

    /// Keep gain continuous at packet boundaries during interactive volume changes.
    private func applyGainRamp(
        to samples: inout [Float],
        channelCount: Int,
        clientKey: PerAppTransportClientKey,
        targetGain: Float
    ) {
        guard channelCount > 0, !samples.isEmpty else {
            gainsByClientKey[clientKey] = targetGain
            return
        }
        let frameCount = samples.count / channelCount
        guard frameCount > 0 else {
            gainsByClientKey[clientKey] = targetGain
            return
        }
        let startingGain = gainsByClientKey[clientKey] ?? targetGain
        if startingGain == targetGain {
            if targetGain != 1 {
                for index in samples.indices { samples[index] *= targetGain }
            }
        } else {
            let gainStep = (targetGain - startingGain) / Float(frameCount)
            var gain = startingGain
            for frame in 0..<frameCount {
                gain += gainStep
                let base = frame * channelCount
                for channel in 0..<channelCount {
                    samples[base + channel] *= gain
                }
            }
        }
        gainsByClientKey[clientKey] = targetGain
    }
}
