import CamiTuneDomain
import SwiftUI

/// Both first setup and later device changes use one catalog/measurement owner.
@MainActor
final class SpatialDeviceSelection: ObservableObject {
    enum CatalogState {
        case idle, loading
        case ready(AutoEQCatalogSearchIndex<DeviceCatalogEntry>)
        case failed(String)
    }
    enum Measurements {
        case none
        case loading(DeviceCatalogEntry)
        case ready(DeviceCatalogEntry, [DeviceCorrectionMeasurement], [CorrectionPath])
        case failed(DeviceCatalogEntry, String)
    }

    let endpoint: ProfileEndpointKind
    let genericName: String
    @Published private(set) var catalogState: CatalogState = .idle
    @Published private(set) var measurements: Measurements = .none
    @Published private(set) var device: SpatialPlaybackDevice
    @Published var signature: SpatialSoundSignature?
    private let catalog: DeviceMeasurementCatalog
    private var catalogTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?

    init(endpoint: ProfileEndpointKind, genericName: String, current: SpatialPlaybackDevice? = nil,
         catalog: DeviceMeasurementCatalog = .online) {
        self.endpoint = endpoint
        self.genericName = genericName
        self.catalog = catalog
        let device = current ?? .init(name: genericName, source: "Generic")
        self.device = device
        signature = .init(device: device)
    }

    deinit { catalogTask?.cancel(); selectionTask?.cancel() }

    func load() async {
        if case .ready = catalogState { return }
        catalogState = .loading
        do {
            let entries = try await catalog.entries()
            let endpoint = endpoint
            let (filtered, index) = await Task.detached(priority: .userInitiated) {
                let filtered = ReferenceCorrection.catalog(entries, endpoint: endpoint)
                return (filtered, AutoEQCatalogSearchIndex(entries: filtered, name: { $0.displayName }))
            }.value
            try Task.checkCancellation()
            catalogState = .ready(index)
            if case .none = measurements, let entry = filtered.first(where: { $0.id == device.id }) {
                loadMeasurements(entry)
            }
        } catch {
            if !Task.isCancelled { catalogState = .failed(error.localizedDescription) }
        }
    }

    func results(matching query: String) -> [DeviceCatalogEntry] {
        guard case .ready(let index) = catalogState else { return [] }
        return index.results(matching: query)
    }

    func retryCatalog() {
        catalogTask?.cancel()
        catalogTask = Task { await load() }
    }

    func select(_ entry: DeviceCatalogEntry) {
        if entry.id != device.id {
            device = SpatialHeadphoneCorrection.describe(entry)
            signature = .original
        }
        loadMeasurements(entry)
    }

    func useGeneric() {
        selectionTask?.cancel()
        device = .init(name: genericName, source: "Generic", typeOverride: device.resolvedType)
        signature = .original
        measurements = .none
    }

    func setType(_ type: SpatialDeviceType) { device.typeOverride = type }
    func cancel() {
        catalogTask?.cancel(); catalogTask = nil
        selectionTask?.cancel(); selectionTask = nil
    }

    private func loadMeasurements(_ entry: DeviceCatalogEntry) {
        selectionTask?.cancel()
        measurements = .loading(entry)
        selectionTask = Task {
            do {
                let values = try await catalog.measurements(for: entry)
                let paths = try await Task.detached(priority: .userInitiated) {
                    try SpatialHeadphoneCorrection.paths(measurements: values)
                }.value
                try Task.checkCancellation()
                measurements = .ready(entry, values, paths)
            } catch {
                if !Task.isCancelled { measurements = .failed(entry, error.localizedDescription) }
            }
        }
    }

    private func savedCorrection(for signature: SpatialSoundSignature) -> DeviceCorrectionProfile? {
        guard let target = signature.target, let correction = device.correction,
              correction.targetSelection.preset == target, device.correctionMatchesType else { return nil }
        return correction
    }

    func sources(for signature: SpatialSoundSignature) -> [DeviceMeasurementReference]? {
        guard let target = signature.target else { return nil }
        if let correction = savedCorrection(for: signature) { return correction.sources }
        guard case .ready(_, _, let paths) = measurements else { return nil }
        return paths.first { $0.target == target && device.resolvedType.supportsCorrection(from: $0.sources) }?.sources
    }

