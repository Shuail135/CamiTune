import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension DeviceCorrectionEditorView {
    func importResponse(
        _ result: Result<[URL], Error>,
        asTarget: Bool
    ) {
        do {
            guard let url = try result.get().first else { return }
            Task { @MainActor in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let imported = try await Task.detached(priority: .userInitiated) {
                        let text = try String(contentsOf: url, encoding: .utf8)
                        let response = try FrequencyResponseCSVImporter().parse(
                            text,
                            name: url.deletingPathExtension().lastPathComponent
                        )
                        return (response, Data(text.utf8))
                    }.value
                    let response = imported.0
                    if asTarget {
                        clearDeviceMatchTarget(clearSearch: true)
                        customTarget = response
                        targetSelection.preset = .custom
                        targetSelection.customTargetRigIdentity = nil
                    } else {
                        loadCoordinator.sourceGeneration &+= 1
                        isLoadingMeasurements = false
                        clearDeviceMatchTarget(clearSearch: true)
                        sourceMeasurements = [DeviceCorrectionMeasurement.local(
                            response: response,
                            originalData: imported.1
                        )]
                        measurement = response
                        deviceName = response.name
                        searchText = response.name
                        selectedCatalogID = "local:\(DeviceNameNormalizer.key(for: response.name))"
                    }
                    generated = nil
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generate() {
        guard let measurement, !isGenerating else { return }

        let capturedDeviceName = trimmedDeviceName
        let capturedMeasurement = measurement
        let capturedMeasurements = sourceMeasurements
        let capturedTargetSelection = targetSelection
        let capturedTargetSources = targetSources
        let capturedCustomTarget = customTarget
        let capturedDeviceMatchConsensus = deviceMatchConsensus
        let capturedPolicy = policy
        let capturedFilterCount = filterCount
        let capturedSampleRate = sampleRate
        let capturedExisting = existing

        isGenerating = true
        errorMessage = nil
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let engine = DeviceCorrectionEngine()
                    let resolution = try DeviceCorrectionTargetCatalog().resolve(
                        selection: capturedTargetSelection,
                        sources: capturedTargetSources,
                        customResponse: capturedCustomTarget,
                        deviceMatchConsensus: capturedDeviceMatchConsensus
                    )
                    if capturedMeasurements.isEmpty, let capturedExisting {
                        return try engine.generate(
                            deviceName: capturedDeviceName,
                            consensus: MeasurementConsensus(
                                response: capturedMeasurement,
                                confidence: capturedExisting.measurementConfidence,
                                sources: capturedExisting.sources,
                                snapshots: capturedExisting.measurementSnapshots
                            ),
                            target: resolution.response,
                            targetSelection: capturedTargetSelection,
                            policy: capturedPolicy,
                            filterCount: capturedFilterCount,
                            sampleRate: capturedSampleRate,
                            preservingID: capturedExisting.id,
                            preservingSources: capturedExisting.sources,
                            targetConfidence: resolution.confidence
                        )
                    }
                    return try engine.generate(
                        deviceName: capturedDeviceName,
                        measurements: capturedMeasurements,
                        target: resolution.response,
                        targetSelection: capturedTargetSelection,
                        policy: capturedPolicy,
                        filterCount: capturedFilterCount,
                        sampleRate: capturedSampleRate,
                        preservingID: capturedExisting?.id,
                        targetConfidence: resolution.confidence
                    )
                }
            }.value

            let inputsAreCurrent = trimmedDeviceName == capturedDeviceName
                && self.measurement == capturedMeasurement
                && sourceMeasurements == capturedMeasurements
                && targetSelection == capturedTargetSelection
                && customTarget == capturedCustomTarget
                && deviceMatchConsensus == capturedDeviceMatchConsensus
                && policy == capturedPolicy
                && filterCount == capturedFilterCount
            guard inputsAreCurrent else {
                isGenerating = false
                return
            }

            switch result {
            case .success(let correction):
                generated = correction
                generatedAutomaticHeadroomDB = automaticHeadroom(correction.filters)
                errorMessage = nil
            case .failure(let error):
                generated = nil
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    func loadIntoEqualizer() {
        guard var generated else { return }
        generated.deviceName = trimmedDeviceName
        generated.isEnabled = true
        onLoad(generated)
    }

    func requestLoadIntoEqualizer() {
        if shouldConfirmReplacement() {
            showingReplacementConfirmation = true
        } else {
            loadIntoEqualizer()
        }
    }

    func refreshMeasurements(from provenance: DeviceCorrectionProfile) {
        loadCoordinator.sourceGeneration &+= 1
        let loadGeneration = loadCoordinator.sourceGeneration
        isLoadingMeasurements = true
        errorMessage = nil
        let entry = DeviceCatalogEntry(
            displayName: provenance.deviceName,
            measurements: provenance.sources,
            identity: provenance.deviceIdentity
        )
        Task { @MainActor in
            do {
                let refreshedCatalog = try? await catalog.entries(refresh: true)
                let currentEntry = refreshedCatalog?.first {
                    $0.identity == provenance.deviceIdentity
                } ?? entry
                let loaded = try await catalog.measurements(
                    for: currentEntry,
                    refresh: true
                )
                guard loadCoordinator.sourceGeneration == loadGeneration else { return }
                let consensus = try await Task.detached(priority: .userInitiated) {
                    try MeasurementConsensusBuilder().build(
                        deviceName: provenance.deviceName,
                        measurements: loaded
                    )
                }.value
                let retainedSourceIDs = Set(consensus.sources.map(\.id))
                sourceMeasurements = loaded.filter {
                    retainedSourceIDs.contains($0.source.id)
                }
                measurement = consensus.response
                generated = nil
                isLoadingMeasurements = false
            } catch {
                guard loadCoordinator.sourceGeneration == loadGeneration else { return }
                errorMessage = "Measurements could not be refreshed: \(error.localizedDescription)"
                isLoadingMeasurements = false
            }
        }
    }

    @MainActor
    func loadCatalog() async {
        guard catalogEntries.isEmpty, !isLoadingCatalog else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            catalogEntries = try await catalog.entries()
        } catch {
            errorMessage = "Online device data is unavailable. You can still import a custom CSV."
        }
    }

    func select(_ entry: DeviceCatalogEntry) {
        loadCoordinator.sourceGeneration &+= 1
        let loadGeneration = loadCoordinator.sourceGeneration
        clearDeviceMatchTarget(clearSearch: true)
        deviceName = entry.displayName
        searchText = entry.displayName
        selectedCatalogID = entry.id
        sourceMeasurements = []
        measurement = nil
        generated = nil
        errorMessage = nil
        isLoadingMeasurements = true

        Task { @MainActor in
            do {
                let loaded = try await catalog.measurements(for: entry)
                guard loadCoordinator.sourceGeneration == loadGeneration,
                      selectedCatalogID == entry.id else { return }
                let consensus = try await Task.detached(priority: .userInitiated) {
                    try MeasurementConsensusBuilder().build(
                        deviceName: entry.displayName,
                        measurements: loaded
                    )
                }.value
                let retainedSourceIDs = Set(consensus.sources.map(\.id))
                sourceMeasurements = loaded.filter {
                    retainedSourceIDs.contains($0.source.id)
                }
                measurement = consensus.response
                errorMessage = nil
                isLoadingMeasurements = false
            } catch {
                guard loadCoordinator.sourceGeneration == loadGeneration,
                      selectedCatalogID == entry.id else { return }
                sourceMeasurements = []
                measurement = nil
                errorMessage = error.localizedDescription
                isLoadingMeasurements = false
            }
        }
    }

    func selectDeviceMatch(_ entry: DeviceCatalogEntry) {
        loadDeviceMatch(entry, refresh: false)
    }

    func refreshDeviceMatch() {
        guard let metadata = targetSelection.deviceMatchTarget else { return }
        let savedEntry = DeviceCatalogEntry(
            displayName: metadata.deviceName,
            measurements: metadata.sources,
            identity: metadata.deviceIdentity
        )
        let currentEntry = catalogEntries.first {
            $0.identity == metadata.deviceIdentity
        } ?? savedEntry
        loadDeviceMatch(currentEntry, refresh: true)
    }

    func loadDeviceMatch(
        _ entry: DeviceCatalogEntry,
        refresh: Bool
    ) {
        let compatibleReferences = DeviceMatchPlanner.compatibleReferences(
            in: entry,
            sourceReferences: targetSources
        )
        guard !compatibleReferences.isEmpty else {
            errorMessage = "The target device has no measurements using the source device's exact form and structured fixture calibration."
            return
        }
        guard entry.identity.stableKey != sourceDeviceIdentityKey else {
            errorMessage = "Choose a different target device for Device Match."
            return
        }

        let compatibleEntry = DeviceCatalogEntry(
            displayName: entry.displayName,
            measurements: compatibleReferences,
            identity: entry.identity
        )
        let previousConsensus = deviceMatchConsensus
        let previousMetadata = targetSelection.deviceMatchTarget
        loadCoordinator.deviceMatchGeneration &+= 1
        let loadGeneration = loadCoordinator.deviceMatchGeneration
        isLoadingDeviceMatch = true
        deviceMatchSearchText = entry.displayName
        selectedDeviceMatchCatalogID = entry.id
        if !refresh {
            deviceMatchConsensus = nil
            targetSelection.deviceMatchTarget = nil
        }
        generated = nil
        errorMessage = nil

        Task { @MainActor in
            do {
                let loaded = try await catalog.measurements(
                    for: compatibleEntry,
                    refresh: refresh
                )
                guard loadCoordinator.deviceMatchGeneration == loadGeneration,
                      selectedDeviceMatchCatalogID == entry.id else { return }
                let consensus = try await Task.detached(priority: .userInitiated) {
                    try MeasurementConsensusBuilder().build(
                        deviceName: entry.displayName,
                        measurements: loaded
                    )
                }.value
                guard DeviceMatchPlanner.isCompatible(
                    sourceReferences: targetSources,
                    targetReferences: consensus.sources
                ) else {
                    throw DeviceCorrectionTargetCatalog.TargetError.incompatibleDeviceMatchRig
                }
                deviceMatchConsensus = consensus
                targetSelection.deviceMatchTarget = DeviceMatchTargetMetadata(
                    deviceName: entry.displayName,
                    deviceIdentity: entry.identity,
                    measurementConfidence: consensus.confidence,
                    sources: consensus.sources,
                    measurementSnapshots: consensus.snapshots
                )
                errorMessage = nil
                isLoadingDeviceMatch = false
            } catch {
                guard loadCoordinator.deviceMatchGeneration == loadGeneration,
                      selectedDeviceMatchCatalogID == entry.id else { return }
                deviceMatchConsensus = refresh ? previousConsensus : nil
                targetSelection.deviceMatchTarget = refresh ? previousMetadata : nil
                selectedDeviceMatchCatalogID = refresh ? entry.id : nil
                errorMessage = "Target measurements could not be loaded: \(error.localizedDescription)"
                isLoadingDeviceMatch = false
            }
        }
    }

    func clearDeviceMatchTarget(clearSearch: Bool) {
        loadCoordinator.deviceMatchGeneration &+= 1
        if clearSearch { deviceMatchSearchText = "" }
        selectedDeviceMatchCatalogID = nil
        deviceMatchConsensus = nil
        targetSelection.deviceMatchTarget = nil
        isLoadingDeviceMatch = false
        generated = nil
    }
}
