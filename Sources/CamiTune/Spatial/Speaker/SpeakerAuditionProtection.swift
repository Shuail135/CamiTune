import CamiTuneAudio
import CamiTuneDomain
import Foundation

/// Identification uses a direct hardware queue, so active-driver protection must
/// be applied to the prepared mono clip before that queue can be opened.
enum SpeakerAuditionProtection {
    static func samples(_ input: [Float], output: PhysicalOutputID, profile: DeviceProfile) throws -> [Float] {
        guard let endpoint = profile.speakerTopology?.endpoints.first(where: { $0.id == output }) else {
            throw SpeakerTopologyError.invalidDeviceUID
        }
        guard [.woofer, .midrange, .tweeter].contains(endpoint.function) else { return input }
        try profile.validateMultichannelSettings()
        guard let crossover = profile.multichannel.crossover.endpoints.first(where: { $0.endpointID == output }),
              let protection = profile.multichannel.crossover.protection[output] else {
            throw ProfileSettingsError.runtime("Configure this driver's crossover and protection before playing a test.")
        }
        var bands: [EQBand] = []
        for q in crossover.slope.sectionQs {
            if let frequency = crossover.highPassHz { bands.append(.init(kind: .highPass, frequency: frequency, q: q)) }
            if let frequency = crossover.lowPassHz { bands.append(.init(kind: .lowPass, frequency: frequency, q: q)) }
        }
        var samples = input
        var bank = PerAppFilterBank()
        bank.process(&samples, channelCount: 1, sampleRate: Double(profile.sampleRate), bands: bands, settingsRevision: 0)
        let gain = Float(pow(10, min(0, protection.maximumGainDB ?? 0) / 20))
        // Keep the conservative active-driver ceiling without hard-clipping a
        // louder identification clip and reintroducing out-of-band harmonics.
        let peak = samples.reduce(Float.zero) { $1.isFinite ? max($0, abs($1)) : $0 }
        let boundedGain = peak > 0 ? min(gain, 0.025 / peak) : gain
        return samples.map { $0.isFinite ? $0 * boundedGain : 0 }
    }
}