    func supports(_ signature: SpatialSoundSignature?) -> Bool {
        guard let signature else { return false }
        return signature == .original || sources(for: signature) != nil
    }

    func prepare() async throws -> SpatialPlaybackDevice {
        guard let signature else { throw PersonalSpatialError.invalidHeadphoneCorrection }
        var result = device
        guard let target = signature.target else {
            result.removeCorrection()
            try result.validate()
            return result
        }
        guard supports(signature) else { throw PersonalSpatialError.incompatibleDeviceType }
        if let correction = savedCorrection(for: signature) {
            result.correction = correction
            result.correction?.isEnabled = true
            if result.strength == 0 { result.strength = 1 }
        } else {
            guard case .ready(let entry, let measurements, _) = self.measurements else {
                throw PersonalSpatialError.invalidHeadphoneCorrection
            }
            let typeOverride = result.typeOverride
            result = try await Task.detached(priority: .userInitiated) {
                try SpatialHeadphoneCorrection.prepare(entry: entry, measurements: measurements, target: target, typeOverride: typeOverride)
            }.value
            try Task.checkCancellation()
        }
        try result.validate()
        return result
    }
}

@MainActor
struct SpatialDeviceSelectionContent: View {
    @ObservedObject var selection: SpatialDeviceSelection
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    AutoEQSearchField(placeholder: selection.endpoint == .iem ? "Search your earphones" : "Search your headphones",
                        query: $query, results: selection.results(matching: query), title: { $0.displayName }) {
                            selection.select($0)
                        }
                    switch selection.catalogState {
                    case .idle, .loading:
                        ProgressView("Loading models…").controlSize(.small)
                    case .failed(let error):
                        Text(error).font(.callout).foregroundStyle(.orange)
                        Button("Retry models") { selection.retryCatalog() }
                    case .ready:
                        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           selection.results(matching: query).isEmpty {
                            Text("No matching models. Try a brand or a shorter name.").foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        if selection.device.id != nil {
                            Text(selection.device.name).fontWeight(.medium)
                        }
                        Spacer()
                        Button("My model isn’t listed") { selection.useGeneric(); query = "" }
                            .uiInteractionAnchor("spatial-device-generic")
                    }
                }.padding(8)
            } label: { Text(selection.endpoint == .iem ? "Earphones" : "Headphones") }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    SpatialDeviceTypeControls(type: Binding(
                        get: { selection.device.resolvedType }, set: { selection.setType($0) }))
                }.padding(8)
            } label: { Text("Device Type") }
        }
        .font(.callout)
    }
}

extension SpatialSoundSignature {
    func title(earphones: Bool) -> String {
        switch self {
        case .original: return earphones ? "Keep my earphones’ sound" : "Keep my headphones’ sound"
        case .natural: return "Natural spatial sound"
        case .balanced: return "Balanced sound"
        }
    }

}

@MainActor
struct SpatialSoundSignatureContent: View {
    @ObservedObject var selection: SpatialDeviceSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                Picker("Sound signature", selection: $selection.signature) {
                    if !selection.supports(selection.signature) {
                        Text("Choose a sound signature").tag(selection.signature)
                    }
                    ForEach(SpatialSoundSignature.allCases.filter { selection.supports($0) }, id: \.self) { option in
                        Text(option.title(earphones: selection.endpoint == .iem)).tag(Optional(option))
                    }
                }
                .pickerStyle(.menu)
                .uiInteractionAnchor("spatial-sound-signature")
                .padding(8)
            }
            switch selection.measurements {
            case .loading:
                ProgressView("Loading sound signatures…").controlSize(.small)
            case .failed(let entry, let error):
                HStack {
                    Text("Sound signatures couldn’t be loaded.").foregroundStyle(.secondary)
                    Button("Retry") { selection.select(entry) }
                    AutoEQDeviceInfoIcon(message: error)
                }
            case .none, .ready:
                EmptyView()
            }
        }.font(.callout)
    }
}
