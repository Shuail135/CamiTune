import Foundation

struct SpatialCalibrationContext: Identifiable, Equatable, Sendable {
    let id: UUID
    let runtimeSessionID: UUID
    let profileID: UUID
    let outputDeviceUID: String
    let sampleRate: Double
}
