import CamiTuneDomain
import SwiftUI

/// Owns persistence/history and runtime apply; the control owns reusable presentation.
@MainActor
struct ConvolutionEditorView: View {
    @ObservedObject var state: AppState
    @Binding var profile: DeviceProfile
    var target: HistoryTarget? = nil
    var targetName = "Global"
    var showsTitle = true
    @State private var convolution: ConvolutionProcessor?
    @State private var isEnabled = false

    private var effectiveTarget: HistoryTarget { target ?? .profile(profile.id) }
    private var context: ConvolutionEditingContext {
        .init(target: effectiveTarget, sampleRate: profile.sampleRate, editGeneration: state.editGeneration,
            channels: profile.configuredProcessingChannels)
    }
    private var applicationDescription: String {
        switch effectiveTarget {
        case .profile:
            return profile.isPersonalListening
                ? "The same selected impulse response applies to both Left and Right."
                : "The same selected impulse response applies to all speakers."
        case .profileGroup:
            return "The same selected impulse response applies to every speaker in \(targetName)."
        default:
            return "The selected impulse response applies to \(targetName)."
        }
    }

    var body: some View {
        ConvolutionControl(title: showsTitle ? "FIR / Convolution" : nil, context: context,
            applicationDescription: applicationDescription,
            convolution: $convolution, isEnabled: $isEnabled, onCommit: commit,
            onError: { state.errorMessage = $0.localizedDescription })
        .onAppear { load() }
        .onChange(of: effectiveTarget) { _ in load() }
        .onChange(of: state.historyReplayRevision) { _ in load() }
        .disabled(state.isSavingProfileSettings || state.history.isReplaying)
    }

    private func load() {
        do {
            let saved = try state.convolutionHistoryState(for: effectiveTarget)
            convolution = saved.processor; isEnabled = saved.isEnabled
        } catch {
            convolution = nil; isEnabled = false
        }
    }

    private func commit() {
        do {
            try state.commitConvolution(.init(processor: convolution, isEnabled: isEnabled),
                target: effectiveTarget, name: targetName)
        } catch {
            state.errorMessage = error.localizedDescription
            load()
        }
    }
}
