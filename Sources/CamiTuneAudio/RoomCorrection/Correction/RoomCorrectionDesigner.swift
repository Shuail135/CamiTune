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
        let low = max(settings.lowHz ?? (policy == .calibrated ? 20 : 45), policy == .calibrated ? 20 : 45)
        let high = min(settings.highHz ?? (policy == .calibrated ? 800 : 300),
                       policy == .calibrated ? 20000 : 300, rate * 0.42)
        let method: RoomCorrectionMethod = [.auto, .hybrid].contains(settings.method) ? .iir : settings.method
        var result = RoomCorrectionResult(sessionID: session.id, context: session.context, method: method,
            settings: settings, lowHz: low, highHz: high, positionCount: session.usablePositionCount)
        result.analysisPolicy = policy; result.channelDiagnostics = [:]
        result.measurementIdentity = .init(session: session)
        var impulses: [Int: [Float]] = [:]
        var plans: [RoomChannelCorrectionPlan] = []
        result.predictions = [:]
        guard low < high else { return .init(result: result, impulses: impulses) }
        for channel in session.context.topology.endpoints.map({ $0.id.channelIndex }).sorted() {
            try Task.checkCancellation()
            let evidence = try RoomAnalysisEvidenceBuilder().build(session: session, channel: channel, settings: settings)
            let channelHigh = session.context.topology.endpoints.first { $0.id.channelIndex == channel }?.isSubwooferLike == true ? min(high, 160) : high
            let fitted = try RoomCorrectionOptimizer().fit(evidence: evidence, policy: policy, settings: settings,
                rate: rate, low: low, high: channelHigh, channel: channel)
            let plan = RoomChannelCorrectionPlan(channel: channel, bands: fitted.bands, diagnostic: fitted.diagnostic)
            result.channelDiagnostics?[channel] = plan.diagnostic
            plans.append(plan)
            let calculator = EQResponseCalculator()
            result.predictions?[channel] = evidence.points.map { point in
                .init(frequency: point.frequency, measuredDB: point.mainDB, targetDB: point.referenceDB,
                      correctedDB: point.mainDB + calculator.gainDB(at: point.frequency,
                        parsed: .init(preampDB: 0, bands: plan.bands), sampleRate: rate), reliability: point.reliability)
            }
        }
        guard plans.contains(where: { !$0.bands.isEmpty }) else { return .init(result: result, impulses: [:]) }
        if method == .fir {
            // One length/delay for the entire output set. A flat channel still
            // needs the same intentional delay as its corrected neighbours.
            var realized = false
            for length in RoomFIRDesigner.lengths(sampleRate: rate, settings: settings) {
                var attempt = settings; attempt.filterLength = length
                var candidate: [Int: [Float]] = [:]
                do {
                    for plan in plans where !plan.bands.isEmpty || settings.phase != .minimum {
                        candidate[plan.channel] = try RoomFIRDesigner().design(bands: plan.bands, sampleRate: rate, settings: attempt)
                    }
                    impulses = candidate; realized = true
                    result.addedDelayMS = settings.phase == .minimum ? 0 : Double(length / 2) / rate * 1000
                    break
                } catch RoomCorrectionError.filterAccuracy {
                    if settings.filterLength != nil { throw RoomCorrectionError.filterAccuracy }
                }
            }
            guard realized else { throw RoomCorrectionError.filterAccuracy }
        } else {
            for plan in plans where !plan.bands.isEmpty {
                result.channelBands[plan.channel] = try RoomCorrectionRealizer().realize(plan, method: method, sampleRate: rate, settings: settings).bands
            }
            result.addedDelayMS = 0
        }
        return .init(result: result, impulses: impulses)
    }
}

