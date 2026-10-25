import CamiTuneAudio
import CamiTuneDomain
import CryptoKit
import Foundation

/// Learns off the audio thread. Recommendations are persisted separately from
/// user preferences. The runtime consumes them on the next activation after
/// the profile is no longer in use; learning never modifies the active buffer or PCM.
@MainActor
final class AutomaticAudioBufferController: ObservableObject {
    struct Status: Equatable {
        let currentFrames: Int
        let nextFrames: Int
    }
    private struct Record: Codable {
        var frames: Int
        var minimumFrames: Int
        var updated: Date
    }
    private struct Context {
        let profileID: UUID
        let key: String
        let currentFrames: Int
        let started: Date
        var lastObserved: Date
        var clockEpoch: UInt64?
        var underruns: UInt64?
        var wasContinuouslyActive = false
        var droppedFrames: UInt64
        var policy: AutomaticAudioBufferPolicy
    }
    @Published private(set) var statuses: [UUID: Status] = [:]
    private var records: [String: Record]
    private var context: Context?
    private let persist: (Data) -> Void
    init(cache: Data? = nil, persist: @escaping (Data) -> Void = { _ in }) {
        self.persist = persist
        let decoded = cache.flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
        records = decoded.filter { _, value in
            AutomaticAudioBufferPolicy.sizes.contains(value.frames)
                && AutomaticAudioBufferPolicy.sizes.contains(value.minimumFrames)
                && value.frames >= value.minimumFrames
                && Date().timeIntervalSince(value.updated) >= 0
                && Date().timeIntervalSince(value.updated) < 30 * 86400
        }
    }

    /// Exact processing configuration, excluding presentation/preferences and
    /// bypassed effects. A changed rack, rate, channel setup or correction must
    /// establish its own evidence instead of borrowing a lighter setup's size.
    static func setupKey(for profile: DeviceProfile) -> String? {
        guard let profile = try? AudioRuntimePlanPreparer.normalize(profile) else { return nil }
        guard let data = try? JSONEncoder().encode(profile),
              var value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for key in ["id", "name", "chunkSize", "usesGlobalAudioBuffer", "audioBufferSetting", "sectionLayout",
                    "outputVolumeScalar", "lockOutputVolume", "autoActivateWhenProfileDeviceSelected", "isEnabled",
                    "deviceTypeConfigurations", "playbackModesByEndpoint", "speakerVerification"] { value[key] = nil }
        var rack = profile.pluginRack
        // The exclusive buffer is dormant when this controller tunes CamillaDSP.
        rack.exclusiveBufferSize = 128
        rack.slots = rack.activeSlots
        rack.isEnabled = true
        guard let rackData = try? JSONEncoder().encode(rack),
              let rackValue = try? JSONSerialization.jsonObject(with: rackData) else { return nil }
        value["pluginRack"] = rackValue
        value["hostOS"] = ProcessInfo.processInfo.operatingSystemVersionString
        guard let canonical = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    func recommendedFrames(for profile: DeviceProfile) -> Int {
        guard let key = Self.setupKey(for: profile), let record = records[key],
              Date().timeIntervalSince(record.updated) < 30 * 86400 else {
            return AutomaticAudioBufferPolicy.startingFrames(sampleRate: profile.sampleRate)
        }
        return record.frames
    }

    func begin(profile: DeviceProfile, now: Date = Date()) {
        guard !profile.usesExclusivePluginOutput, let key = Self.setupKey(for: profile) else { end(); return }
        if context?.profileID != profile.id { end() }
        let record = records[key].flatMap { now.timeIntervalSince($0.updated) < 30 * 86400 ? $0 : nil }
        context = Context(profileID: profile.id, key: key, currentFrames: profile.chunkSize, started: now,
            lastObserved: now, droppedFrames: 0,
            policy: .init(frames: record?.frames ?? profile.chunkSize,
                minimumFrames: record?.minimumFrames ?? 128))
        publish()
    }
    func end() {
        if let context { statuses[context.profileID] = nil }
        context = nil
    }

    func observe(work: AudioBufferWorkObservation, dspLoadPercent: Double?, clockEpoch: UInt64?,
                 underrunFrames: UInt64?, droppedFrames: UInt64, now: Date = Date()) {
        guard var current = context else { return }
        let elapsed = now.timeIntervalSince(current.lastObserved)
        let usable = now.timeIntervalSince(current.started) >= 3 && elapsed > 0 && elapsed <= 2.5
        // The output clock also counts starvation while the producer is idle.
        // Compare counters only across complete active intervals, so a pause
        // or resume cannot masquerade as an undersized processing buffer.
        let continuouslyActive = usable && work.audioSeconds.isFinite && work.audioSeconds >= elapsed * 0.9
        let clockIsContinuous = (clockEpoch ?? 0) > 0 && clockEpoch == current.clockEpoch
        let underrunDelta: UInt64?
        if continuouslyActive, current.wasContinuouslyActive, clockIsContinuous,
           let count = underrunFrames, let previous = current.underruns, count >= previous {
            underrunDelta = count - previous
        } else { underrunDelta = nil }
        let dropped = droppedFrames > current.droppedFrames
        current.clockEpoch = clockEpoch; current.underruns = underrunFrames
        current.wasContinuouslyActive = continuouslyActive
        current.droppedFrames = droppedFrames; current.lastObserved = now
        let oldRecommendation = current.policy.recommendedFrames
        let oldMinimum = current.policy.minimumFrames
        // Discard startup transients and stale/incomplete collection intervals.
        current.policy.observe(.init(audioSeconds: usable ? min(work.audioSeconds, elapsed) : 0,
            dspLoad: dspLoadPercent.map { $0 / 100 }, writerLoad: work.writerLoad, pluginLoad: work.pluginLoad,
            underruns: underrunDelta, deliveryFault: dropped, pluginFailed: work.pluginFailed),
            currentFrames: current.currentFrames)
        context = current
        if oldRecommendation != current.policy.recommendedFrames || oldMinimum != current.policy.minimumFrames {
            records[current.key] = Record(frames: current.policy.recommendedFrames,
                minimumFrames: current.policy.minimumFrames, updated: now)
            if records.count > 64 {
                records = Dictionary(uniqueKeysWithValues: records.sorted { $0.value.updated > $1.value.updated }.prefix(64).map { ($0.key, $0.value) })
            }
            if let data = try? JSONEncoder().encode(records) { persist(data) }
            publish()
        }
    }

    private func publish() {
        guard let context else { return }
        let value = Status(currentFrames: context.currentFrames, nextFrames: context.policy.recommendedFrames)
        if statuses[context.profileID] != value { statuses[context.profileID] = value }
    }
}
