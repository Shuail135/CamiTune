import AppKit
import CamiTuneAudio
import CamiTuneDomain
import Combine
import SwiftUI

extension DeveloperSelfTests {
    static func uiStateCases() -> [DiagnosticCase] {
        [
            DiagnosticCase(id: "UI01", suite: "UI interactions", name: "Unchanged profiles do not invalidate editors", safety: .simulated) {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let profile = DiagnosticSandbox.profile()
                box.profiles.profiles = [profile]
                var publications = 0
                let subscription = box.profiles.objectWillChange.sink { _ in publications += 1 }
                for _ in 0..<20 { box.profiles.update(profile) }
                try diagnosticRequire(publications == 0, "Unchanged profile republished")
                var changed = profile; changed.name = "Renamed fixture"
                box.profiles.update(changed)
                try diagnosticRequire(publications > 0, "Real edit was not published")
                withExtendedLifetime(subscription) {}
                return .init(summary: "No-op updates leave the editor tree intact; real edits still publish")
            },
            DiagnosticCase(id: "UI02", suite: "UI interactions", name: "Band edits preserve control identity", safety: .simulated) {
                let bands = PerChannelBandsState()
                let initial = EQEditorSupport.resizedBands([], count: 8)
                bands.replace(with: initial)
                let first = bands.items[0]
                var publications = 0
                let subscription = bands.$items.dropFirst().sink { _ in publications += 1 }
                bands.replace(with: initial)
                var changed = initial; changed[0].gain = 3
                bands.replace(with: changed)
                try diagnosticRequire(publications == 0 && bands.items[0] === first && first.band.gain == 3,
                    "Numeric edits replaced the band strip or lost the edited value")
                bands.replace(with: Array(changed.dropLast()))
                try diagnosticRequire(publications == 1 && bands.count == 7 && bands.items[0] === first,
                    "Structural edit did not preserve surviving controls")
                withExtendedLifetime(subscription) {}
                return .init(summary: "Numeric changes update one band; deletion publishes one structural change")
            },
            DiagnosticCase(id: "UI03", suite: "UI interactions", name: "Async editor restoration preserves recoverable work", safety: .simulated) {
                let box = try DiagnosticSandbox(); defer { box.cleanUp() }
                let url = box.directory.appendingPathComponent("ui-draft.json")
                let original = Data("unreadable draft".utf8)
                try original.write(to: url)
                let store = AutoEQWorkStore<UIWorkFixture>(url: url)
                let restored = await store.loadWithoutBlockingUI()
                try diagnosticRequire(restored == nil && store.errorMessage != nil, "Unreadable draft was accepted")
                store.save(.init(value: 7)); store.flush()
                guard let backup = store.recoveryBackupURL else { throw DiagnosticFailure(message: "Recovery backup was not written") }
                let backupData = try Data(contentsOf: backup)
                try diagnosticRequire(backupData == original, "Recovery changed the original data")
                let next = AutoEQWorkStore<UIWorkFixture>(url: url)
                let saved = await next.loadWithoutBlockingUI()
                try diagnosticRequire(saved?.value == 7 && next.errorMessage == nil, "Async round trip lost the saved draft")
                return .init(summary: "Restoration runs off-main and retains unreadable originals before saving")
            }
        ]
    }
}

private struct UIWorkFixture: PersistedAutoEQWork {
    var value: Int
    func migrated() throws -> Self { self }
}

#if DEBUG
/// Native layout regressions use isolated profiles and fake runtime services.
/// Run the Debug executable with --ui-self-test <artifact-directory>.
@MainActor
enum UIInteractionSelfTests {
    static func run(artifacts: URL) async throws {
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["CAMITUNE_UI_CORRECTION_ONLY"] == "1" {
            try await spectrumPresentation(artifacts: artifacts)
            try await correctionInteractions(artifacts: artifacts)
            return
        }
        for test in DeveloperSelfTests.uiStateCases() {
            let result = try await test.execute()
            print("\(test.id): \(result.summary)")
        }
        try await overflowAndResize(artifacts: artifacts)
        try await channelSwitching(artifacts: artifacts)
        try await disclosureLayout()
        try await responsiveLayouts(artifacts: artifacts)
        try await adaptiveEditor(artifacts: artifacts)
        try await nativeDisclosureAlignment()
        try await steppedSliderPrecision()
        try await scrollingCadence()
        try await correctionInteractions(artifacts: artifacts)
        try await spectrumPresentation(artifacts: artifacts)
    }

