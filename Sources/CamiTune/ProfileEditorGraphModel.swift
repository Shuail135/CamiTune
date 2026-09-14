import Combine
import Foundation

/// The response shared by the spectrum panels and the equalizer editor.
/// Keeping it in a narrow observable object prevents band gestures from
/// invalidating the rest of the profile page.
@MainActor
final class ProfileEditorGraphModel: ObservableObject {
    @Published private(set) var responsePoints: [EQResponsePoint] = []
    private var calculationTask: Task<Void, Never>?

    func seed(profile: DeviceProfile, state: AppState) {
        let parsed: ParsedEQ
        do {
            let processing = try profile.resolvedProcessing()
            if let draft = state.eqDraft(for: profile.id) {
                parsed = try EqualizerAPOParser().parse(draft)
            } else if processing.deviceCorrection != nil {
                parsed = processing.globalEqualizerIncludingDeviceCorrection
            } else {
                parsed = processing.globalEqualizer
            }
        } catch {
            return
        }

        var combined = parsed
        if state.eqDraft(for: profile.id) != nil,
           !state.eqDraftReplacesDeviceCorrection(for: profile.id),
           let correction = profile.processing.deviceCorrection,
           correction.isEnabled {
            combined.bands.insert(contentsOf: correction.filters, at: 0)
        }
        let tone = state.toneDraft(for: profile.id) ?? profile.processing.simpleTone
        combined.bands += (try? SimpleToneFilterFactory.filters(for: tone, sampleRate: Double(profile.sampleRate))) ?? []
        calculate(parsed: combined, sampleRate: Double(profile.sampleRate))
    }

    func calculate(parsed: ParsedEQ, sampleRate: Double) {
        calculationTask?.cancel()
        calculationTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return
            }
            let points = await Task.detached(priority: .userInitiated) {
                EQResponseCalculator().calculate(
                    parsed: parsed,
                    sampleRate: sampleRate
                )
            }.value
            guard !Task.isCancelled else { return }
            responsePoints = points
        }
    }

    func cancel() {
        calculationTask?.cancel()
    }
}
