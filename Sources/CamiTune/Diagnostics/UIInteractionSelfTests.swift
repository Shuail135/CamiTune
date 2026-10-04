import UniformTypeIdentifiers
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
        if ProcessInfo.processInfo.environment["CAMITUNE_UI_ROOM_RESULT_ONLY"] == "1" {
            try await roomCorrectionResultInteractions(artifacts: artifacts)
            return
        }
        if ProcessInfo.processInfo.environment["CAMITUNE_UI_ROOM_RECORDER_ONLY"] == "1"
            || ProcessInfo.processInfo.environment["CAMITUNE_UI_ROOM_IMPORT_ONLY"] == "1" {
            for test in DeveloperSelfTests.roomRecordingCases() {
                let result = try await test.execute()
                print("\(test.id): \(result.summary)")
            }
            try await roomRecorderInteractions(artifacts: artifacts)
            return
        }
        if ProcessInfo.processInfo.environment["CAMITUNE_UI_ROOM_ONLY"] == "1" {
            try await roomCorrectionResultInteractions(artifacts: artifacts)
            try await roomCorrectionInteractions(artifacts: artifacts)
            try await roomRecorderInteractions(artifacts: artifacts)
            return
        }
        if ProcessInfo.processInfo.environment["CAMITUNE_UI_SEARCH_ONLY"] != "1",
           ProcessInfo.processInfo.environment["CAMITUNE_UI_CORRECTION_ONLY"] != "1" {
            try await roomCorrectionResultInteractions(artifacts: artifacts)
            try await roomMenuTracking()
            try await roomCorrectionInteractions(artifacts: artifacts)
            try await roomRecorderInteractions(artifacts: artifacts)
        }
        try await autoEQSearchSelection()
        if ProcessInfo.processInfo.environment["CAMITUNE_UI_SEARCH_ONLY"] == "1" { return }
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

    private static func autoEQSearchSelection() async throws {
        for placeholder in ["Search IEMs", "Search headphones", "Search speakers"] {
            let state = SearchSelectionState()
            let fixture = WindowFixture(SearchSelectionFixture(state: state, placeholder: placeholder),
                size: .init(width: 500, height: 350))
            defer { fixture.close() }
            await fixture.settle()
            guard let field = fixture.textFields.first(where: { $0.placeholderString == placeholder }) else {
                throw DiagnosticFailure(message: "Missing \(placeholder) field")
            }
            try await fixture.edit(field, text: "Fixture")
            let resultID = "autoeq-search-result-fixture"
            try diagnosticRequire(fixture.views.contains { $0.identifier?.rawValue == resultID },
                "Searching did not display a result for \(placeholder)")

            // The profile editor clears text focus after mouse-down, before a
            // result button receives mouse-up. Reproduce that focus transition.
            fixture.window.makeFirstResponder(nil)
            await fixture.settle()
            guard let result = fixture.views.first(where: { $0.identifier?.rawValue == resultID }) else {
                throw DiagnosticFailure(message: "\(placeholder) removed its result before selection when text focus cleared")
            }
            fixture.click(in: result, at: .init(x: result.bounds.midX, y: result.bounds.midY))
            await fixture.settle()
            try diagnosticRequire(state.selections == 1, "\(placeholder) did not select its result exactly once")
            try diagnosticRequire(!fixture.views.contains { $0.identifier?.rawValue == resultID },
                "\(placeholder) did not dismiss results after selection")

            try await fixture.edit(field, text: "Fixture")
            try diagnosticRequire(fixture.views.contains { $0.identifier?.rawValue == resultID },
                "\(placeholder) did not reopen results when editing again")
            fixture.window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
            await fixture.settle()
            try diagnosticRequire(!fixture.views.contains { $0.identifier?.rawValue == resultID },
                "\(placeholder) did not dismiss results on Escape")
        }
        print("UI17: IEM, headphone, and speaker search results survive focus clearing, select once, reopen, and dismiss on Escape")
    }

    private final class SearchSelectionState: ObservableObject {
        @Published var query = ""
        var selections = 0
    }
    private struct SearchSelectionEntry: Identifiable {
        let id = "fixture"
    }
    private struct SearchSelectionFixture: View {
        @ObservedObject var state: SearchSelectionState
        let placeholder: String
        var body: some View {
            VStack {
                AutoEQSearchField(placeholder: placeholder, query: $state.query,
                    results: [SearchSelectionEntry()], title: { _ in "Fixture device" }) { _ in
                        state.selections += 1
                        state.query = "Fixture device"
                    }
                Spacer()
            }.padding(20)
        }
    }

    private static func correctionInteractions(artifacts: URL) async throws {
        // Catalog completion removes a loading row; finish it before comparing disclosure heights.
        _ = try? await AutoEQCatalogPresentationCache.shared.load(endpoint: .headphones)
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
                    let collapsed = fixture.scrollViews[0].documentView!.frame.height
                    if abs(collapsed - initial) >= 1 {
                        try fixture.snapshot(to: artifacts.appendingPathComponent("correction-collapse-failure.png"))
                    }
                    try diagnosticRequire(abs(collapsed - initial) < 1,
                        "Correction disclosure left stale height after collapse: \(initial) -> \(collapsed)")
                }
            }
        }
        print("UI12: Device Correction navigation and repeated disclosures update their hosted height")
    }

    private final class RoomMenuState: NSObject, ObservableObject {
        @Published var selection: Int? = nil
        @Published var update = 0
        var trackedMenu: NSMenu?
        var closed = false
        var remainedOpen = false
        var timedOut = false
        var dismiss: (@MainActor () -> Void)?
        @MainActor @objc func dismissMenu() { dismiss?() }
    }
    private struct RoomMenuFixture: View {
        @ObservedObject var state: RoomMenuState
        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                RoomCorrectionMenu(label: "Test selection", selection: $state.selection, options: [nil, 1, 2],
                    title: { $0.map { "Option \($0)" } ?? "Auto" }).frame(width: 260)
                Text("Background update \(state.update)")
                Spacer()
            }.padding(20)
        }
    }
    private static func roomMenuTracking() async throws {
        let state = RoomMenuState()
        let fixture = WindowFixture(RoomMenuFixture(state: state), size: .init(width: 400, height: 240))
        defer { state.dismiss = nil; fixture.close() }
        await fixture.settle()
        let center = NotificationCenter.default
        let opened = center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            state.trackedMenu = note.object as? NSMenu
        }
        let closed = center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { note in
            if note.object as? NSMenu === state.trackedMenu { state.closed = true }
        }
        defer { center.removeObserver(opened); center.removeObserver(closed) }
        for dismissal in ["outside", "selection"] {
            state.trackedMenu = nil; state.closed = false; state.remainedOpen = false; state.timedOut = false
            guard let marker = fixture.views.first(where: { $0.identifier?.rawValue == "room-menu-Test selection" }) else {
                throw DiagnosticFailure(message: "Missing room menu")
            }
            // Timers also run in AppKit's nested menu-tracking run loop.
            let updates = Timer(timeInterval: 0.05, repeats: true) { _ in
                state.update += 1
            }
            state.dismiss = {
                state.remainedOpen = state.trackedMenu != nil && !state.closed && state.selection == nil
                if dismissal == "outside" {
                    let location = fixture.host.convert(NSPoint(x: 350, y: 200), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        NSApp.postEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: false)
                    }
                } else {
                    if let menu = state.trackedMenu, let index = menu.items.firstIndex(where: { $0.title == "Option 2" }) {
                        menu.performActionForItem(at: index)
                    }
                    state.trackedMenu?.cancelTracking()
                }
            }
            let dismiss = Timer(timeInterval: 0.8, target: state, selector: #selector(RoomMenuState.dismissMenu), userInfo: nil, repeats: false)
            let watchdog = Timer(timeInterval: 2, repeats: false) { _ in
                if !state.closed { state.timedOut = true; state.trackedMenu?.cancelTracking() }
            }
            for timer in [updates, dismiss, watchdog] { RunLoop.main.add(timer, forMode: .common) }
            fixture.click(in: marker, at: .init(x: marker.bounds.midX, y: marker.bounds.midY))
            try await Task.sleep(for: .milliseconds(1100))
            for timer in [updates, dismiss, watchdog] { timer.invalidate() }
            try diagnosticRequire(state.remainedOpen, "Room menu closed or selected an item during unrelated UI updates (\(dismissal))")
            try diagnosticRequire(state.closed && !state.timedOut, "Room menu did not dismiss on \(dismissal)")
            try diagnosticRequire(dismissal == "selection" ? state.selection == 2 : state.selection == nil,
                "Room menu did not preserve/commit the expected selection on \(dismissal)")
        }
        print("Room Correction menus: stay open during updates; outside click preserves selection; explicit menu actions commit selection")
    }

    private static func roomRecorderInteractions(artifacts: URL) async throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        var profile = DiagnosticSandbox.profile()
        profile.endpointKind = .speakers
        profile.speakerTopology = SpeakerTopology(deviceUID: profile.outputDeviceUID,
            sampleRate: Double(profile.sampleRate), declaredChannelCount: 2,
            endpoints: (0..<2).map { .init(id: .init(deviceUID: profile.outputDeviceUID, channelIndex: $0),
                role: $0 == 0 ? .left : .right, displayName: "Speaker \($0 + 1)", connectionState: .confirmedByUser) })
        let context = try profile.roomMeasurementContext()
        let editor = RoomCorrectionEditorState()
        box.profiles.profiles = [profile]
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
        let binding = Binding(get: { box.profiles.profiles[0] }, set: { box.profiles.update($0) })
        let fixture = WindowFixture(ScrollView { RoomCorrectionView(state: state, profile: binding, editor: editor).padding(16) },
            size: .init(width: 600, height: 800))
        defer { fixture.close() }
        await fixture.settle(); try await Task.sleep(for: .milliseconds(600))
        func marker(_ id: String) throws -> NSView {
            guard let view = fixture.views.first(where: { $0.identifier?.rawValue == id }) else {
                throw DiagnosticFailure(message: "Missing recorder action \(id)")
            }
            return view
        }
        func press(_ id: String, fraction: CGFloat = 0.5, verticalFraction: CGFloat = 0.5) async throws {
            if id.hasPrefix("room-position-"), let row = try? marker("room-position-navigation") {
                row.scrollToVisible(row.bounds); await fixture.settle()
            }
            let view = try marker(id)
            view.scrollToVisible(view.bounds); await fixture.settle()
            fixture.click(in: view, at: .init(x: view.bounds.width * fraction, y: view.bounds.height * verticalFraction))
            await fixture.settle()
        }
        func requirePositions(_ count: Int) throws {
            for index in 0..<count { _ = try marker("room-position-\(index)") }
            try diagnosticRequire((try? marker("room-position-\(count)")) == nil, "Recorder created extra positions")
            try diagnosticRequire((try? marker("room-position-editing")) == nil,
                "Phone recording must not expose Adjust, Skip, Remove, or Add Position")
        }
        if ProcessInfo.processInfo.environment["CAMITUNE_UI_ROOM_IMPORT_ONLY"] == "1" {
            // Isolate import lifecycle checks from the separate microphone,
            // position-navigation and native-slider interaction checks.
            editor.setSourceKind(.recorder, profile: profile)
            editor.beginSession(profile: profile)
            for index in 0..<(editor.session?.positions.count ?? 0) {
                editor.selectPosition(index)
                let blocks = editor.plannedBlocks(selectedChannel: nil)
                guard let initial = editor.session else { throw DiagnosticFailure(message: "Missing import fixture session") }
                editor.session = try editor.completedRecorderPosition(blocks, in: initial)
                editor.advanceAfterPlayback()
            }
            await fixture.settle()
        } else {
            _ = try marker("room-test-volume")
            guard let slider = fixture.views.compactMap({ $0 as? NSSlider }).first else {
                throw DiagnosticFailure(message: "Missing native test-volume slider")
            }
            try diagnosticRequire(slider.accessibilityPerformIncrement(), "Test volume must accept native slider adjustments")
            await fixture.settle()
            try diagnosticRequire(editor.testVolumeDB == 1, "Test-volume adjustment did not reach the measurement state")
            try await press("room-correction-start")
            try diagnosticRequire(editor.session?.source.kind == .microphone && !editor.busy && editor.error == nil
                && editor.session?.blocks.isEmpty == true, "Start Measurement must prepare the Mac microphone without starting capture/playback")
            _ = try marker("room-measurement-channels")
            try fixture.snapshot(to: artifacts.appendingPathComponent("room-recording-type.png"))
            try await press("room-recording-type", fraction: 0.35, verticalFraction: 0.25)
            try diagnosticRequire(editor.source.kind == .recorder, "Recording type must remain switchable after Start Measurement")
            try requirePositions(5)
            try diagnosticRequire((try? marker("room-new-session")) == nil, "New Session must not be exposed")
            try diagnosticRequire((try? marker("room-measurement-channels")) == nil, "Phone recording must play all speakers without a channel chooser")
            for count in [5, 9] {
                try await press("room-recorder-position-count", fraction: count == 5 ? 0.25 : 0.75)
                try requirePositions(count)
                try await press("room-position-\(count - 1)")
                guard let map = fixture.views.compactMap({ $0 as? SpeakerRoomNSView }).first else {
                    throw DiagnosticFailure(message: "Missing phone measurement map")
                }
                let expected = RoomMeasurementGeometry.recorderPositions(center: context.listener, radius: 0.2,
                    count: count == 5 ? .five : .nine)
                try diagnosticRequire(map.configuration?.measurementPoint == expected.last && map.configuration?.measurementRadius == 0,
                    "Phone measurement marker must show the exact fixed point")
                map.scrollToVisible(map.bounds); await fixture.settle()
                try fixture.snapshot(to: artifacts.appendingPathComponent("room-recorder-\(count).png"))
            }
            editor.selectPosition(0)
            for index in 0..<9 {
                try diagnosticRequire(editor.positionIndex == index, "Phone guide must advance the graph after each completed position")
                let blocks = editor.plannedBlocks(selectedChannel: 0)
                guard let initial = editor.session else { throw DiagnosticFailure(message: "Missing prepared phone session") }
                editor.session = try editor.completedRecorderPosition(blocks, in: initial)
                editor.advanceAfterPlayback()
                await fixture.settle()
                _ = try marker("room-recorder-next")
                try diagnosticRequire(editor.recorderActionTitle == (index == 8 ? "Import Recording…" : "Next"),
                    "Phone footer must guide every position before offering a single import")
            }
            try fixture.snapshot(to: artifacts.appendingPathComponent("room-recorder-import.png"))
            try await press("room-recorder-next")
            for _ in 0..<100 where !NSApp.windows.contains(where: { $0 is NSOpenPanel && $0.isVisible }) {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let panel = NSApp.windows.compactMap({ $0 as? NSOpenPanel }).first(where: \.isVisible) else {
                throw DiagnosticFailure(message: "Import Recording did not open its file picker")
            }
            try diagnosticRequire(panel.allowedContentTypes == [.audio] && !panel.canChooseDirectories && !panel.allowsMultipleSelection,
                "Recording import must choose a single audio file")
            panel.cancel(nil)
            await fixture.settle()
            try diagnosticRequire(editor.error == nil, "Cancelling the picker must not report an import failure")
        }

        guard var imported = editor.session else { throw DiagnosticFailure(message: "Missing recorder session") }
        var recording = RoomRecordingReference(fileName: "fixture.m4a", sourceFormat: "AAC", isLossy: true,
            blockIDs: imported.blocks.map(\.id))
        let legacyData = try PropertyListEncoder().encode(recording)
        let legacyRecording = try PropertyListDecoder().decode(RoomRecordingReference.self, from: legacyData)
        try diagnosticRequire(legacyRecording.originalFileName == nil && legacyRecording.fileName == recording.fileName,
            "Saved recordings without display metadata must remain readable")
        recording.originalFileName = "Living room recording.m4a"
        imported.recordings = [recording]
        imported.positions[0].observations = [.init(channel: 0, bins: (1...12).map {
            .init(frequency: Double($0) * 100, magnitudeDB: 0)
        })]
        try RoomMeasurementStore().save(imported)
        let recordingURL = try RoomMeasurementStore().recordingURL(recording, sessionID: imported.id)
        try Data("retained recording fixture".utf8).write(to: recordingURL)
        let restored = try RoomMeasurementStore().load(imported.id)
        try diagnosticRequire(restored.recordings.first?.originalFileName == recording.originalFileName,
            "The imported filename must survive reopening the session")
        editor.session = imported
        editor.persistSession()
        for _ in 0..<500 where editor.busy { try await Task.sleep(for: .milliseconds(20)) }
        editor.tab = .analysis
        await fixture.settle()
        func requireHiddenRecordingControls() throws {
            try diagnosticRequire((try? marker("room-imported-recording")) == nil
                && (try? marker("room-recording-remove")) == nil,
                "Recording file controls must only appear on Measure")
        }
        func requireCorrectionCreation() async throws {
            let previousDate = editor.calculatedResult?.generatedAt
            let profileBeforeCalculation = box.profiles.profiles[0]
            try await press("room-correction-create")
            for _ in 0..<500 where editor.busy { try await Task.sleep(for: .milliseconds(20)) }
            await fixture.settle()
            let result = editor.calculatedResult
            try diagnosticRequire(box.profiles.profiles[0] == profileBeforeCalculation, "Calculating must leave saved processing unchanged")
            _ = try marker("room-correction-details")
            try diagnosticRequire(editor.error == nil && result?.sessionID == imported.id
                && result?.generatedAt != previousDate && result?.positionCount == imported.usablePositionCount
                && editor.tab == .correction && editor.session?.blocks == imported.blocks,
                "Recalculate must rebuild imported analysis: error=\(editor.error ?? "none"), result=\(String(describing: result?.sessionID)), expected=\(imported.id), positions=\(String(describing: result?.positionCount)), tab=\(editor.tab), busy=\(editor.busy), blocksMatch=\(editor.session?.blocks == imported.blocks), changed=\(result?.generatedAt != previousDate)")
            try requireHiddenRecordingControls()
        }
        try requireHiddenRecordingControls()
        try diagnosticRequire((try? marker("room-correction-remeasure")) == nil
            && (try? marker("room-correction-recalculate")) == nil,
            "Imported analysis must use the Next workflow without a recalculation action")
        try await press("room-correction-next")
        try await requireCorrectionCreation()
        try diagnosticRequire((try? marker("room-correction-remeasure")) == nil
            && (try? marker("room-correction-recalculate")) == nil,
            "Imported analysis must not expose Re-measure or a separate WAV recalculation action")
        try diagnosticRequire((try? marker("room-recording-reanalyze")) == nil,
            "The recording footer must not expose Reanalyze")
        try await press("room-correction-tab-measure")
        try diagnosticRequire((try? marker("room-recorder-next")) == nil,
            "An imported recording must replace the import action")
        _ = try marker("room-correction-next")
        for width: CGFloat in [500, 950] {
            fixture.resize(width: width, height: 800); await fixture.settle()
            let filename = try marker("room-imported-recording")
            let remove = try marker("room-recording-remove")
            let next = try marker("room-correction-next")
            let filenameFrame = filename.convert(filename.bounds, to: fixture.host)
            let removeFrame = remove.convert(remove.bounds, to: fixture.host)
            let nextFrame = next.convert(next.bounds, to: fixture.host)
            try diagnosticRequire(abs(filenameFrame.midY - nextFrame.midY) < 2
                && abs(removeFrame.midY - nextFrame.midY) < 2
                && filenameFrame.width > 40 && filenameFrame.maxX <= removeFrame.minX
                && removeFrame.maxX <= nextFrame.minX && nextFrame.maxX <= fixture.host.bounds.maxX,
                "The filename and remove control must share the Next row and fit the window")
        }
        fixture.resize(width: 600, height: 800); await fixture.settle()
        try fixture.snapshot(to: artifacts.appendingPathComponent("room-recorder-attached.png"))
        try await press("room-recording-remove")
        for _ in 0..<100 where editor.busy { try await Task.sleep(for: .milliseconds(20)) }
        await fixture.settle()
        let detached = try RoomMeasurementStore().load(imported.id)
        try diagnosticRequire(editor.error == nil && detached.recordings.isEmpty
            && detached.positions.allSatisfy { $0.observations.isEmpty }
            && detached.blocks == imported.blocks && FileManager.default.fileExists(atPath: recordingURL.path),
            "Removing an import must detach its measurements, preserve playback and retain the file")
        _ = try marker("room-recorder-next")
        try diagnosticRequire(editor.recorderPlaybackComplete && editor.recorderActionTitle == "Import Recording…",
            "Removing a recording must restore Import without requiring another measurement sequence")
        try await press("room-recorder-next")
        for _ in 0..<100 where !NSApp.windows.contains(where: { $0 is NSOpenPanel && $0.isVisible }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let replacementPanel = NSApp.windows.compactMap({ $0 as? NSOpenPanel }).first(where: \.isVisible) else {
            throw DiagnosticFailure(message: "Removing the file must allow importing another recording")
        }
        replacementPanel.cancel(nil); await fixture.settle()

        // A replacement import automatically analyzes the file. Next leads to
        // the existing correction settings and Create/Update action.
        editor.session = imported
        editor.persistSession()
        for _ in 0..<500 where editor.busy { try await Task.sleep(for: .milliseconds(20)) }
        editor.tab = .analysis
        await fixture.settle()
        try requireHiddenRecordingControls()
        try diagnosticRequire((try? marker("room-correction-recalculate")) == nil,
            "Reimport must not bring back the recalculation action")
        try await press("room-correction-next")
        try await requireCorrectionCreation()
        try await press("room-correction-tab-measure")
        _ = try marker("room-imported-recording")

        func answerReset(_ title: String) async throws {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let content = fixture.window.attachedSheet?.contentView,
                  let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                throw DiagnosticFailure(message: "Missing reset confirmation button \(title)")
            }
            button.performClick(nil)
            await fixture.settle()
            for _ in 0..<100 where editor.busy { try await Task.sleep(for: .milliseconds(20)) }
        }
        let sessionBeforeReset = editor.session?.id
        try await press("room-correction-reset")
        try diagnosticRequire(editor.session?.id == sessionBeforeReset, "Opening Reset must preserve the session")
        try await answerReset("Cancel")
        try diagnosticRequire(editor.session?.id == sessionBeforeReset, "Cancelling Reset must preserve the session")
        try await press("room-correction-reset")
        try await answerReset("Reset")
        try diagnosticRequire(editor.session == nil && editor.comparison == nil && editor.source.kind == .microphone
            && editor.testVolumeDB == 0 && editor.recorderPositionCount == .five && editor.error == nil,
            "Reset must restore a fresh Room Correction workflow")
        _ = try marker("room-correction-start")
        try diagnosticRequire((try? marker("room-imported-recording")) == nil && (try? marker("room-recorder-next")) == nil,
            "Reset must clear the imported file and require a new measurement setup")
        try await press("room-calibration-import")
        for _ in 0..<100 where !NSApp.windows.contains(where: { $0 is NSOpenPanel && $0.isVisible }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let calibration = NSApp.windows.compactMap({ $0 as? NSOpenPanel }).first(where: \.isVisible) else {
            throw DiagnosticFailure(message: "Calibration picker must still open after recording import and reset")
        }
        try diagnosticRequire(calibration.allowedContentTypes == [.plainText, .data], "Calibration must use its own file types")
        calibration.cancel(nil); await fixture.settle()
        print("Room recorder: silent preparation, recording type/count switching, all-speaker sequence, and final single-file import")
    }

    private static func systemMapPan(_ map: SpeakerRoomNSView, window: NSWindow, label: String) async throws {
        guard ProcessInfo.processInfo.environment["CAMITUNE_UI_SYSTEM_MOUSE"] == "1" else { return }
        try diagnosticRequire(CGPreflightPostEventAccess(), "System mouse test requires event-posting access")
        let originalFrame = window.frame
        let originalPointer = CGEvent(source: nil)?.location
        window.setFrameOrigin(.init(x: 100, y: 150))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(300))
        let origin = CGPoint(x: map.graph.minX + 10, y: map.graph.minY + 10)
        let screenTop = NSScreen.screens[0].frame.maxY
        var buttonDown = false
        func send(_ type: CGEventType, _ offset: CGPoint) {
            let local = CGPoint(x: origin.x + offset.x, y: origin.y + offset.y)
            let screen = window.convertPoint(toScreen: map.convert(local, to: nil))
            let event = CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: .init(x: screen.x, y: screenTop - screen.y), mouseButton: .left)!
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
        defer {
            if buttonDown { send(.leftMouseUp, .init(x: 1, y: 1)) }
            window.setFrame(originalFrame, display: true)
            if let originalPointer {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: originalPointer,
                    mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            map.resetViewport()
        }
        let clickStart = ProcessInfo.processInfo.systemUptime
        buttonDown = true
        send(.leftMouseDown, .zero)
        while map.lastMouseDownTime < clickStart && ProcessInfo.processInfo.systemUptime - clickStart < 0.5 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let clickMS = (map.lastMouseDownTime - clickStart) * 1000
        try diagnosticRequire(map.lastMouseDownTime >= clickStart && clickMS < 50,
            "\(label) system mouse-down was not delivered promptly: \(clickMS) ms")
        let dragStart = ProcessInfo.processInfo.systemUptime
        send(.leftMouseDragged, .init(x: 1, y: 1))
        while map.lastDrawTime < dragStart && ProcessInfo.processInfo.systemUptime - dragStart < 0.5 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let frameMS = (map.lastDrawTime - dragStart) * 1000
        try diagnosticRequire(map.pan == CGPoint(x: 1, y: 1) && map.lastDrawTime >= dragStart && frameMS < 50,
            "\(label) system drag did not paint its first one-point movement promptly: \(frameMS) ms, pan \(map.pan)")
        send(.leftMouseUp, .init(x: 1, y: 1))
        buttonDown = false
        try await Task.sleep(for: .milliseconds(30))
        print("\(label) system mouse: click \(String(format: "%.2f", clickMS)) ms, first frame \(String(format: "%.2f", frameMS)) ms")
        fflush(stdout)
    }

    private static func roomCorrectionResultInteractions(artifacts: URL) async throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        var profile = DiagnosticSandbox.profile()
        profile.endpointKind = .speakers
        profile.speakerTopology = SpeakerTopology(deviceUID: profile.outputDeviceUID,
            sampleRate: Double(profile.sampleRate), declaredChannelCount: 2,
            endpoints: (0..<2).map { .init(id: .init(deviceUID: profile.outputDeviceUID, channelIndex: $0),
                role: $0 == 0 ? .left : .right, displayName: $0 == 0 ? "Left" : "Right", connectionState: .confirmedByUser) })
        let context = try profile.roomMeasurementContext()
        var position = RoomMeasurementPosition(coordinate: context.listener, isMain: true)
        position.observations = [.init(channel: 0, bins: (1...20).map { .init(frequency: Double($0) * 40, magnitudeDB: 0) })]
        let session = RoomMeasurementSession(context: context, source: .init(), positions: [position])
        try RoomMeasurementStore().save(session)
        var result = RoomCorrectionResult(sessionID: session.id, context: context,
            method: .iir, settings: .init(), lowHz: 25, highHz: 800, positionCount: 5)
        result.channelBands = [0: (0..<8).map { EQBand(kind: .peaking, frequency: Double(60 + $0 * 80), gain: -3, q: 2) },
                               1: [EQBand(kind: .peaking, frequency: 120, gain: -4.5, q: 3)]]
        var seat = SpatialSeatingCalibration(outputDeviceUID: profile.outputDeviceUID)
        seat.roomCorrectionSessionID = session.id; seat.roomCorrectionResult = result; seat.roomCorrectionEnabled = true
        profile.spatialSettings.seating = seat
        box.profiles.profiles = [profile]
        let editor = RoomCorrectionEditorState()
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
        let binding = Binding(get: { box.profiles.profiles[0] }, set: { box.profiles.update($0) })
        let fixture = WindowFixture(ScrollView { RoomCorrectionView(state: state, profile: binding, editor: editor).padding(16) },
            size: .init(width: 600, height: 850))
        defer { fixture.close() }
        await fixture.settle()
        for _ in 0..<100 where editor.busy { try await Task.sleep(for: .milliseconds(20)) }
        await fixture.settle()
        var gaps: [Double] = []
        func marker(_ id: String) throws -> NSView {
            guard let view = fixture.views.first(where: { $0.identifier?.rawValue == id }) else {
                throw DiagnosticFailure(message: "Missing correction result control \(id)")
            }
            return view
        }
        func press(_ id: String, measure: Bool = false) async throws {
            let view = try marker(id)
            view.scrollToVisible(view.bounds); await fixture.settle()
            let started = ProcessInfo.processInfo.systemUptime
            fixture.click(in: view, at: .init(x: view.bounds.midX, y: view.bounds.midY))
            if measure {
                var previous = started
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(16))
                    let now = ProcessInfo.processInfo.systemUptime
                    gaps.append((now - previous) * 1000); previous = now
                }
            }
            await fixture.settle()
            for _ in 0..<100 where editor.busy { try await Task.sleep(for: .milliseconds(20)) }
        }
        try diagnosticRequire((try? marker("room-correction-enabled")) == nil, "Room Correction must only calculate and import")
        _ = try marker("room-correction-import")
        try diagnosticRequire((try? marker("room-correction-back")) == nil && (try? marker("room-correction-compare")) == nil,
            "Correction must not expose Back or Compare")
        try await press("room-correction-remeasure")
        try diagnosticRequire(editor.tab == .measure, "Re-measure must return directly to Measure")
        try await press("room-correction-tab-correction", measure: true)
        try diagnosticRequire(editor.tab == .correction, "The Correction tab must open")
        for width: CGFloat in [600, 950] {
            fixture.resize(width: width, height: 850); await fixture.settle()
            editor.settings.method = .fir
            await fixture.settle()
            try diagnosticRequire((try? marker("room-correction-details")) == nil, "Calculation must start collapsed")
            for _ in 0..<3 {
                try await press("room-correction-calculation", measure: true)
                _ = try marker("room-correction-details")
                try diagnosticRequire(box.profiles.profiles[0].effectiveSpatialSettings.seating?.roomCorrectionResult == result,
                    "Showing details and editing draft settings must preserve the saved result")
                try fixture.snapshot(to: artifacts.appendingPathComponent("room-correction-details-\(Int(width)).png"))
                try await press("room-correction-tab-analysis", measure: true)
                try diagnosticRequire(editor.tab == .analysis, "Analysis navigation must respond")
                try await press("room-correction-tab-correction", measure: true)
                _ = try marker("room-correction-details")
                try await press("room-correction-calculation", measure: true)
                try diagnosticRequire((try? marker("room-correction-details")) == nil, "Calculation must collapse")
            }
        }
        let sorted = gaps.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print("Room correction results: max main-loop gap \(String(format: "%.2f", sorted.last ?? 0)) ms, p95 \(String(format: "%.2f", p95)) ms")
        try diagnosticRequire(p95 < 45 && (sorted.last ?? 0) < 150, "Correction disclosure and navigation exceeded their responsiveness budget")
        editor.settings = result.settings
        await fixture.settle()
        try await press("room-correction-calculation")
        let beforeImport = box.profiles.profiles[0]
        try await press("room-correction-import")
        try diagnosticRequire(editor.error == nil && editor.importRevision == 1,
            "Import must install calculated IIR: \(editor.error ?? "none")")
        try diagnosticRequire((try? marker("room-correction-details")) == nil, "Successful import must close Calculation")
        let imported = box.profiles.profiles[0]
        let processing = try imported.resolvedProcessing()
        try diagnosticRequire(processing.settings(forChannel: 0)?.bands.count == 8
            && processing.settings(forChannel: 1)?.bands.count == 1
            && imported.effectiveSpatialSettings.seating?.roomCorrectionEnabled == false,
            "Import must populate ordinary per-channel EQ and retire managed room stages")
        try await press("room-correction-calculation")
        try await press("room-correction-import")
        try diagnosticRequire(fixture.window.attachedSheet != nil && box.profiles.profiles[0] == imported,
            "Replacing existing channel EQ must ask first and leave processing untouched")
        func answerReplacement(_ title: String) async throws {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let content = fixture.window.attachedSheet?.contentView,
                  let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                throw DiagnosticFailure(message: "Missing replacement confirmation button \(title)")
            }
            button.performClick(nil); await fixture.settle()
            for _ in 0..<300 where editor.busy { try await Task.sleep(for: .milliseconds(20)) }
            await fixture.settle()
        }
        try await answerReplacement("Cancel")
        _ = try marker("room-correction-details")
        try diagnosticRequire(box.profiles.profiles[0] == imported && editor.importRevision == 1, "Cancel must preserve filters and the open calculation")
        try await press("room-correction-import")
        try await answerReplacement("Replace and Import")
        try diagnosticRequire(editor.error == nil && editor.importRevision == 2
            && (try? marker("room-correction-details")) == nil, "Confirmed replacement must import and collapse Calculation")
        await state.history.undo()
        await state.history.undo()
        let restored = box.profiles.profiles[0]
        let restoredProcessing = try restored.resolvedProcessing()
        let previousProcessing = try beforeImport.resolvedProcessing()
        try diagnosticRequire(restoredProcessing == previousProcessing, "Undo must restore the previous room correction and channel filters")
        await state.history.redo()
        let redoneProcessing = try box.profiles.profiles[0].resolvedProcessing()
        try diagnosticRequire(redoneProcessing == processing, "Redo must restore the imported filters")
        let beforeRecalculation = box.profiles.profiles[0]
        try await press("room-correction-create")
        try diagnosticRequire(editor.error == nil && editor.calculationRevision == 1
            && box.profiles.profiles[0] == beforeRecalculation,
            "Recalculating after import must preserve audio and accept its original measurements")
        _ = try marker("room-correction-details")
        try diagnosticRequire(!editor.canImport, "A calculation with no usable filters must not import")
        print("Room correction results: calculate/import controls, replacement confirmation, filter details, disclosure state and resizing passed")
    }

    private static func roomCorrectionInteractions(artifacts: URL) async throws {
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        var profile = DiagnosticSandbox.profile()
        profile.endpointKind = .speakers
        profile.speakerTopology = SpeakerTopology(deviceUID: profile.outputDeviceUID,
            sampleRate: Double(profile.sampleRate), declaredChannelCount: 2,
            endpoints: (0..<2).map { .init(id: .init(deviceUID: profile.outputDeviceUID, channelIndex: $0),
                role: $0 == 0 ? .left : .right, displayName: $0 == 0 ? "Left" : "Right", connectionState: .confirmedByUser) })
        let context = try profile.roomMeasurementContext()
        var position = RoomMeasurementPosition(coordinate: context.listener, isMain: true)
        position.observations = [.init(channel: 0, bins: (0..<80).map {
            .init(frequency: 25 * pow(2, Double($0) / 12), magnitudeDB: sin(Double($0) * 0.2) * 4)
        })]
        let analysisFixture = ProcessInfo.processInfo.environment["CAMITUNE_UI_ROOM_ANALYSIS_SESSION"]
        if let path = analysisFixture {
            let imported = try JSONDecoder().decode(RoomMeasurementSession.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            position.observations = imported.positions.first(where: \.isMain)?.observations ?? []
        }
        let extraPositions = (1..<5).map { index in
            RoomMeasurementPosition(coordinate: .init(x: Float(index) * 0.1, y: -Float(index) * 0.05, z: 0))
        }
        var session = RoomMeasurementSession(context: context, source: .init(), positions: [position] + extraPositions)
        if analysisFixture != nil { session.measurementAnalysisVersion = 2 }
        try RoomMeasurementStore().save(session)
        var seat = SpatialSeatingCalibration(outputDeviceUID: profile.outputDeviceUID)
        seat.roomCorrectionSessionID = session.id; profile.spatialSettings.seating = seat
        box.profiles.profiles = [profile]
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
        let binding = Binding(get: { box.profiles.profiles[0] }, set: { box.profiles.update($0) })
        let setupFixture = WindowFixture(ScrollView {
            SpeakerSystemView(state: state, profile: binding, draftOnly: true, embedded: true,
                auditionOverride: { _ in }).padding(16)
        }, size: .init(width: 950, height: 1000))
        defer { setupFixture.close() }
        await setupFixture.settle()
        if let setupMap = setupFixture.views.compactMap({ $0 as? SpeakerRoomNSView }).first {
            try diagnosticRequire(setupMap.acceptsFirstResponder, "Editable speaker setup must retain keyboard editing")
            try await systemMapPan(setupMap, window: setupFixture.window, label: "Speaker setup")
        } else { throw DiagnosticFailure(message: "Missing speaker setup reference map") }
        setupFixture.window.orderOut(nil)
        let fixture = WindowFixture(ProfileEditorView(state: state, coreAudio: state.coreAudio, profile: binding)
            .environmentObject(MainWindowCommandCoordinator()),
            size: .init(width: 950, height: 1000))
        defer { fixture.close() }
        await fixture.settle(); try await Task.sleep(for: .milliseconds(600))
        var tabSwitchGaps: [Double] = []
        func press(_ id: String) async throws {
            // Reveal the whole navigation row in the outer vertical page before
            // scrolling a number inside its independent horizontal scroller.
            if id.hasPrefix("room-position-"),
               let row = fixture.views.first(where: { $0.identifier?.rawValue == "room-position-navigation" }) {
                row.scrollToVisible(row.bounds); await fixture.settle()
            }
            guard let marker = fixture.views.first(where: { $0.identifier?.rawValue == id }) else { throw DiagnosticFailure(message: "Missing room correction action \(id)") }
            marker.scrollToVisible(marker.bounds); await fixture.settle()
            let started = ProcessInfo.processInfo.systemUptime
            fixture.click(in: marker, at: .init(x: marker.bounds.midX, y: marker.bounds.midY))
            if id.hasPrefix("room-correction-tab-") {
                var previous = started
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(16))
                    let now = ProcessInfo.processInfo.systemUptime
                    tabSwitchGaps.append((now - previous) * 1000)
                    previous = now
                }
            }
            await fixture.settle()
        }
        try await press("correction-page-roomCorrection")
        // AppKit can consume the first click to activate this offscreen test
        // window. Verify the outer page before interacting with retained tabs.
        if !fixture.views.contains(where: { $0.identifier?.rawValue == "correction-content-roomCorrection" }) {
            try await press("correction-page-roomCorrection")
        }
        try diagnosticRequire(fixture.views.contains { $0.identifier?.rawValue == "correction-content-roomCorrection" },
            "Room Correction must be visible before advancing its workflow")
        guard let map = fixture.views.compactMap({ $0 as? SpeakerRoomNSView }).first,
              var mapConfiguration = map.configuration else { throw DiagnosticFailure(message: "Missing measurement map") }
        try diagnosticRequire(!fixture.views.contains { $0.identifier?.rawValue == "room-menu-Position" },
            "Measurement positions must use numbered navigation instead of a dropdown")
        try await press("room-position-4")
        try fixture.snapshot(to: artifacts.appendingPathComponent("room-positions.png"))
        try diagnosticRequire(map.configuration?.measurementPoint == session.positions[4].coordinate,
            "Numbered position navigation did not move the measurement marker: \(String(describing: map.configuration?.measurementPoint))")
        try await press("room-position-0")
        try diagnosticRequire(map.configuration?.measurementPoint == position.coordinate,
            "Numbered position navigation did not restore the main measurement position")
        func requireFitted(_ view: SpeakerRoomNSView) throws {
            guard let config = view.configuration else { throw DiagnosticFailure(message: "Missing map configuration") }
            for (index, speaker) in config.topology.endpoints.enumerated() {
                try diagnosticRequire(view.graph.contains(view.nodeRect(view.nodePoint(speaker, index: index))),
                    "Fit All clipped a speaker")
            }
            for point in [config.listener] + config.viewportPoints {
                try diagnosticRequire(view.graph.contains(view.nodeRect(view.point(point))), "Fit All clipped a listening or measurement position")
            }
        }
        try diagnosticRequire(map.bounds.height == 300 && mapConfiguration.fitsAllContent && !mapConfiguration.allowsScrollPanning,
            "Measurement map must be taller, fitted, and independent of trackpad scrolling")
        try requireFitted(map)
        map.panScroll(x: 90, y: -70, precise: true, momentum: [])
        try diagnosticRequire(map.pan == .zero, "Trackpad scrolling panned the measurement map")
        map.scrollToVisible(map.bounds)
        await fixture.settle()
        // Keep a native field editor active to exercise the profile's actual
        // outside-click monitor, not just the canvas's pointer methods.
        let focusProbe = NSTextField(string: "Uncommitted field edit")
        focusProbe.frame = .init(x: 8, y: 8, width: 180, height: 24)
        fixture.host.addSubview(focusProbe)
        defer { focusProbe.removeFromSuperview() }
        try diagnosticRequire(fixture.window.makeFirstResponder(focusProbe), "Focus probe refused editing")
        guard let fieldEditor = focusProbe.currentEditor() else { throw DiagnosticFailure(message: "Missing field editor before panning") }
        try diagnosticRequire(!map.acceptsFirstResponder, "Measurement navigation must not request keyboard editing focus")
        try await systemMapPan(map, window: fixture.window, label: "Room Correction")
        let origin = NSPoint(x: map.graph.midX, y: map.graph.midY)
        try diagnosticRequire(map.wantsLayer && map.isOpaque && !map.mouseDownCanMoveWindow,
            "Map dragging must redraw independently and must not initiate window dragging")
        var firstDragMilliseconds: Double = 0
        var clickMilliseconds: Double = 0
        for (type, point) in [(NSEvent.EventType.leftMouseDown, origin),
                              (.leftMouseDragged, NSPoint(x: origin.x + 1, y: origin.y + 1)),
                              (.leftMouseDragged, NSPoint(x: origin.x - 1, y: origin.y - 1)),
                              (.leftMouseDragged, NSPoint(x: origin.x + 35, y: origin.y + 20)),
                              (.leftMouseUp, NSPoint(x: origin.x + 35, y: origin.y + 20))] {
            let event = NSEvent.mouseEvent(with: type, location: map.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let deliveryStart = ProcessInfo.processInfo.systemUptime
            NSApp.sendEvent(event)
            if type == .leftMouseDown {
                clickMilliseconds = (ProcessInfo.processInfo.systemUptime - deliveryStart) * 1000
                try diagnosticRequire(clickMilliseconds < 50, "Map click exceeded 50 ms: \(clickMilliseconds) ms")
                // Let deferred focus-clearing requests run before movement.
                try await Task.sleep(for: .milliseconds(16))
                try diagnosticRequire(fixture.window.firstResponder === fieldEditor,
                    "Panning committed an unrelated field before the first mouse movement")
            }
            if type == .leftMouseDragged, point.x == origin.x + 1 {
                firstDragMilliseconds = (ProcessInfo.processInfo.systemUptime - deliveryStart) * 1000
                try diagnosticRequire(map.lastDrawTime >= deliveryStart,
                    "The first pan movement must be drawn during event delivery, not just update coordinates")
                try diagnosticRequire(firstDragMilliseconds < 50,
                    "First pan frame exceeded 50 ms: \(firstDragMilliseconds) ms")
            }
            if type == .leftMouseDragged {
                try diagnosticRequire(map.pan == CGPoint(x: point.x - origin.x, y: point.y - origin.y),
                    "Map panning must follow the first one-point movement and direction changes without a dead zone")
            }
        }
        print("Room map: click \(String(format: "%.2f", clickMilliseconds)) ms, first pan frame \(String(format: "%.2f", firstDragMilliseconds)) ms; active text edit preserved")
        fflush(stdout)
        fixture.window.makeFirstResponder(nil)
        focusProbe.removeFromSuperview()
        try diagnosticRequire(map.pan == CGPoint(x: 35, y: 20), "Click and drag must pan the measurement map without editing geometry")
        try await press("room-map-zoom-in")
        try diagnosticRequire(map.zoom > 1, "Zoom In did not magnify the map")
        try await press("room-map-zoom-out")
        try diagnosticRequire(abs(map.zoom - 1) < 0.001, "Zoom Out did not restore the scale")
        try await press("room-map-fit")
        try diagnosticRequire(map.pan == .zero && map.zoom == 1, "Fit All must reset a dragged map even when the zoom is already 100 percent")
        try requireFitted(map)
        // A separate native view exercises asymmetric rooms and viewport resizing.
        let geometryProbe = SpeakerRoomNSView(frame: .init(x: 0, y: 0, width: 360, height: 300))
        for index in mapConfiguration.topology.endpoints.indices {
            mapConfiguration.topology.endpoints[index].position = SpeakerLayoutGeometry.position(x: index == 0 ? -12 : 8, y: index == 0 ? 7 : -9, height: 0)
        }
        mapConfiguration.listener = .init(x: 5, y: -6, z: 0)
        mapConfiguration.measurementPoint = mapConfiguration.listener
        mapConfiguration.viewportPoints = [mapConfiguration.listener, .init(x: -14, y: -11, z: 0)]
        geometryProbe.configuration = mapConfiguration
        try requireFitted(geometryProbe)
        geometryProbe.setFrameSize(.init(width: 700, height: 300))
        try requireFitted(geometryProbe)
        try diagnosticRequire(!fixture.views.contains { $0.identifier?.rawValue == "room-correction-create" },
            "Measure must show Next instead of creating correction early")
        try fixture.snapshot(to: artifacts.appendingPathComponent("room-measure.png"))
        try await press("room-correction-next")
        try diagnosticRequire(!fixture.views.contains { $0.identifier?.rawValue == "room-correction-create" },
            "Analysis must show Next instead of creating correction early")
        try fixture.snapshot(to: artifacts.appendingPathComponent("room-analysis.png"))
        if analysisFixture != nil {
            guard let mode = fixture.views.first(where: { $0.identifier?.rawValue == "room-analysis-mode" }) else {
                throw DiagnosticFailure(message: "Missing analysis mode controls")
            }
            for (index, name) in [(2, "impulse"), (3, "phase"), (4, "group-delay"), (0, "frequency")] {
                mode.scrollToVisible(mode.bounds); await fixture.settle()
                fixture.click(in: mode, at: .init(x: mode.bounds.width * (CGFloat(index) + 0.5) / 5, y: mode.bounds.midY))
                await fixture.settle()
                try fixture.snapshot(to: artifacts.appendingPathComponent("room-phone-\(name).png"))
            }
        }
        try await press("room-correction-next")
        try diagnosticRequire(fixture.views.contains { $0.identifier?.rawValue == "room-correction-create" },
            "The last workflow step must offer Create Room Correction")
        try await press("room-correction-remeasure")
        for _ in 0..<3 {
            for tab in ["analysis", "correction", "measure"] { try await press("room-correction-tab-\(tab)") }
            try await press("correction-page-convolution")
            try await press("correction-page-roomCorrection")
        }
        for width: CGFloat in [600, 950] {
            fixture.resize(width: width, height: 850); await fixture.settle()
            try await press("room-correction-tab-measure")
            try await press("room-map-fit")
            try requireFitted(map)
            try fixture.snapshot(to: artifacts.appendingPathComponent("room-map-\(Int(width)).png"))
            for tab in ["analysis", "measure", "correction"] { try await press("room-correction-tab-\(tab)") }
            guard let method = fixture.views.first(where: { $0.identifier?.rawValue == "room-correction-method" }),
                  let create = fixture.views.first(where: { $0.identifier?.rawValue == "room-correction-create" }),
                  let back = fixture.views.first(where: { $0.identifier?.rawValue == "room-correction-remeasure" }) else {
                throw DiagnosticFailure(message: "Missing Room Correction workflow controls")
            }
            try diagnosticRequire(abs(method.bounds.width - 260) < 1, "Room method control must match the Equalizer control width")
            let createFrame = create.convert(create.bounds, to: fixture.host)
            let backFrame = back.convert(back.bounds, to: fixture.host)
            try diagnosticRequire(createFrame.minX > backFrame.maxX && createFrame.maxX <= fixture.host.bounds.maxX,
                "Create Room Correction must stay on the right and inside the window")
            method.scrollToVisible(method.bounds); await fixture.settle()
            fixture.click(in: method, at: .init(x: method.bounds.width * 0.625, y: method.bounds.midY))
            await fixture.settle()
            guard let phase = fixture.views.first(where: { $0.identifier?.rawValue == "room-correction-phase" }) else {
                throw DiagnosticFailure(message: "The FIR method must expose its phase controls")
            }
            try diagnosticRequire(phase.bounds.width <= 121, "Room correction dropdowns must remain compact")
            try fixture.snapshot(to: artifacts.appendingPathComponent("room-correction-\(Int(width)).png"))
        }
        let sortedGaps = tabSwitchGaps.sorted()
        let p95 = sortedGaps.isEmpty ? 0 : sortedGaps[Int(Double(sortedGaps.count - 1) * 0.95)]
        print("Room tabs: main-loop max gap \(String(format: "%.2f", sortedGaps.last ?? 0)) ms, p95 \(String(format: "%.2f", p95)) ms")
        // Includes click delivery and the following 320 ms of main-loop work
        // in the complete profile editor, at both narrow and wide widths.
        try diagnosticRequire(!sortedGaps.isEmpty && p95 < 45 && (sortedGaps.last ?? 0) < 150,
            "Room Correction tab switching exceeded its responsiveness budget")
        print("Room Correction: fitted measurement map, mouse-only pan, zoom/reset controls, Next/Re-measure workflow, compact controls and resize")
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
            // Offscreen windows need a display pass to refresh SwiftUI hit regions after scrolling.
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
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