/// Compare fresh, repeated calibrated captures against the approved response.
/// A broadband level offset is removed; frequency-dependent errors remain.
package enum RoomCorrectionVerification {
    package static func evaluate(baseline: RoomMeasurementSession, measured: RoomMeasurementSession,
                                 result: RoomCorrectionResult) throws -> RoomCorrectionVerificationReport {
        try baseline.validate(); try measured.validate()
        let channels = result.context.topology.endpoints.map { $0.id.channelIndex }
        guard baseline.id == result.sessionID, result.measurementIdentity == .init(session: baseline),
              measured.id != baseline.id, measured.source == baseline.source,
              baseline.source.kind == .microphone, baseline.source.calibration != nil,
              measured.requiresRepeatedPositions == true, measured.microphoneMeasurementsComplete,
              baseline.context.canReprocess(to: result.context),
              let imported = result.importedChannelChains, Set(imported.keys) == Set(channels) else {
            throw RoomCorrectionError.invalidSession
        }
        var expectedContext = result.context
        expectedContext.processing.channels = result.context.topology.endpoints.map { endpoint in
            .init(index: endpoint.id.channelIndex, role: endpoint.role, chain: imported[endpoint.id.channelIndex]!)
        }.sorted { $0.index < $1.index }
        guard measured.context == expectedContext else { throw RoomCorrectionError.stale }
        for observation in (baseline.positions + measured.positions).flatMap(\.observations) {
            if let evidence = observation.captureEvidence, evidence.calibrationApplied != baseline.source.calibration {
                throw RoomCorrectionError.calibrationChanged
            }
        }
        let evidence = try Dictionary(uniqueKeysWithValues: channels.map { channel in
            (channel, try RoomAnalysisEvidenceBuilder().build(session: baseline, channel: channel, settings: result.settings))
        })
        var worst = 0.0, compared = 0, passed = true
        for position in baseline.positions where !position.skipped {
            guard let fresh = measured.positions.first(where: { $0.id == position.id && $0.coordinate == position.coordinate && !$0.skipped }) else {
                passed = false; continue
            }
            for channel in channels {
                guard let original = position.observations.first(where: { $0.channel == channel }),
                      let observation = fresh.observations.first(where: { $0.channel == channel }),
                      observation.repeatDifferenceDB != nil,
                      let prediction = result.predictions?[channel], let channelEvidence = evidence[channel],
                      let seat = channelEvidence.seats.first(where: { $0.id == position.id }) else { passed = false; continue }
                let originals = Dictionary(uniqueKeysWithValues: original.bins.map { ($0.frequency, $0) })
                let predictions = Dictionary(uniqueKeysWithValues: prediction.map { ($0.frequency, $0) })
                let indices = Dictionary(uniqueKeysWithValues: channelEvidence.points.enumerated().map { ($0.element.frequency, $0.offset) })
                let freshBins = Dictionary(uniqueKeysWithValues: observation.bins.map { ($0.frequency, $0) })
                let expectedBins = prediction.filter { point in
                    guard let i = indices[point.frequency], let old = originals[point.frequency] else { return false }
                    return point.reliability > 0.4 && seat.quality[i] > 0.4 && old.snrDB > 20
                        && (result.lowHz...result.highHz).contains(point.frequency)
                }
                // Missing/noisy coverage cannot certify the bands being corrected.
                for point in expectedBins where abs(point.correctedDB - point.measuredDB) > 0.35 {
                    if let fresh = freshBins[point.frequency], fresh.reliability > 0.4, fresh.snrDB > 20 { continue }
                    passed = false
                }
                let pairs = observation.bins.compactMap { bin -> (Double, Double, Double)? in
                    guard bin.reliability > 0.4, bin.snrDB > 20,
                          let old = originals[bin.frequency], old.reliability > 0.4, old.snrDB > 20,
                          let expected = predictions[bin.frequency], expected.reliability > 0.4,
                          let i = indices[bin.frequency], seat.quality[i] > 0.4,
                          (result.lowHz...result.highHz).contains(bin.frequency) else { return nil }
                    let correction = expected.correctedDB - expected.measuredDB
                    return (bin.magnitudeDB - old.magnitudeDB - correction,
                            seat.excess[i], correction)
                }
                guard pairs.count >= 24, Double(pairs.count) >= Double(expectedBins.count) * 0.9 else { passed = false; continue }
                let residuals = pairs.map { $0.0 }.sorted(), offset = residuals[residuals.count / 2]
                let error = sqrt(pairs.reduce(0) { $0 + pow($1.0 - offset, 2) } / Double(pairs.count))
                let before = pairs.reduce(0) { $0 + pow($1.1, 2) } / Double(pairs.count)
                let after = pairs.reduce(0) { $0 + pow($1.1 + $1.2 + $1.0 - offset, 2) } / Double(pairs.count)
                // Agreement with prediction AND no material target regression.
                let outliers = pairs.filter { abs($0.0 - offset) > 2 }.count
                passed = passed && error <= 1 && outliers <= pairs.count / 10 && after <= before + 0.5
                worst = max(worst, error); compared += 1
            }
        }
        passed = passed && compared >= channels.count * 3
        return .init(sessionID: measured.id, passed: passed, comparedResponses: compared,
            worstPredictionErrorDB: worst,
            reason: passed ? "Verified at the measured positions: the applied response agrees with prediction within 1 dB RMS and does not materially worsen the target error."
                : "Verification did not pass. Check microphone placement, calibration, background noise and the active filters before relying on this correction.")
    }
}
