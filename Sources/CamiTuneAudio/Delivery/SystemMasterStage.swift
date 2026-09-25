import Foundation

package final class SystemMasterGainControl: @unchecked Sendable {
    package init() {}
    package struct Snapshot {
        package init(revision: UInt64, linearGain: Float, muted: Bool) {
            self.revision = revision
            self.linearGain = linearGain
            self.muted = muted
        }

        package let revision: UInt64
        package let linearGain: Float
        package let muted: Bool
        package var effectiveGain: Float { muted ? 0 : linearGain }
    }

    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var linearGain: Float = 1
    private var muted = false

    package func set(linearGain: Float, muted: Bool) {
        let clamped = linearGain.isFinite ? min(1, max(0, linearGain)) : 1
        lock.lock()
        if self.linearGain != clamped || self.muted != muted {
            self.linearGain = clamped
            self.muted = muted
            revision &+= 1
        }
        lock.unlock()
    }

    package func snapshot() -> Snapshot {
        lock.lock()
        let value = Snapshot(revision: revision, linearGain: linearGain, muted: muted)
        lock.unlock()
        return value
    }
}

/// Writer-owned ramp history. Queue recovery never resets the user's master gain.
package final class SystemMasterStage {
    private let systemMaster: SystemMasterGainControl
    private var masterRevision: UInt64 = UInt64.max
    private var currentMasterGain: Float = 1
    private var targetMasterGain: Float = 1
    private var masterRampFramesRemaining = 0
    private var masterRampStep: Float = 0

    package init(control: SystemMasterGainControl) {
        self.systemMaster = control
        let initialMaster = control.snapshot()
        masterRevision = initialMaster.revision
        currentMasterGain = initialMaster.effectiveGain
        targetMasterGain = initialMaster.effectiveGain
    }

    package func process(
        to samples: inout [Float],
        channelCount: Int,
        sampleRate: Double
    ) {
        guard channelCount > 0, sampleRate > 0, !samples.isEmpty else { return }
        let snapshot = systemMaster.snapshot()
        if snapshot.revision != masterRevision {
            masterRevision = snapshot.revision
            targetMasterGain = snapshot.effectiveGain
            // 8 ms is fast enough for a single keyboard tap to feel immediate,
            // but still prevents a discontinuity at a PCM block boundary.
            masterRampFramesRemaining = max(1, Int(sampleRate * 0.008))
            masterRampStep = (targetMasterGain - currentMasterGain)
                / Float(masterRampFramesRemaining)
        }

        let frameCount = samples.count / channelCount
        guard frameCount > 0 else { return }
        if masterRampFramesRemaining == 0 {
            currentMasterGain = targetMasterGain
            if currentMasterGain == 1 { return }
            for index in samples.indices { samples[index] *= currentMasterGain }
            return
        }

        for frame in 0..<frameCount {
            if masterRampFramesRemaining > 0 {
                currentMasterGain += masterRampStep
                masterRampFramesRemaining -= 1
                if masterRampFramesRemaining == 0 {
                    currentMasterGain = targetMasterGain
                }
            }
            let base = frame * channelCount
            for channel in 0..<channelCount {
                samples[base + channel] *= currentMasterGain
            }
        }
    }
}
