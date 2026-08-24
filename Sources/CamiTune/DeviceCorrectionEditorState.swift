import Foundation
import SwiftUI

@MainActor
extension DeviceCorrectionEditorView {
    var trimmedDeviceName: String {
        deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var searchResults: [DeviceCatalogEntry] {
        DeviceCatalogSearch.results(in: catalogEntries, matching: searchText)
    }

    var deviceMatchSearchResults: [DeviceCatalogEntry] {
        DeviceCatalogSearch.results(
            in: catalogEntries,
            matching: deviceMatchSearchText,
            limit: max(40, catalogEntries.count)
        ).filter { entry in
            entry.identity.stableKey != sourceDeviceIdentityKey
                && !DeviceMatchPlanner.compatibleReferences(
                    in: entry,
                    sourceReferences: targetSources
                ).isEmpty
        }.prefix(40).map { $0 }
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
            generated = nil
        })
    }

    var filterCountBinding: Binding<Int> {
        Binding(get: { filterCount }, set: {
            filterCount = $0
            generated = nil
        })
    }

    var targetPresetBinding: Binding<DeviceCorrectionTargetPreset> {
        Binding(get: { targetSelection.preset }, set: {
            if $0 != .deviceMatch {
                clearDeviceMatchTarget(clearSearch: true)
            }
            targetSelection.preset = $0
            generated = nil
            errorMessage = nil
        })
    }

    var targetTiltBinding: Binding<Double> {
        Binding(get: { targetSelection.tiltDBPerOctave }, set: {
            targetSelection.tiltDBPerOctave = min(1, max(-2, $0))
            generated = nil
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
                generated = nil
                errorMessage = nil
            }
        )
    }

    var targetSources: [DeviceMeasurementReference] {
        if !sourceMeasurements.isEmpty { return sourceMeasurements.map(\.source) }
        return existing?.sources ?? []
    }

    var targetCompatibilityMessage: String {
        DeviceCorrectionTargetCatalog().compatibilityMessage(
            for: targetSelection,
            sources: targetSources,
            deviceMatchSources: deviceMatchSources
        )
    }

    var targetIsIncompatible: Bool {
        if targetSelection.preset == .deviceMatch {
            guard targetSelection.deviceMatchTarget != nil else { return false }
            return !DeviceMatchPlanner.isCompatible(
                sourceReferences: targetSources,
                targetReferences: deviceMatchSources
            )
        }
        let measurementFamily = DeviceCorrectionRigFamily.identify(from: targetSources)
        if targetSelection.preset == .custom,
           let targetFamily = targetSelection.customTargetRigIdentity?.family,
           measurementFamily != .unknown,
           targetFamily != measurementFamily {
            return true
        }
        guard measurementFamily == .bk5128 else {
            return false
        }
        return [.harmanInEar2019V2, .iefNeutral2023, .etymotic]
            .contains(targetSelection.preset)
    }

    var policyExplanation: String {
        switch policy {
        case .recommended:
            return "Uses frequency-dependent confidence, stronger cut limits, restrained boosts, and smoothing to avoid correcting unreliable narrow features."
        case .exactTarget:
            return "Tracks the selected target more closely with wider gain limits. Use this only with a measurement you trust."
        }
    }

}
