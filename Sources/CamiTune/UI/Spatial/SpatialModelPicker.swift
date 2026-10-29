import CamiTuneDomain
import SwiftUI

@MainActor
struct SpatialDevicePicker: View {
    let endpoint: ProfileEndpointKind
    let genericName: String
    var current: SpatialPlaybackDevice? = nil
    let choose: (SpatialPlaybackDevice?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = AutoEQCatalogSearchIndex<DeviceCatalogEntry>(entries: [], name: { $0.displayName })
    @State private var loading = false
    @State private var error: String?
    @State private var pending: String?
    @State private var selection: MeasurementChoice?
    @State private var editingType = false
    @State private var selectionTask: Task<Void, Never>?

    private struct MeasurementChoice {
        let entry: DeviceCatalogEntry
        let measurements: [DeviceCorrectionMeasurement]
        let paths: [CorrectionPath]
        var target: DeviceCorrectionTargetPreset?
        var device: SpatialPlaybackDevice
        var path: CorrectionPath? { paths.first { $0.target == target } }
        var canCorrect: Bool { path.map { device.resolvedType.supportsCorrection(from: $0.sources) } ?? false }
    }

    var body: some View {
        let results = index.results(matching: query)
        VStack(alignment: .leading, spacing: 14) {
            Text(endpoint == .iem ? "Choose earphones" : "Choose headphones").font(.title3.bold())
            AutoEQSearchField(placeholder: "Search AutoEq models", query: $query,
                results: results, title: { $0.displayName }) { select($0) }
            if loading { ProgressView().controlSize(.small) }
            if !loading, error == nil, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, results.isEmpty {
                Text("No matching models. Try a brand or a shorter model name.").font(.caption).foregroundStyle(.secondary)
            }
            if let pending { Text(pending).font(.caption).foregroundStyle(.secondary) }
            if let selection {
                selectionDetails(selection).disabled(pending != nil)
            }
            Text("Model correction applies only to Spatial audio. Fine-tune lets you adjust its strength.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if index.isEmpty { Button("Retry catalog") { Task { await load() } } }
            }
            HStack {
                Button("Use \(genericName)") {
                    selectionTask?.cancel()
                    choose(.init(name: genericName, source: "Generic", typeOverride: current?.resolvedType))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                if selection != nil {
                    Button("Use without correction") { apply(correction: false) }.disabled(pending != nil)
                }
                Button("Apply correction") { apply(correction: true) }
                    .disabled(selection?.canCorrect != true || pending != nil)
                    .uiInteractionAnchor("spatial-device-apply")
            }
        }.padding(20).frame(width: 540)
            .task { await load() }.onDisappear { selectionTask?.cancel() }
    }

    @ViewBuilder private func selectionDetails(_ choice: MeasurementChoice) -> some View {
        Text(choice.entry.displayName).fontWeight(.medium)
        HStack {
            Text(choice.device.resolvedType.summary).foregroundStyle(.secondary)
            Spacer()
            Button("Change type…") { editingType.toggle() }
        }
        Text(choice.device.typeProvenance).font(.caption).foregroundStyle(.secondary)
        if let evidence = choice.device.verifiedType, let url = URL(string: evidence.sourceURL) {
            Link("Model specifications", destination: url).font(.caption)
        }
        if editingType || choice.device.resolvedType.needsDetails {
            SpatialDeviceTypeControls(type: Binding(get: { selection?.device.resolvedType ?? .init() },
                set: { selection?.device.typeOverride = $0 }))
        }
        if let path = choice.path {
            Picker("Correction reference", selection: Binding(get: { choice.target }, set: { selection?.target = $0 })) {
                ForEach([DeviceCorrectionTargetPreset.diffuseFieldReference, .neutral].filter { target in choice.paths.contains { $0.target == target } }, id: \.self) { target in
                    Text(DeviceCorrectionTargetCatalog().displayName(for: target,
                        sources: choice.paths.first { $0.target == target }!.sources)).tag(Optional(target))
                }
            }
            Text("\(path.sources.count) compatible measurement(s) · \(path.sources.first?.resolvedRigIdentity.family.title ?? "Unknown fixture")")
                .font(.caption).foregroundStyle(.secondary)
            if !choice.canCorrect {
                Text("This measurement does not match your selected wearing type. You can use the model without correction.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(choice.target == .diffuseFieldReference
                    ? "A fixture-matched diffuse-field baseline for binaural listening. Your ear shape and fit can still change the result."
                    : "A published neutral baseline for this measurement fixture. You can adjust its strength in Fine-tune.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("A compatible correction reference is not available for these measurements. You can still identify this model and use generic spatial rendering.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load() async {
        loading = true; error = nil
        do {
            let entries = try await DeviceMeasurementCatalog.online.entries()
            try Task.checkCancellation()
            index = .init(entries: ReferenceCorrection.catalog(entries, endpoint: endpoint), name: { $0.displayName })
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        loading = false
    }
    private func select(_ entry: DeviceCatalogEntry) {
        selectionTask?.cancel(); selection = nil; editingType = false; pending = "Loading \(entry.displayName)…"; error = nil
        selectionTask = Task {
            do {
                let measurements = try await DeviceMeasurementCatalog.online.measurements(for: entry)
                let paths = try await Task.detached(priority: .userInitiated) { try SpatialHeadphoneCorrection.paths(measurements: measurements) }.value
                try Task.checkCancellation()
                selection = .init(entry: entry, measurements: measurements, paths: paths, target: paths.first?.target,
                    device: SpatialHeadphoneCorrection.describe(entry))
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { pending = nil }
        }
    }
    private func apply(correction: Bool) {
        guard let selection else { return }
        if !correction { choose(selection.device); return }
        guard let target = selection.target, selection.canCorrect else { return }
        selectionTask?.cancel(); pending = "Preparing correction…"; error = nil
        selectionTask = Task {
            do {
                var value = try await Task.detached(priority: .userInitiated) {
                    try SpatialHeadphoneCorrection.prepare(entry: selection.entry, measurements: selection.measurements, target: target)
                }.value
                try Task.checkCancellation()
                value.typeOverride = selection.device.typeOverride
                try value.validate()
                choose(value)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { pending = nil }
        }
    }
}

@MainActor
private struct SpatialDeviceTypeControls: View {
    @Binding var type: SpatialDeviceType
    var body: some View {
        Picker("How do you wear it?", selection: Binding(get: { type.form }, set: {
            type = .init(form: $0, enclosure: type.enclosure)
        })) {
            Text("Not sure").tag(DeviceForm?.none)
            ForEach(DeviceForm.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
        }
        if type.form?.hasEnclosure == true {
            Picker("Earcup design", selection: $type.enclosure) {
                ForEach(HeadphoneEnclosure.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("Open backs let sound pass through the outside of the earcups. Closed backs enclose the earcups.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if type.form == .boneConduction {
            Text("The current spatial profile is measured for air-conduction listening. Its calibration has not been validated for bone conduction.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if type.form == .earbud {
            Text("Earbuds rest outside the ear canal. Their fit and bass leakage differ from sealed IEMs.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
struct SpatialDeviceTypePicker: View {
    let device: SpatialPlaybackDevice
    let apply: (SpatialPlaybackDevice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typeOverride: SpatialDeviceType?

    init(device: SpatialPlaybackDevice, apply: @escaping (SpatialPlaybackDevice) -> Void) {
        self.device = device; self.apply = apply
        _typeOverride = State(initialValue: device.typeOverride)
    }
    private var candidate: SpatialPlaybackDevice {
        var value = device; value.typeOverride = typeOverride; return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Listening device type").font(.title3.bold())
            Text(device.name).fontWeight(.medium)
            SpatialDeviceTypeControls(type: Binding(get: { candidate.resolvedType }, set: { typeOverride = $0 }))
            Text(candidate.typeProvenance).font(.caption).foregroundStyle(.secondary)
            if !candidate.correctionMatchesType {
                Text("The saved measurement describes a different wearing type. Choose a compatible model, or save this type without correction.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if typeOverride != nil { Button("Use catalog identification") { typeOverride = nil } }
                Spacer()
                Button("Cancel") { dismiss() }
                if !candidate.correctionMatchesType {
                    Button("Use without correction") { var value = candidate; value.correction = nil; apply(value) }
                }
                Button("Save") { apply(candidate) }.disabled(!candidate.correctionMatchesType)
            }
        }.padding(20).frame(width: 500)
    }
}

@MainActor
struct SpatialSpeakerPicker: View {
    let group: VirtualSpeakerGroup
    let choose: (VirtualSpeakerSound?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = AutoEQCatalogSearchIndex<SpeakerCatalogEntry>(entries: [], name: { $0.name })
    @State private var error: String?
    @State private var loading = false
    @State private var pending: String?
    @State private var selection: VirtualSpeakerSound?
    @State private var selectionTask: Task<Void, Never>?
    var body: some View {
        let results = index.results(matching: query)
        VStack(alignment: .leading, spacing: 14) {
            Text(group == .front ? "Choose speakers" : "Choose \(group.title.lowercased())").font(.title3.bold())
            AutoEQSearchField(placeholder: "Search speakers", query: $query, results: results, title: { $0.name }) { select($0) }
            if loading { ProgressView().controlSize(.small) }
            if !loading, error == nil, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, results.isEmpty {
                Text("No matching speakers. Try a brand or a shorter model name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let selection {
                Text(selection.name).fontWeight(.medium)
                Text(selection.specifications?.summary.isEmpty == false ? selection.specifications!.summary : "Specifications unavailable for this measurement.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(group == .front
                    ? "Builds a matching speaker set. Start with stereo, or add surround speakers and a subwoofer using Setup."
                    : "\(group.roles.count) \(group.roles.count == 1 ? "speaker" : "matching speakers") · \(group.roles.map(\.displayName).joined(separator: ", "))")
                    .font(.caption)
                Text("Measurement: \(selection.sourceName ?? "Spinorama")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Uses the measured listening-window response and, when available, bass extension with an approximate 12 dB/octave roll-off. Cabinet dimensions are for reference. Directivity, distortion and maximum output are not reproduced.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let pending { Text("Preparing \(pending)…").font(.caption) }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if index.isEmpty { Button("Retry catalog") { Task { await load() } } }
            }
            HStack {
                Button("Use Neutral Monitor") { selectionTask?.cancel(); choose(nil) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply model") { if let selection { choose(selection) } }
                    .disabled(selection == nil || pending != nil)
                    .uiInteractionAnchor("spatial-speaker-apply")
            }
        }.padding(20).frame(width: 480).task { await load() }.onDisappear { selectionTask?.cancel() }
    }
    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let entries = try await SpinoramaSpeakerProvider.shared.catalog()
            try Task.checkCancellation()
            index = .init(entries: entries, name: { $0.name })
            error = nil
        }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func select(_ entry: SpeakerCatalogEntry) {
        selectionTask?.cancel(); pending = entry.name; selection = nil; error = nil
        selectionTask = Task {
            do {
                let provider = SpinoramaSpeakerProvider.shared
                let metadata = try await provider.metadata(for: entry)
                let versions = try await provider.versions(for: entry)
                guard let version = SpeakerMeasurementVersion.recommended(in: versions, metadata: metadata) else {
                    throw SpeakerCorrectionError.invalid("No compatible measurement is available. Neutral Monitor remains available.")
                }
                let specifications = metadata.specifications[version.id]
                if let cabinet = specifications?.cabinet?.lowercased(), cabinet.contains("soundbar") || cabinet.contains("subwoofer") {
                    throw SpeakerCorrectionError.invalid("This is not an individual full-range speaker measurement. Choose a speaker for this position; subwoofers have separate bass settings.")
                }
                let measurement = try await provider.cea2034(speaker: entry, version: version)
                guard let response = measurement.listeningWindow else { throw PersonalSpatialError.invalidSpeakerSound }
                let bands = try await Task.detached(priority: .userInitiated) {
                    try VirtualSpeakerSound.tonalBands(response, bassExtensionHz: specifications?.bassExtensionHz)
                }.value
                try Task.checkCancellation()
                selection = .init(name: entry.name, measurementID: "spinorama/\(entry.id)/\(version.id)/\(measurement.rawPayloadHash)", bands: bands,
                    sourceName: measurement.provenance.sourceDisplayName, retrievedAt: measurement.provenance.retrievedAt,
                    specifications: specifications)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { pending = nil }
        }
    }
}

@MainActor
struct MovieApplicationPicker: View {
    @ObservedObject var controller: PerAppAudioController
    let apply: (MovieApplicationScope) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var all: Bool
    @State private var selected: Set<String>

    init(controller: PerAppAudioController, scope: MovieApplicationScope, apply: @escaping (MovieApplicationScope) -> Void) {
        self.controller = controller
        self.apply = apply
        switch scope {
        case .allApplications:
            _all = State(initialValue: true)
            _selected = State(initialValue: [])
        case .selectedApplications(let ids):
            _all = State(initialValue: false)
            _selected = State(initialValue: ids)
        }
    }
    private var ids: [String] {
        Set(controller.applications.map(\.id).filter(PerAppApplicationIdentityPolicy.isPersistentApplicationID))
            .union(selected).sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Movie apps").font(.title3.bold())
            Picker("Apply to", selection: $all) { Text("All apps").tag(true); Text("Selected apps").tag(false) }.pickerStyle(.segmented)
            if !all {
                if ids.isEmpty { Text("Play audio in an app to select it.").foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(ids, id: \.self) { id in
                            let app = controller.applications.first { $0.id == id }
                            HStack {
                                if let app { Image(nsImage: PerAppIconCache.icon(for: app)).resizable().frame(width: 20, height: 20) }
                                Toggle(app?.displayName ?? id, isOn: Binding(get: { selected.contains(id) }, set: { enabled in
                                    if enabled { selected.insert(id) } else { selected.remove(id) }
                                }))
                                Spacer()
                                if let mode = app?.settings.playbackModeOverride, mode != .spatialRender {
                                    Text("Uses \(mode.compactDisplayName)").font(.caption).foregroundStyle(.secondary)
                                } else if app?.isActive != true { Text("Not playing").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }.frame(maxHeight: 260)
                if controller.applications.contains(where: { PerAppApplicationIdentityPolicy.isEphemeralApplicationID($0.id) }) {
                    Text("Sources without a stable application identity are available only in All apps.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Apply") { apply(all ? .allApplications : .selectedApplications(selected)) }.disabled(!all && selected.isEmpty) }
        }.padding(20).frame(width: 450)
    }
}
