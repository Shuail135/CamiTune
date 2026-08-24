import Combine
import SwiftUI

struct EQBandColumn: View {
    @Binding var band: EQBand
    let audioDB: Double
    let responseDB: Double
    let setKind: (EQBand.Kind, inout EQBand) -> Void
    let commitFrequency: @MainActor (Double) -> Void
    let onGainEditingChanged: @MainActor (Bool) -> Void

    @State private var frequencyDraft: String
    @FocusState private var frequencyFieldFocused: Bool
    private let fieldWidth: CGFloat = 68
    private static let frequencyFormat = FloatingPointFormatStyle<Double>.number
        .precision(.fractionLength(0...1))

    init(
        band: Binding<EQBand>,
        audioDB: Double,
        responseDB: Double,
        setKind: @escaping (EQBand.Kind, inout EQBand) -> Void,
        commitFrequency: @escaping @MainActor (Double) -> Void,
        onGainEditingChanged: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        _band = band
        self.audioDB = audioDB
        self.responseDB = responseDB
        self.setKind = setKind
        self.commitFrequency = commitFrequency
        self.onGainEditingChanged = onGainEditingChanged
        _frequencyDraft = State(initialValue: band.wrappedValue.frequency.formatted(Self.frequencyFormat))
    }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                TextField("Hz", text: $frequencyDraft)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: fieldWidth)
                    .focused($frequencyFieldFocused)
                    .onSubmit { commitDraftFrequency() }
                    .onChange(of: frequencyFieldFocused) { focused in
                        if !focused { commitDraftFrequency() }
                    }
                    .onChange(of: band.frequency) { frequency in
                        guard !frequencyFieldFocused else { return }
                        frequencyDraft = frequency.formatted(Self.frequencyFormat)
                    }
                HStack {
                    Spacer()
                    Text("Hz").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)

            VerticalEQSlider(
                gain: Binding(
                    get: { band.gain ?? 0 },
                    set: { band.gain = usesGain(band.kind) ? $0 : nil }
                ),
                audioDB: audioDB,
                responseDB: responseDB,
                gainEnabled: usesGain(band.kind),
                accessibilityTitle: "\(band.frequency.formatted(Self.frequencyFormat)) Hz gain",
                onEditingChanged: onGainEditingChanged
            )
            .frame(width: 80, height: 220)

            VStack(spacing: 2) {
                Text("Gain")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Gain", value: Binding(
                    get: { band.gain ?? 0 },
                    set: { band.gain = min(12, max(-12, $0)) }
                ), format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: fieldWidth)
                .disabled(!usesGain(band.kind))
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Text("Q")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Q", value: Binding(
                    get: { band.q ?? 0.707 },
                    set: { band.q = max(0.05, $0) }
                ), format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: fieldWidth)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 2) {
                Button {
                    band.enabled.toggle()
                } label: {
                    Image(systemName: band.enabled ? "power.circle.fill" : "power.circle")
                        .foregroundStyle(band.enabled ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .frame(width: 18)
                .help(band.enabled ? "Disable this filter" : "Enable this filter")

                Menu {
                    ForEach(EQBand.Kind.allCases, id: \.self) { kind in
                        Button {
                            setKind(kind, &band)
                        } label: {
                            Text(filterLabel(kind))
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        FilterShapeIcon(kind: band.kind)
                            .frame(width: 20, height: 15)
                        Text(filterLabel(band.kind))
                            .font(.caption2)
                            .lineLimit(1)
                            .frame(width: 39, alignment: .trailing)
                    }
                    .frame(width: 62, height: 24, alignment: .trailing)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .frame(width: 70, alignment: .center)
                .help("Filter type")
            }
            .frame(width: 90)
        }
    }

    @MainActor
    private func commitDraftFrequency() {
        guard let frequency = try? Self.frequencyFormat.parseStrategy.parse(frequencyDraft),
              frequency.isFinite, frequency > 0 else {
            frequencyDraft = band.frequency.formatted(Self.frequencyFormat)
            return
        }
        frequencyDraft = frequency.formatted(Self.frequencyFormat)
        guard frequency != band.frequency else { return }
        commitFrequency(frequency)
    }

    private func usesGain(_ kind: EQBand.Kind) -> Bool {
        kind == .peaking || kind == .lowShelf || kind == .highShelf
    }

    private func filterLabel(_ kind: EQBand.Kind) -> String {
        switch kind {
        case .peaking: return "Peak"
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        case .lowPass: return "Low pass"
        case .highPass: return "High pass"
        case .notch: return "Notch"
        case .allPass: return "All pass"
        }
    }
}


private struct FilterShapeIcon: View {
    let kind: EQBand.Kind

    var body: some View {
        Canvas { context, size in
            let points = shapePoints(size: size)
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .color(.accentColor), lineWidth: 1.8)
        }
    }

    private func shapePoints(size: CGSize) -> [CGPoint] {
        let w = size.width, h = size.height
        switch kind {
        case .peaking:
            return [CGPoint(x: 0, y: h * 0.75), CGPoint(x: w * 0.3, y: h * 0.72), CGPoint(x: w * 0.5, y: h * 0.18), CGPoint(x: w * 0.7, y: h * 0.72), CGPoint(x: w, y: h * 0.75)]
        case .lowShelf:
            return [CGPoint(x: 0, y: h * 0.2), CGPoint(x: w * 0.42, y: h * 0.2), CGPoint(x: w * 0.62, y: h * 0.75), CGPoint(x: w, y: h * 0.75)]
        case .highShelf:
            return [CGPoint(x: 0, y: h * 0.75), CGPoint(x: w * 0.38, y: h * 0.75), CGPoint(x: w * 0.58, y: h * 0.2), CGPoint(x: w, y: h * 0.2)]
        case .lowPass:
            return [CGPoint(x: 0, y: h * 0.2), CGPoint(x: w * 0.45, y: h * 0.2), CGPoint(x: w, y: h * 0.9)]
        case .highPass:
            return [CGPoint(x: 0, y: h * 0.9), CGPoint(x: w * 0.55, y: h * 0.2), CGPoint(x: w, y: h * 0.2)]
        case .notch:
            return [CGPoint(x: 0, y: h * 0.2), CGPoint(x: w * 0.38, y: h * 0.2), CGPoint(x: w * 0.5, y: h * 0.9), CGPoint(x: w * 0.62, y: h * 0.2), CGPoint(x: w, y: h * 0.2)]
        case .allPass:
            return [CGPoint(x: 0, y: h * 0.5), CGPoint(x: w, y: h * 0.5)]
        }
    }
}

