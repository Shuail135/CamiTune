import CamiTuneDomain
import Foundation
import SwiftUI

@MainActor
extension DeviceCorrectionEditorView {
    func restoreDraft(_ snapshot: AutoEQEditorDraft) {
        loadCoordinator.sourceGeneration &+= 1
        loadCoordinator.deviceMatchGeneration &+= 1
        isGenerating = false; isLoadingMeasurements = false; isLoadingDeviceMatch = false
        deviceName = snapshot.deviceName; searchText = snapshot.searchText
        selectedCatalogID = snapshot.selectedCatalogID
        sourceMeasurements = snapshot.sourceMeasurements; measurement = snapshot.measurement
        policy = snapshot.policy; autoEQSettings = snapshot.settings
        targetChosen = snapshot.targetChosen; targetSelection = snapshot.targetSelection
        customTarget = snapshot.customTarget
        deviceMatchSearchText = snapshot.deviceMatchSearchText
        selectedDeviceMatchCatalogID = snapshot.selectedDeviceMatchCatalogID
        deviceMatchConsensus = snapshot.deviceMatchConsensus
        generated = snapshot.generated; generatedAutomaticHeadroomDB = snapshot.automaticHeadroomDB
    }

    var trimmedDeviceName: String {
        deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var sourceSearchRequest: DeviceCatalogSearch.Request {
        .init(query: selectedCatalogID == nil ? searchText : "", indexID: searchIndex.id)
    }

    var matchSearchRequest: DeviceCatalogSearch.Request {
        .init(query: selectedDeviceMatchCatalogID == nil ? deviceMatchSearchText : "", indexID: searchIndex.id,
              compatibleKeys: Set(targetSources.map(\.compatibilityKey)), excludedIdentity: sourceDeviceIdentityKey)
    }

    func updateSearch(_ request: DeviceCatalogSearch.Request, deviceMatch: Bool = false) async {
        let index = searchIndex
        do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
        let results = await Task.detached(priority: .userInitiated) {
            index.results(matching: request.query, compatibleKeys: request.compatibleKeys, excluding: request.excludedIdentity)
        }.value
        guard !Task.isCancelled else { return }
        if deviceMatch { deviceMatchSearchResults = results } else { searchResults = results }
    }

    var sourceDeviceIdentityKey: String? {
        sourceMeasurements.compactMap(\.source.deviceIdentity).first?.stableKey
            ?? existing?.deviceIdentity.stableKey
    }

    var deviceMatchSources: [DeviceMeasurementReference] {
        deviceMatchConsensus?.sources
            ?? targetSelection.deviceMatchTarget?.sources
            ?? []
    }

    var policyBinding: Binding<DeviceCorrectionPolicyKind> {
        Binding(get: { policy }, set: {
            policy = $0
            if policy == .exactTarget, var modifiers = targetSelection.modifiers {
                modifiers.bassGainDB = 0
                targetSelection.modifiers = modifiers
            }
        })
    }

    func targetTitle(_ preset: DeviceCorrectionTargetPreset) -> String {
        let sources = resultIsCurrent ? (generated?.sources ?? targetSources) : targetSources
        return DeviceCorrectionTargetCatalog().displayName(for: preset, sources: sources, paths: preset == .neutral ? loadCoordinator.targetPaths(for: sources) : [])
    }

    var availableTargets: [DeviceCorrectionTargetPreset] {
        guard measurement != nil else { return [] }
        let valid = Set(loadCoordinator.targetPaths(for: targetSources).map(\.target))
        var result = DeviceCorrectionTargetPreset.allCases.filter { valid.contains($0) }
        if customTarget != nil, let rig = targetSelection.customTargetRigIdentity,
           !targetSources.isEmpty, targetSources.allSatisfy({ $0.resolvedRigIdentity == rig }) { result.append(.custom) }
        if hasCompatibleDeviceMatch {
            result.append(.deviceMatch)
        }
        return Self.uniqueTargetsInOriginalOrder(result,
            selected: targetChosen ? targetSelection.preset : nil, title: targetTitle)
    }

    static func uniqueTargetsInOriginalOrder(
        _ presets: [DeviceCorrectionTargetPreset],
        selected: DeviceCorrectionTargetPreset?,
        title: (DeviceCorrectionTargetPreset) -> String
    ) -> [DeviceCorrectionTargetPreset] {
        var result: [DeviceCorrectionTargetPreset] = []
        var positions: [String: Int] = [:]
        for preset in presets {
            let label = title(preset)
            if let position = positions[label] {
                // Preserve a saved alias without moving its label in the menu.
                if preset == selected { result[position] = preset }
            } else {
                positions[label] = result.count
                result.append(preset)
            }
        }
        return result
    }

    var targetHelpMessage: String {
        guard measurement != nil else {
            return "Choose a device or import a measurement to see explanations of the available targets. A target is the sound balance Auto EQ aims for."
        }
        let targets = availableTargets
        guard !targets.isEmpty else {
            return "No compatible target is available for these measurements. If you imported a measurement, choose its measurement fixture first."
        }
        let explanations = targets.map { preset in
            let title = targetTitle(preset)
            let describedPreset = preset == .neutral
                ? DeviceCorrectionTargetPreset.allCases.first { $0 != .neutral && $0.title == title } ?? preset
                : preset
            return "\(title): \(describedPreset.shortDescription)"
        }
        return (["A target is the sound balance Auto EQ aims for."] + explanations)
            .joined(separator: "\n")
    }

    func updateDeviceMatchAvailability() {
        let keys = Set(targetSources.map(\.compatibilityKey))
        let savedMatchIsCompatible = targetSelection.deviceMatchTarget.map { target in
            target.deviceIdentity.stableKey != sourceDeviceIdentityKey
                && deviceMatchSources.contains { keys.contains($0.compatibilityKey) }
        } ?? false
        hasCompatibleDeviceMatch = savedMatchIsCompatible
            || searchIndex.hasCompatibleDevice(keys: keys, excluding: sourceDeviceIdentityKey)
    }

    var compatibleTargetBinding: Binding<DeviceCorrectionTargetPreset?> {
        Binding(get: { targetChosen && availableTargets.contains(targetSelection.preset) ? targetSelection.preset : nil }, set: { value in
            targetChosen = value != nil
            if let value { targetSelection.preset = value }
        })
    }

    func reconcileTargetSelection() {
        if targetChosen && availableTargets.contains(targetSelection.preset) { return }
        if let preset = TargetCompatibilityEngine().preferredTarget(sources: targetSources) {
            targetSelection.preset = preset
            targetChosen = true
        } else {
            targetChosen = false
        }
    }

    var targetTiltBinding: Binding<Double> {
        Binding(get: { targetSelection.tiltDBPerOctave }, set: {
            targetSelection.tiltDBPerOctave = min(1, max(-2, $0))
            errorMessage = nil
        })
    }

    var customTargetRigFamilyBinding: Binding<DeviceCorrectionRigFamily?> {
        Binding(
            get: { targetSelection.customTargetRigIdentity?.family },
            set: { family in
                targetSelection.customTargetRigIdentity = family.map { selectedFamily in
                    targetSources.lazy.map(\.resolvedRigIdentity).first {
                        $0.family == selectedFamily
                    } ?? MeasurementRigIdentity.canonical(for: selectedFamily)
                }
                targetChosen = availableTargets.contains(.custom)
                errorMessage = nil
            }
        )
    }

    var targetSources: [DeviceMeasurementReference] {
        if !sourceMeasurements.isEmpty { return sourceMeasurements.map(\.source) }
        return existing?.sources ?? []
    }

    var resultIsCurrent: Bool {
        generated?.targetSelection == targetSelection && generated?.policy == policy && generated?.autoEQSettings == autoEQSettings
    }

    var correctionIsLoaded: Bool {
        guard let generated, resultIsCurrent else { return false }
        return equalizerState?.matchesAutoEQ(generated) == true
    }

    var targetIsIncompatible: Bool {
        !targetChosen || !availableTargets.contains(targetSelection.preset)
    }

    var sourceRigBinding: Binding<DeviceCorrectionRigFamily?> {
        Binding(get: { sourceMeasurements.first?.source.rigIdentity?.family }, set: { family in
            guard let family else { return }
            for index in sourceMeasurements.indices {
                sourceMeasurements[index].source.rigIdentity = .canonical(for: family)
                sourceMeasurements[index].source.form = catalogIsIEM ? "in-ear" : "over-ear"
            }
            reconcileTargetSelection()
        })
    }

    func modifierBinding(_ keyPath: WritableKeyPath<TargetModifiers, Double>) -> Binding<Double> {
        Binding(get: { (targetSelection.modifiers ?? .init())[keyPath: keyPath] }, set: { value in
            var modifiers = targetSelection.modifiers ?? .init()
            modifiers[keyPath: keyPath] = value
            targetSelection.modifiers = modifiers
        })
    }

}

extension GlobalEQHistoryState {
    func matchesAutoEQ(_ correction: DeviceCorrectionProfile) -> Bool {
        guard deviceCorrectionProvenance?.id == correction.id, preampDB == 0 else { return false }
        let serializer = EqualizerAPOSerializer()
        func values(_ filters: [EQBand]) -> [String] {
            filters.map { serializer.serialize(.init(preampDB: 0, bands: [$0])) }.sorted()
        }
        return values(bands) == values(correction.filters)
    }
}

@MainActor
extension DeviceCorrectionEditorView {
    var persistentDraft: AutoEQEditorDraft {
        .init(sampleRate: sampleRate, reference: existing, deviceName: deviceName,
            searchText: searchText, selectedCatalogID: selectedCatalogID,
            sourceMeasurements: sourceMeasurements, measurement: measurement,
            policy: policy, settings: autoEQSettings, targetChosen: targetChosen,
            targetSelection: targetSelection, customTarget: customTarget,
            deviceMatchSearchText: deviceMatchSearchText,
            selectedDeviceMatchCatalogID: selectedDeviceMatchCatalogID,
            deviceMatchConsensus: deviceMatchConsensus, generated: generated,
            automaticHeadroomDB: generatedAutomaticHeadroomDB,
            presentation: presentation)
    }
}
