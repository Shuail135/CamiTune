import CamiTuneDomain
import SwiftUI
import UniformTypeIdentifiers

struct ConvolutionEditingContext: Hashable {
    let target: HistoryTarget
    let sampleRate: Int
    let editGeneration: UInt64
    let channels: [ConfiguredProcessingChannel]
}

/// The file access and analysis lifetime is independent of the editor's DSP target.
@MainActor
struct ConvolutionImporter: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var isImporting: Bool
    let context: ConvolutionEditingContext
    let onImported: @MainActor (ImpulseResponseAsset) -> Void
    let onError: @MainActor (Error) -> Void
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: ImpulseResponseStore.fileExtensions.compactMap {
            UTType(filenameExtension: $0, conformingTo: .audio)
        }, allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                task?.cancel()
                let sampleRate = context.sampleRate
                isImporting = true
                task = Task {
                    let imported = await Task.detached(priority: .userInitiated) {
                        Result {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            return try ImpulseResponseStore().importWAV(at: url, expectedSampleRate: sampleRate)
                        }
                    }.value
                    guard !Task.isCancelled else { return }
                    isImporting = false
                    switch imported {
                    case .success(let asset): onImported(asset)
                    case .failure(let error): onError(error)
                    }
                }
            } catch { onError(error) }
        }
        .onChange(of: context) { _ in cancel() }
        .onDisappear { cancel() }
    }

    private func cancel() {
        task?.cancel(); task = nil
        isImporting = false; isPresented = false
    }
}
