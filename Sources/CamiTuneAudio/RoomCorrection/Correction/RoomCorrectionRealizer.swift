import CamiTuneDomain
import Foundation

struct RoomCorrectionRealizer {
    struct Output { var bands: [EQBand]; var impulse: [Float]? }
    func realize(_ plan: RoomChannelCorrectionPlan, method: RoomCorrectionMethod,
                 sampleRate: Double, settings: RoomCorrectionSettings) throws -> Output {
        switch method {
        case .auto, .iir: return .init(bands: plan.bands)
        case .fir:
            return .init(bands: [], impulse: try RoomFIRDesigner().design(bands: plan.bands, sampleRate: sampleRate, settings: settings))
        case .hybrid:
            // EQ exactly realizes the canonical parametric target. Its residual
            // is unity: creating another full-target FIR would double correction.
            return .init(bands: plan.bands)
        }
    }
}