    private static func overflowAndResize(artifacts: URL) async throws {
        let probe = ScrollProbeState()
        let bands = EQEditorSupport.resizedBands([], count: 4)
        let content = ScrollView {
            VStack {
                OverflowAwareHorizontalScrollView(
                    contentWidth: GraphicEqualizerBands.requiredContentWidth(bandCount: 4, columnWidth: 96), height: 402
                ) {
                    GraphicEqualizerBands(bands: .constant(bands), profileID: UUID(), responsePoints: [],
                        setKind: EQEditorSupport.setKind, columnWidth: 96)
                        .background(ScrollEnvironmentProbe(state: probe))
                }
                Text("Below the equalizer")
            }
        }.scrollBounceWhenNeeded()
        let fixture = WindowFixture(content, size: .init(width: 700, height: 600))
        defer { fixture.close() }
        await fixture.settle()
        try diagnosticRequire(probe.enabled == false, "A fitting EQ still accepts scrolling (enabled: \(String(describing: probe.enabled)), host: \(fixture.host.frame), scrolls: \(fixture.scrollViews.map { "\($0.frame.size)/\($0.documentView?.frame.size ?? .zero)" }))")
        fixture.resize(width: 350, height: 600)
        await fixture.settle()
        try diagnosticRequire(probe.enabled == true, "Outer page prevented an overflowing EQ from scrolling")
        let horizontal = fixture.scrollViews.first { ($0.documentView?.frame.width ?? 0) > $0.contentSize.width + 1 }
        try diagnosticRequire(horizontal != nil, "EQ bands were clipped instead of horizontally scrollable")
        if let horizontal {
            horizontal.contentView.scroll(to: NSPoint(x: 70, y: 0))
            horizontal.reflectScrolledClipView(horizontal.contentView)
        }
        fixture.resize(width: 700, height: 600)
        await fixture.settle()
        try diagnosticRequire(probe.enabled == false, "EQ scrolling stayed enabled after expanding the window")
        try diagnosticRequire(fixture.scrollViews.allSatisfy { abs($0.contentView.bounds.origin.x) < 1 },
            "A fitting EQ retained a stale horizontal offset")
        try fixture.snapshot(to: artifacts.appendingPathComponent("equalizer-fit.png"))
        print("UI04: Fitting EQ is stationary; overflow scrolls inside a fitting page; resizing resets its offset")

        let table = WindowFixture(OverflowAwareHorizontalScrollView {
            CorrectionFilterTable(filters: .constant(bands))
        }, size: .init(width: 700, height: 350))
        defer { table.close() }
        await table.settle()
        try diagnosticRequire(table.scrollViews.allSatisfy { ($0.documentView?.frame.width ?? 0) <= $0.contentSize.width + 1 },
            "Filter table unexpectedly overflows a wide window")
        table.resize(width: 350, height: 350)
        await table.settle()
        try table.snapshot(to: artifacts.appendingPathComponent("correction-table-narrow.png"))
        try diagnosticRequire(table.scrollViews.contains { ($0.documentView?.frame.width ?? 0) > $0.contentSize.width + 1 },
            "Filter table failed to expose narrow-window overflow: host \(table.host.frame), scrolls \(table.scrollViews.map { "\($0.frame)/\($0.documentView?.frame ?? .zero)" })")
        try table.snapshot(to: artifacts.appendingPathComponent("correction-table-narrow.png"))
        print("UI05: Intrinsic filter table fits wide layouts and scrolls in narrow layouts")
    }

