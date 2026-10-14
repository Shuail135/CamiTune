import CamiTuneDomain
import SwiftUI

struct SpeakerLayoutSelector: View {
    @Binding var topology: SpeakerTopology
    var allowedOutputs: Set<Int>? = nil
    var applied: () -> Void = {}
    @State private var message: String?

    private var available: [SpeakerLayoutTemplate] {
        SpeakerLayoutTemplate.available(outputCount: topology.endpoints.filter {
            allowedOutputs?.contains($0.id.channelIndex) ?? true
        }.count)
    }
    private var selected: SpeakerLayoutTemplate? {
        SpeakerLayoutTemplate.selected(in: topology, allowedOutputs: allowedOutputs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speakers").font(.callout)
                Spacer()
                /*
                if topology.layoutTemplateID == nil, selected != nil {
                    Text("Estimated").font(.caption).foregroundStyle(.secondary)
                }
                 */
                Menu {
                    ForEach(available) { template in
                        Button {
                            do {
                                topology = try template.applying(to: topology, allowedOutputs: allowedOutputs)
                                message = nil; applied()
                            } catch { message = error.localizedDescription }
                        } label: {
                            if selected?.id == template.id { Label(template.displayName, systemImage: "checkmark") }
                            else { Text(template.displayName) }
                        }
                    }
                    Divider()
                    Button("Custom") {
                        topology.layoutTemplateID = .custom
                        for index in topology.endpoints.indices { topology.endpoints[index].roleOrigin = .user }
                    }
                } label: {
                    Text(selected?.displayName ?? "Custom")
                }
                .fixedSize().accessibilityLabel("Speaker setup")
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
    }
}

struct SpeakerPlacementNotice: View {
    @Binding var endpoint: SpeakerEndpoint
    let listener: SpatialVector3
    @State private var kept = false

    var body: some View {
        let warnings = SpeakerPlacementWarning.warnings(for: endpoint, listener: listener)
        VStack(alignment: .leading, spacing: 4) {
            if !kept && !warnings.isEmpty {
                ForEach(warnings) { warning in
                    Label(warning.message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Keep Position") { kept = true }
                    Button("Move to Suggested Position") {
                        let suggested = SpeakerLayoutGeometry.vector(SpeakerLayoutGeometry.suggestedPosition(for: endpoint.role))
                        endpoint.position = SpeakerLayoutGeometry.position(x: suggested.x + listener.x,
                            y: suggested.y + listener.y, height: suggested.z + listener.z)
                        endpoint.positionSource = .userPlacement
                    }
                }.controlSize(.small)
            }
        }
        .onChange(of: endpoint) { _ in kept = false }
        .onChange(of: listener) { _ in kept = false }
    }
}
