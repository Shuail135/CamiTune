import CamiTuneDomain
import Foundation

package struct RoomCorrectionDesign: Sendable {
    package var result: RoomCorrectionResult
    package var impulses: [Int: [Float]]
}

/// One approved transfer function per physical channel, independent of import mode.
/// The parametric basis defines the continuous target, including its real skirts.
struct RoomChannelCorrectionPlan: Sendable {
    var channel: Int
    var bands: [EQBand]
    var diagnostic: RoomCorrectionDiagnostic
}

package struct RoomCorrectionDesigner {
    package init() {}
    package func aggregate(session: RoomMeasurementSession, channel: Int) -> [RoomAnalysisPoint] {
        (try? RoomAnalysisEvidenceBuilder().build(session: session, channel: channel).points) ?? []
    }
    package func design(session: RoomMeasurementSession, settings: RoomCorrectionSettings) throws -> RoomCorrectionDesign {
        try session.validate()
        let rate = session.context.topology.sampleRate
        try settings.validate(sampleRate: rate)
        let policy = try RoomAnalysisPolicy.resolve(session.source)
        // New captures explicitly record which calibration was already subtracted.
        // Legacy observations remain usable under their saved session calibration.
        for observation in session.positions.flatMap(\.observations) {
            if let evidence = observation.captureEvidence, evidence.calibrationApplied != session.source.calibration {
                throw RoomCorrectionError.calibrationChanged
            }
        }
        let low = max(settings.lowHz ?? (policy == .calibrated ? 25 : 45), policy == .calibrated ? 20 : 45)
        let high = min(settings.highHz ?? (policy == .calibrated ? 800 : 300),
                       policy == .calibrated ? 20000 : 300, rate * 0.42)
        let method: RoomCorrectionMethod = settings.method == .auto ? .iir : settings.method
        var result = RoomCorrectionResult(sessionID: session.id, context: session.context, method: method,
            settings: settings, lowHz: low, highHz: high, positionCount: session.usablePositionCount)
        result.analysisPolicy = policy; result.channelDiagnostics = [:]
        var impulses: [Int: [Float]] = [:]
        guard low < high else { return .init(result: result, impulses: impulses) }
        for channel in session.context.topology.endpoints.map({ $0.id.channelIndex }).sorted() {
            try Task.checkCancellation()
            let evidence = try RoomAnalysisEvidenceBuilder().build(session: session, channel: channel)
            let fitted = try RoomCorrectionOptimizer().fit(evidence: evidence, policy: policy, settings: settings,
                rate: rate, low: low, high: high, channel: channel)
            let plan = RoomChannelCorrectionPlan(channel: channel, bands: fitted.bands, diagnostic: fitted.diagnostic)
            result.channelDiagnostics?[channel] = plan.diagnostic
            guard !plan.bands.isEmpty else { continue }
            let realized = try RoomCorrectionRealizer().realize(plan, method: method, sampleRate: rate, settings: settings)
            if !realized.bands.isEmpty { result.channelBands[channel] = realized.bands }
            if let impulse = realized.impulse { impulses[channel] = impulse }
        }
        return .init(result: result, impulses: impulses)
    }
}
