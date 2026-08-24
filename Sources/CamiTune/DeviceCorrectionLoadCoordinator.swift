import Combine

/// Non-visual cancellation generations for async device-correction loads.
/// These deliberately are not @Published: changing a generation token should
/// not invalidate the SwiftUI editor hierarchy.
@MainActor
final class DeviceCorrectionLoadCoordinator: ObservableObject {
    var sourceGeneration: UInt64 = 0
    var deviceMatchGeneration: UInt64 = 0
}
