import Foundation

package struct PCMProducerDrainStatistics: Sendable, Codable, Equatable {
    package init(completedDrains: UInt64 = 0, resamplerTailFrames: UInt64 = 0, backendPaddingFrames: UInt64 = 0) {
        self.completedDrains = completedDrains
        self.resamplerTailFrames = resamplerTailFrames
        self.backendPaddingFrames = backendPaddingFrames
    }

    package var completedDrains: UInt64 = 0
    package var resamplerTailFrames: UInt64 = 0
    package var backendPaddingFrames: UInt64 = 0
}

package struct PCMDeliveryStatistics: Sendable {
    package init(droppedFrames: UInt64 = 0, recoveries: UInt64 = 0, writeFailures: UInt64 = 0, adjustmentPPM: Double = 0, bufferedFrames: UInt64 = 0, error: String? = nil, drains: PCMProducerDrainStatistics = PCMProducerDrainStatistics()) {
        self.droppedFrames = droppedFrames
        self.recoveries = recoveries
        self.writeFailures = writeFailures
        self.adjustmentPPM = adjustmentPPM
        self.bufferedFrames = bufferedFrames
        self.error = error
        self.drains = drains
    }

    package var droppedFrames: UInt64 = 0
    package var recoveries: UInt64 = 0
    package var writeFailures: UInt64 = 0
    package var adjustmentPPM: Double = 0
    package var bufferedFrames: UInt64 = 0
    package var error: String?
    package var drains = PCMProducerDrainStatistics()


}