    private static func channelSwitching(artifacts: URL) async throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        var profile = DiagnosticSandbox.profile()
        profile.endpointKind = .headphones
        for index in 0..<2 {
            profile.processing.setChannelProcessing(index: index, role: index == 0 ? .left : .right,
                gainDB: index == 0 ? -3 : 3, bands: EQEditorSupport.resizedBands([], count: 8))
        }
        profile.sectionLayout = .init(hidden: [.meters, .spectrum, .mode, .deviceCorrection, .equalizer])
        box.profiles.profiles = [profile]
        let runtime = DiagnosticRuntimeFakes()
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: runtime.services())
        let content = ProfileEditorView(state: state, coreAudio: state.coreAudio,
            profile: ContentDetailView.editorBinding(for: profile, in: box.profiles))
            .environmentObject(MainWindowCommandCoordinator())
        let fixture = WindowFixture(content, size: .init(width: 700, height: 640))
        defer { fixture.close() }
        await fixture.settle()
        guard let scroll = fixture.scrollViews.first else { throw DiagnosticFailure(message: "Missing profile scroll view") }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 260))
        scroll.reflectScrolledClipView(scroll.contentView)
        await fixture.settle()
        let origin = scroll.contentView.bounds.origin
        let height = scroll.documentView?.frame.height ?? 0
        var publications = 0
        let subscription = box.profiles.objectWillChange.sink { _ in publications += 1 }
        try fixture.snapshot(to: artifacts.appendingPathComponent("headphone-channel-processing.png"))
        let channels = profile.configuredProcessingChannels
        try diagnosticRequire(channels.count == 2, "Headphone fixture did not expose Left and Right")
        for index in 0..<12 {
            let label = channels[(index + 1) % 2].displayName
            guard let selector = fixture.scrollViews.first(where: { $0.contentSize.height < 60 }),
                  let document = selector.documentView else { throw DiagnosticFailure(message: "Missing channel selector") }
            let selectedIndex = (index + 1) % 2
            fixture.click(in: document, at: .init(x: document.bounds.width * (CGFloat(selectedIndex) + 0.5) / 2,
                                                  y: document.bounds.midY))
            await fixture.settle()
            let gain = fixture.textFields.first { $0.placeholderString == "Channel gain" }
            try diagnosticRequire(gain?.doubleValue == (selectedIndex == 0 ? -3 : 3),
                "Channel click did not load its independent gain: \(String(describing: gain?.stringValue))")
            try diagnosticRequire(abs(scroll.contentView.bounds.origin.y - origin.y) < 1,
                "Channel \(label) moved the viewport from \(origin.y) to \(scroll.contentView.bounds.origin.y)")
            try diagnosticRequire(abs((scroll.documentView?.frame.height ?? 0) - height) < 1,
                "Channel \(label) changed page height")
        }
        try diagnosticRequire(publications == 0, "Channel navigation wrote \(publications) profile changes")
        withExtendedLifetime(subscription) {}
        try fixture.snapshot(to: artifacts.appendingPathComponent("headphone-channel-processing.png"))
        fixture.resize(width: 500, height: 640)
        await fixture.settle()
        try diagnosticRequire((scroll.documentView?.frame.width ?? 0) <= scroll.contentSize.width + 1,
            "Narrow profile controls forced horizontal page overflow")
        try fixture.snapshot(to: artifacts.appendingPathComponent("headphone-channel-processing-narrow.png"))

        // A native text field must commit to the channel being left, even when
        // the next selection shares the same control objects.
        guard let gainField = fixture.textFields.first(where: { $0.placeholderString == "Channel gain" }) else {
            throw DiagnosticFailure(message: "Missing channel gain field")
        }
        try await fixture.edit(gainField, text: "-6.0")
        guard let selector = fixture.scrollViews.first(where: { $0.contentSize.height < 60 }),
              let selectorDocument = selector.documentView else { throw DiagnosticFailure(message: "Missing channel selector") }
        fixture.click(in: selectorDocument, at: .init(x: selectorDocument.bounds.width * 0.75, y: selectorDocument.bounds.midY))
        await fixture.settle()
        let saved = box.profiles.profiles[0].processing
        try diagnosticRequire(saved.settings(forChannel: 0)?.gainDB == -6 && saved.settings(forChannel: 1)?.gainDB == 3,
            "Focused gain edit was lost or committed to the next channel")

        fixture.resize(width: 700, height: 1300)
        await fixture.settle()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        await fixture.settle()
        guard let frequencyField = fixture.textFields.first(where: { $0.placeholderString == "Hz" }) else {
            throw DiagnosticFailure(message: "Missing channel frequency field")
        }
        try await fixture.edit(frequencyField, text: "777")
        fixture.click(in: selectorDocument, at: .init(x: selectorDocument.bounds.width * 0.25, y: selectorDocument.bounds.midY))
        await fixture.settle()
        let frequencies = box.profiles.profiles[0].processing
        try diagnosticRequire(frequencies.settings(forChannel: 1)?.bands.contains(where: { $0.frequency == 777 }) == true
            && frequencies.settings(forChannel: 0)?.bands.contains(where: { $0.frequency == 777 }) != true,
            "Focused frequency edit was lost or crossed channel boundaries: left \(frequencies.settings(forChannel: 0)?.bands.map(\.frequency) ?? []), right \(frequencies.settings(forChannel: 1)?.bands.map(\.frequency) ?? [])")
        print("UI10: Focused gain and frequency edits commit to the departing channel")
        print("UI06: Twelve Left/Right switches preserve page offset and height with zero profile writes; narrow layout fits")
    }

    private static func disclosureLayout() async throws {
        let state = DisclosureState()
        let fixture = WindowFixture(DisclosureFixture(state: state), size: .init(width: 500, height: 600))
        defer { fixture.close() }
        await fixture.settle()
        guard let marker = fixture.views.first(where: { $0.identifier?.rawValue == "below-disclosure" }) else {
            throw DiagnosticFailure(message: "Missing disclosure marker")
        }
        let initial = marker.convert(marker.bounds, to: fixture.host)
        for _ in 0..<5 {
            withAnimation(.easeInOut(duration: 0.18)) { state.expanded = true }
            await fixture.settle()
            let expanded = marker.convert(marker.bounds, to: fixture.host)
            try diagnosticRequire(abs(expanded.minX - initial.minX) < 1 && abs(expanded.width - initial.width) < 1,
                "Disclosure expansion shifted neighboring controls horizontally")
            try diagnosticRequire(abs(expanded.minY - initial.minY) > 190, "Disclosure did not expand its content")
            withAnimation(.easeInOut(duration: 0.18)) { state.expanded = false }
            await fixture.settle()
            let collapsed = marker.convert(marker.bounds, to: fixture.host)
            try diagnosticRequire(abs(collapsed.minY - initial.minY) < 1, "Disclosure did not restore the original position")
        }
        print("UI07: Repeated disclosure expansion preserves horizontal alignment and restores neighboring control positions")
    }

    private static func responsiveLayouts(artifacts: URL) async throws {
        let bands = EQEditorSupport.resizedBands([], count: 4)
        for textSize in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
            let content = ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PreampGainControl(gainDB: .constant(0), limiterEnabled: .constant(true),
                        meters: AudioRuntimeMonitor(), profileID: UUID())
                    SimpleEQControlsView(settings: .constant(.init()))
                    EqualizerBandScrollView(bandCount: bands.count) { columnWidth in
                        GraphicEqualizerBands(bands: .constant(bands), profileID: UUID(), responsePoints: [],
                            setKind: EQEditorSupport.setKind, columnWidth: columnWidth)
                    }
                }.padding(20)
            }.dynamicTypeSize(textSize)
            let fixture = WindowFixture(content, size: .init(width: 480, height: 800))
            defer { fixture.close() }
            for width in [480.0, 900.0] {
                fixture.resize(width: width, height: 800)
                await fixture.settle()
                guard let scroll = fixture.scrollViews.first else { throw DiagnosticFailure(message: "Missing responsive scroll view") }
                try diagnosticRequire((scroll.documentView?.frame.width ?? 0) <= scroll.contentSize.width + 1,
                    "Text size \(textSize) caused page overflow at \(width) points")
            }
            fixture.window.appearance = NSAppearance(named: .darkAqua)
            fixture.resize(width: 480, height: 800)
            await fixture.settle()
            try fixture.snapshot(to: artifacts.appendingPathComponent("responsive-\(textSize).png"))
        }
        print("UI08: Default, larger, and accessibility text layouts fit 480- and 900-point windows")
    }

    private static func adaptiveEditor(artifacts: URL) async throws {
        let state = EditorProbeState()
        let content = AdaptiveEditorLayout {
            Text("Auto EQ").frame(maxWidth: .infinity, alignment: .leading)
        } compactSelector: {
            Picker("Correction method", selection: .constant(0)) { Text("Auto EQ").tag(0) }
                .labelsHidden().fixedSize()
        } content: {
            EditorProbe(state: state)
        }.padding(20)
        let fixture = WindowFixture(content, size: .init(width: 900, height: 400))
        defer { fixture.close() }
        await fixture.settle()
        guard let field = fixture.textFields.first(where: { $0.placeholderString == "Draft" }) else {
            throw DiagnosticFailure(message: "Missing adaptive editor field")
        }
        try await fixture.edit(field, text: "Unfinished correction")
        let wideX = field.convert(field.bounds, to: fixture.host).minX
        fixture.resize(width: 450, height: 400)
        await fixture.settle()
        try diagnosticRequire(field.convert(field.bounds, to: fixture.host).minX < wideX - 100,
            "Narrow navigation did not move above the editor")
        try fixture.snapshot(to: artifacts.appendingPathComponent("adaptive-editor-narrow.png"))
        fixture.resize(width: 900, height: 400)
        await fixture.settle()
        try diagnosticRequire(state.appearances == 1 && fixture.textFields.contains(where: { $0 === field })
            && field.stringValue == "Unfinished correction" && field.currentEditor() != nil,
            "Navigation resize replaced the editor, lost its draft, or dropped focus")
        print("UI11: Compact navigation preserves editor identity, unfinished text, and keyboard focus across resizing")
    }

    private static func correctionInteractions(artifacts: URL) async throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        var profile = DiagnosticSandbox.profile()
        profile.endpointKind = .headphones
        box.profiles.profiles = [profile]
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
        let binding = Binding(get: { box.profiles.profiles[0] }, set: { box.profiles.update($0) })
        let fixture = WindowFixture(ScrollView {
            VStack {
                DeviceCorrectionSectionView(state: state, profile: binding)
                    .disclosureGroupStyle(SectionDisclosureStyle())
                Text("Below correction")
                Color.clear.frame(height: 800)
            }.padding(16)
        }, size: .init(width: 950, height: 1000))
        defer { fixture.close() }
        await fixture.settle()
        try await Task.sleep(for: .milliseconds(500))
        func press(identifier id: String, disclosure: Bool = false) async throws {
            guard let marker = fixture.views.first(where: { $0.identifier?.rawValue == id }) else {
                throw DiagnosticFailure(message: "Missing correction action \(id)")
            }
            if disclosure {
                let area = marker.convert(marker.bounds, to: fixture.host)
                guard let title = fixture.views.first(where: {
                    $0.identifier?.rawValue == "disclosure-label" && area.contains($0.convert($0.bounds, to: fixture.host))
                }) else { throw DiagnosticFailure(message: "Missing disclosure title") }
                title.scrollToVisible(title.bounds)
                await fixture.settle()
                fixture.click(in: title, at: .init(x: title.bounds.midX, y: title.bounds.midY))
            } else {
                marker.scrollToVisible(marker.bounds)
                await fixture.settle()
                fixture.click(in: marker, at: .init(x: marker.bounds.midX, y: marker.bounds.midY))
            }
        }
        guard let originalSearchField = fixture.textFields.first(where: { $0.placeholderString == "Search headphones" }) else {
            throw DiagnosticFailure(message: "Missing Auto EQ search field")
        }
        try fixture.snapshot(to: artifacts.appendingPathComponent("correction-auto.png"))
        for round in 0..<3 {
            for page in [DeviceCorrectionPage.convolution, .crossfeed, .automaticEQ] {
                try await press(identifier: "correction-page-\(page.rawValue)")
                await fixture.settle()
                try fixture.snapshot(to: artifacts.appendingPathComponent("selected-\(page.rawValue).png"))
                try diagnosticRequire(fixture.views.contains { $0.identifier?.rawValue == "correction-content-\(page.rawValue)" },
                    "Correction selector did not display \(page.rawValue)")
                print("Correction \(round): selected \(page.rawValue)")
                fflush(stdout)
                if page == .automaticEQ {
                    try diagnosticRequire(fixture.textFields.contains { $0 === originalSearchField },
                        "Returning to Auto EQ recreated the editor and its unfinished draft")
                }
                if page == .convolution {
                    try diagnosticRequire(fixture.views.contains { $0.identifier?.rawValue == "correction-fir-all-channels" },
                        "Personal FIR correction did not display the shared all-channel editor")
                }
                if page == .automaticEQ {
                    let initial = fixture.scrollViews[0].documentView!.frame.height
                    try await press(identifier: "correction-auto-advanced", disclosure: true)
                    await fixture.settle()
                    try diagnosticRequire(abs(fixture.scrollViews[0].documentView!.frame.height - initial) > 10,
                        "Correction disclosure did not update the hosted section height")
                    try fixture.snapshot(to: artifacts.appendingPathComponent("correction-\(page.rawValue)-expanded.png"))
                    try await press(identifier: "correction-auto-advanced", disclosure: true)
                    await fixture.settle()
                    try diagnosticRequire(abs(fixture.scrollViews[0].documentView!.frame.height - initial) < 1,
                        "Correction disclosure left stale height after collapse")
                }
            }
        }
        print("UI12: Device Correction navigation and repeated disclosures update their hosted height")
    }

    private static func spectrumPresentation(artifacts: URL) async throws {
        let spectrum = SpectrumAnalyzer()
        let profileID = UUID()
        let model = ProfileEditorGraphModel()
        let bands = [EQBand(kind: .peaking, frequency: 100, gain: 6, q: 1),
                     EQBand(kind: .peaking, frequency: 1000, gain: -6, q: 1)]
        model.calculate(parsed: ParsedEQ(preampDB: 0, bands: bands, warnings: []), sampleRate: 48000)
        spectrum.setPreviewPoints([SpectrumPoint(frequency: 100, db: -30), SpectrumPoint(frequency: 1000, db: -30)], profileID: profileID)
        let fixture = WindowFixture(ScrollView {
            VStack {
                LiveSpectrumPanels(spectrum: spectrum, profileID: profileID, graphModel: model)
                StableEditorSection(revision: 0) {
                EqualizerBandScrollView(bandCount: bands.count) { width in
                    GraphicEqualizerBands(bands: .constant(bands), spectrum: spectrum, profileID: profileID,
                        responsePoints: [.init(frequency: 100, gainDB: 6), .init(frequency: 1000, gainDB: -6)],
                        setKind: EQEditorSupport.setKind, columnWidth: width)
                }
                }
            }.padding(16)
        }, size: .init(width: 900, height: 800))
        defer { fixture.close() }
        await fixture.settle()
        let fields = fixture.textFields.filter { $0.placeholderString == "Hz" }
        try diagnosticRequire(fields.count == 2 && fields.allSatisfy { !$0.stringValue.isEmpty && $0.bounds.width >= 60 && $0.bounds.height >= 18 },
            "EQ frequency digits are missing or clipped")
        guard let pre = fixture.views.first(where: { $0.identifier?.rawValue == "spectrum-pre-card" }),
              let post = fixture.views.first(where: { $0.identifier?.rawValue == "spectrum-post-card" }) else {
            throw DiagnosticFailure(message: "Missing spectrum cards")
        }
        let preRect = pre.convert(pre.bounds, to: fixture.host), postRect = post.convert(post.bounds, to: fixture.host)
        try diagnosticRequire(abs(preRect.height - postRect.height) < 0.5 && abs(preRect.minY - postRect.minY) < 0.5,
            "Spectrum cards have different heights or top edges")
        try fixture.snapshot(to: artifacts.appendingPathComponent("live-spectrum-and-eq.png"))
        fixture.window.appearance = NSAppearance(named: .darkAqua)
        await fixture.settle()
        try diagnosticRequire(fields.allSatisfy { $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua && !$0.stringValue.isEmpty },
            "Hosted frequency fields did not follow dark appearance")
        try fixture.snapshot(to: artifacts.appendingPathComponent("live-spectrum-and-eq-dark.png"))
        fixture.resize(width: 480, height: 800)
        await fixture.settle()
        try diagnosticRequire((fixture.scrollViews[0].documentView?.frame.width ?? 0) <= 481,
            "Spectrum cards overflow a narrow window")
        print("UI13: Live spectrum, boost/cut meters, and populated frequency fields rendered")
        let focusFields = fixture.textFields.filter { $0.placeholderString == "Hz" }
        try diagnosticRequire(focusFields.count == 2, "Resizing lost a frequency control")
        focusFields[0].scrollToVisible(focusFields[0].bounds)
        try diagnosticRequire(fixture.window.makeFirstResponder(focusFields[0]), "Frequency control rejected keyboard focus")
        var visited: Set<ObjectIdentifier> = [ObjectIdentifier(focusFields[0])]
        for _ in 0..<20 {
            fixture.window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!)
            await fixture.settle()
            let field = (fixture.window.firstResponder as? NSTextView)?.delegate as? NSTextField
                ?? fixture.window.firstResponder as? NSTextField
            if let field { visited.insert(ObjectIdentifier(field)) }
            if focusFields.allSatisfy({ visited.contains(ObjectIdentifier($0)) }) { break }
        }
        try diagnosticRequire(focusFields.allSatisfy { visited.contains(ObjectIdentifier($0)) },
            "Keyboard navigation cannot leave an EQ band's focus group")
        fixture.window.makeFirstResponder(nil)
        print("UI16: Tab navigation crosses EQ-band focus groups in a narrow window")
    }

    private static func nativeDisclosureAlignment() async throws {
        let state = DisclosureState()
        let fixture = WindowFixture(DisclosureFixture(state: state), size: .init(width: 600, height: 600))
        defer { fixture.close() }
        await fixture.settle()
        guard let label = fixture.views.first(where: { $0.identifier?.rawValue == "alignment-label" }),
              let button = fixture.views.first(where: { $0.identifier?.rawValue == "alignment-button" }),
              let title = fixture.views.first(where: { $0.identifier?.rawValue == "disclosure-label" }) else {
            throw DiagnosticFailure(message: "Missing native alignment controls")
        }
        guard let field = fixture.textFields.first(where: { $0.placeholderString == "Alignment field" }) else {
            throw DiagnosticFailure(message: "Missing native alignment field")
        }
        let fieldBaseline = label.convert(label.bounds, to: fixture.host).midY - field.convert(field.bounds, to: fixture.host).midY
        let baseline = label.convert(label.bounds, to: fixture.host).midY - button.convert(button.bounds, to: fixture.host).midY
        for _ in 0..<8 {
            let wasExpanded = state.expanded
            let oldY = label.convert(label.bounds, to: fixture.host).midY
            fixture.click(in: title, at: .init(x: title.bounds.midX, y: title.bounds.midY))
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(16))
                let delta = label.convert(label.bounds, to: fixture.host).midY - button.convert(button.bounds, to: fixture.host).midY
                let fieldDelta = label.convert(label.bounds, to: fixture.host).midY - field.convert(field.bounds, to: fixture.host).midY
                try diagnosticRequire(abs(delta - baseline) < 1 && abs(fieldDelta - fieldBaseline) < 1,
                    "Native controls and text moved at different speeds during disclosure")
            }
            try diagnosticRequire(state.expanded != wasExpanded && abs(label.convert(label.bounds, to: fixture.host).midY - oldY) > 190,
                "Alignment test did not actually expand/collapse the controls")
        }
        print("UI14: Native buttons and text remain aligned across eight disclosure changes, sampled every 16ms")
    }

    private static func steppedSliderPrecision() async throws {
        var value = 0.0
        let fixture = WindowFixture(SteppedValueSlider(value: Binding(get: { value }, set: { value = $0 }),
            in: 0...2, step: 0.01).padding(20), size: .init(width: 400, height: 100))
        defer { fixture.close() }
        await fixture.settle()
        guard let slider = fixture.views.compactMap({ $0 as? NSSlider }).first,
              let action = slider.action else { throw DiagnosticFailure(message: "Missing native stepped slider") }
        try diagnosticRequire(slider.numberOfTickMarks == 0, "Fine-grained slider created hundreds of native tick marks")
        slider.doubleValue = slider.minValue + (slider.maxValue - slider.minValue) * (0.337 / 2)
        NSApp.sendAction(action, to: slider.target, from: slider)
        try diagnosticRequire(abs(value - 0.34) < 0.000001, "Fine-grained slider lost its numeric step: \(value)")
        fixture.window.makeFirstResponder(slider)
        let arrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
            context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)!
        fixture.window.sendEvent(arrow)
        await fixture.settle()
        try diagnosticRequire(abs(value - 0.35) < 0.000001, "Keyboard adjustment did not use the numeric step: \(value)")
        print("UI15: Native slider and keyboard retain 0.01 precision without generating tick marks")
    }

    private static func scrollingCadence() async throws {
        UIRenderPerformance.startMonitoring()
        let interval = UIRenderPerformance.meterPollMilliseconds
        let transition = UIRenderPerformance.animatedLevelTransitionDuration
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        let same = interval == UIRenderPerformance.meterPollMilliseconds
            && transition == UIRenderPerformance.animatedLevelTransitionDuration
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: nil)
        try diagnosticRequire(same, "Scrolling reduced the meter cadence or animation speed")
        print("UI09: Live scrolling preserves meter publication and interpolation timing")
    }

    @MainActor
    final class WindowFixture<Content: View> {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        init(_ content: Content, size: NSSize) {
            host = NSHostingView(rootView: AnyView(content.background(Color(nsColor: .windowBackgroundColor))))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: size)
            host.autoresizingMask = [.width, .height]
            window = NSWindow(contentRect: NSRect(origin: .init(x: -10000, y: -10000), size: size),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        func resize(width: CGFloat, height: CGFloat) { window.setContentSize(.init(width: width, height: height)) }
        func settle() async {
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        var scrollViews: [NSScrollView] { descendants(host).compactMap { $0 as? NSScrollView } }
        func close() { window.close() }
        func snapshot(to url: URL) throws {
            for view in views { view.needsDisplay = true }
            host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            window.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: url) }
        }
        var views: [NSView] { descendants(host) }
        var textFields: [NSTextField] { views.compactMap { $0 as? NSTextField } }
        func edit(_ field: NSTextField, text: String) async throws {
            window.makeKeyAndOrderFront(nil)
            try diagnosticRequire(window.makeFirstResponder(field), "Text field refused keyboard focus")
            await settle()
            guard let editor = field.currentEditor() as? NSTextView else {
                throw DiagnosticFailure(message: "Missing native field editor")
            }
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            await settle()
        }
        func click(in view: NSView, at point: NSPoint) {
            let location = view.convert(point, to: nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
        }
        private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    }

    private final class ScrollProbeState { var enabled: Bool? }
    private final class EditorProbeState { var appearances = 0 }
    private struct EditorProbe: View {
        let state: EditorProbeState
        @State private var text = ""
        var body: some View {
            TextField("Draft", text: $text).onAppear { state.appearances += 1 }
        }
    }
    private struct ScrollEnvironmentProbe: NSViewRepresentable {
        @Environment(\.isScrollEnabled) private var enabled
        let state: ScrollProbeState
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) { state.enabled = enabled }
    }
    private final class DisclosureState: ObservableObject {
        @Published var expanded = false
    }
    private struct DisclosureMarker: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView(); view.identifier = .init("below-disclosure"); return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }
    private struct DisclosureFixture: View {
        @ObservedObject var state: DisclosureState
        var body: some View {
            ScrollView {
                VStack(alignment: .leading) {
                    DisclosureGroup("Advanced", isExpanded: $state.expanded) {
                        Text("Settings").frame(height: 200)
                    }
                    Button("Below") {}.background(DisclosureMarker())
                    HStack {
                        Text("Aligned label").uiInteractionAnchor("alignment-label")
                        Button("Alignment action") {}.uiInteractionAnchor("alignment-button")
                        TextField("Alignment field", text: .constant("1.0")).frame(width: 80)
                    }
                }.padding(24)
            }
            .disclosureGroupStyle(SectionDisclosureStyle())
        }
    }
}
#endif

// Native frame anchors exist only in the UI diagnostic executable's test mode.
// Tests send real mouse events at these controls, without hard-coded pixels.
extension View {
    @ViewBuilder
    func uiInteractionAnchor(_ id: String) -> some View {
        #if DEBUG
        if UIInteractionAnchor.isEnabled {
            background(UIInteractionAnchor(id: id))
        } else { self }
        #else
        self
        #endif
    }
}
#if DEBUG
private struct UIInteractionAnchor: NSViewRepresentable {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--ui-self-test") || ProcessInfo.processInfo.arguments.contains("--ui-app-self-test")
    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    let id: String
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        view.identifier = NSUserInterfaceItemIdentifier(id)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { view.identifier = NSUserInterfaceItemIdentifier(id) }
}
#endif
