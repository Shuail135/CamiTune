import SwiftUI

@MainActor
struct FrontStageEditorView: View {
    let state: AppState
    @Binding var profile: DeviceProfile

    private var profileIsActive: Bool {
        state.isActive && state.activeProfileID == profile.id
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        heading
                        Spacer()
                        modePicker
                            .frame(width: 230)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        heading
                        modePicker
                            .frame(maxWidth: 300)
                    }
                }

                if profile.spatialRenderingMode == .frontStage {
                    Text("Front Stage automatically detects stereo, 5.1, and 7.1 PCM. Dialogue is anchored to the screen, front channels form the main stage, surrounds add width and depth, and LFE receives protected impact processing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Standard adds no spatial processing: stereo remains unchanged and multichannel audio uses the conservative role-aware fallback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Spatial Rendering").font(.title3.bold())
            Text("Listening mode")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modePicker: some View {
        Picker("Listening mode", selection: modeBinding) {
            ForEach(SpatialRenderingMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var modeBinding: Binding<SpatialRenderingMode> {
        Binding(
            get: { profile.spatialRenderingMode },
            set: { mode in
                guard mode != profile.spatialRenderingMode else { return }
                profile.spatialRenderingMode = mode
                guard profileIsActive else { return }
                let updated = profile
                Task { await state.apply(profile: updated) }
            }
        )
    }
}
