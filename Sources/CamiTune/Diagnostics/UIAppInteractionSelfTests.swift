import AppKit
import CamiTuneAudio
import CamiTuneDomain
import SwiftUI

#if DEBUG
@MainActor
extension UIInteractionSelfTests {
    static func runWholeWindow(artifacts: URL) async throws {
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let box = try DiagnosticSandbox(); defer { box.cleanUp() }
        let editOnly = ProcessInfo.processInfo.environment["CAMITUNE_UI_EDIT_ONLY"] == "1"
        let previousSetup = UserDefaults.standard.object(forKey: "hasPresentedInitialSetup")
        defer {
            UserDefaults.standard.set(previousSetup, forKey: "hasPresentedInitialSetup")
            if ProcessInfo.processInfo.environment["CAMITUNE_UI_TEST_SUPPORT_DIRECTORY"] == nil {
                try? FileManager.default.removeItem(at: CamiTunePaths.supportDirectory)
            }
        }
        var profiles: [DeviceProfile] = [ProfileEndpointKind.headphones, .iem, .speakers].enumerated().map { index, kind in
            var profile = DiagnosticSandbox.profile()
            profile.name = "UI fixture \(index + 1) \(kind.rawValue)"
            profile.endpointKind = kind
            profile.sectionLayout = .init(hidden: [])
            profile.setGlobalEqualizer(preampDB: 0, bands: EQEditorSupport.resizedBands([], count: 8))
            return profile
        }
        if let source = ProcessInfo.processInfo.environment["CAMITUNE_UI_TEST_PROFILE_LIBRARY"] {
            let copy = box.directory.appendingPathComponent("copied-library.json")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
            let copiedStore = ProfileStore(storageURL: copy, userDefaults: box.defaults)
            profiles = copiedStore.profiles.enumerated().map { index, original in
                var profile = original
                profile.name = "UI fixture \(index + 1) \(original.endpointKind.rawValue)"
                return profile
            }
            try diagnosticRequire(!profiles.isEmpty, "The copied profile library was empty")
        }
        box.profiles.profiles = profiles
        box.profiles.selectedProfileID = profiles[0].id
        box.defaults.set(profiles[0].id.uuidString, forKey: "lastSidebarSelection")
        let runtime = DiagnosticRuntimeFakes(output: AudioDeviceInfo(id: profiles[0].outputDeviceUID,
            objectID: 100, name: "Simulated output"))
        runtime.defaultUID = profiles[0].outputDeviceUID
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: runtime.services())
        // This fixture simulates audio services; installed driver availability
        // belongs to hardware diagnostics, not the interaction measurement.
        _ = state.setupPresentation.begin(hasExistingProfiles: true)
        let appClients = (1...8).map { index in
            PerAppDriverClient(deviceObjectID: 100, clientID: UInt32(index), processID: Int32(2_000_400_000 + index),
                bundleID: "fixture.ui.player\(index)", isActive: true, generation: 1)
        }
        box.perApp.updateClients(appClients)
        await box.perApp.drainPresentationPreparation()
        for client in appClients {
            _ = box.perApp.ingest(PerAppAudioPacket(deviceObjectID: 100, clientID: client.clientID,
                processID: client.processID, cycleCounter: 1, sampleTime: 0,
                interleaved: Array(repeating: Float(0.1), count: 64), channelCount: 2, sampleRate: 48_000))
        }
        await state.activate(profile: profiles[0])
        try diagnosticRequire(state.errorMessage == nil, "Fixture activation failed: \(state.errorMessage ?? "")")
        let commands = MainWindowCommandCoordinator()
        commands.resolveContext = { destination, sidebar in
            var context = MainWindowCommandCoordinator.Context(destination: destination,
                mainWindowVisible: true, sidebarVisible: sidebar)
            if case .profile(let id) = destination { context.profileID = id; context.profileEnabled = true }
            return context
        }
        let meterTask = Task { @MainActor in
            var tick = 0
            while !Task.isCancelled {
                let level = -24 + sin(Double(tick) * 0.3) * 18
                let id: UUID
                if case .profile(let selected) = commands.selection { id = selected } else { id = profiles[0].id }
                if tick.isMultiple(of: 2) {
                    state.meters.setPreviewLevels(.init(capturePeak: [level, level - 2], captureRMS: [level - 6, level - 8],
                        playbackPeak: [level - 1, level - 3], playbackRMS: [level - 7, level - 9]), profileID: id)
                }
                state.spectrum.setPreviewPoints((0..<180).map { index in
                    SpectrumPoint(frequency: 20 * pow(1000, Double(index) / 179),
                        db: -48 + sin(Double(index) * 0.07 + Double(tick) * 0.1) * 15)
                }, profileID: id)
                tick += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { meterTask.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        let controller = NSHostingController(rootView: ContentView(state: state, commands: commands, preferences: box.defaults)
            .background(Color(nsColor: .windowBackgroundColor)))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.setContentSize(.init(width: 1000, height: 700))
        window.setFrameOrigin(.init(x: -10000, y: -10000))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        print("Whole-window created in \(ProcessInfo.processInfo.systemUptime - start)s"); fflush(stdout)
        var measurements: [[String: Any]] = []
        var worstNavigationGap: Double = 0
        let navigationBudget = Double(ProcessInfo.processInfo.environment["CAMITUNE_UI_MAX_NAVIGATION_GAP_MS"] ?? "500") ?? 500
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: artifacts.appendingPathComponent("whole-window-performance.json"))
            }
        }
        func idle(_ name: String, milliseconds: Int = 1200) async {
            var gaps: [Double] = []
            let until = ProcessInfo.processInfo.systemUptime + Double(milliseconds) / 1000
            while ProcessInfo.processInfo.systemUptime < until {
                let before = ProcessInfo.processInfo.systemUptime
                try? await Task.sleep(for: .milliseconds(16))
                gaps.append((ProcessInfo.processInfo.systemUptime - before) * 1000)
            }
            print("\(name): main-loop max gap \(Int(gaps.max() ?? 0))ms, samples \(gaps.count), memory \(memoryMB()) MB")
            let sorted = gaps.sorted()
            measurements.append(["action": name, "maxGapMS": sorted.last ?? 0,
                "p95GapMS": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
                "memoryMB": memoryMB()])
            if name.hasPrefix("Sidebar row") { worstNavigationGap = max(worstNavigationGap, gaps.max() ?? 0) }
            fflush(stdout)
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func click(_ view: NSView, x: CGFloat, y: CGFloat) {
            // Offscreen windows need a display pass to refresh SwiftUI hit regions after scrolling.
            controller.view.layoutSubtreeIfNeeded()
            controller.view.displayIfNeeded()
            let location = view.convert(.init(x: x, y: y), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            }
            // Native NSButton tracking waits synchronously for mouse-up.
            NSApp.postEvent(event(.leftMouseUp), atStart: false)
            window.sendEvent(event(.leftMouseDown))
        }
        await idle("Initial profile", milliseconds: 2500)
        guard let table = descendants(controller.view).compactMap({ $0 as? NSTableView }).first else {
            throw DiagnosticFailure(message: "Missing full-window sidebar")
        }
        for row in 0..<table.numberOfRows {
            let view = table.view(atColumn: 0, row: row, makeIfNecessary: true)
            let labels = view.map { descendants($0).compactMap { ($0 as? NSTextField)?.stringValue } } ?? []
            print("Sidebar row \(row): \(labels)")
        }
        fflush(stdout)
        if ProcessInfo.processInfo.environment["CAMITUNE_UI_CORRECTION_ONLY"] != "1", !editOnly {
        if profiles.count >= 2 {
            let displayed = commands.selection
            let profileRows = IndexSet(integersIn: 2..<table.numberOfRows)
            func contextMenu(at point: NSPoint) throws -> NSMenu {
                let event = NSEvent.mouseEvent(with: .rightMouseDown,
                    location: table.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                guard let menu = table.menu(for: event) else {
                    throw DiagnosticFailure(message: "Sidebar context menu was missing")
                }
                return menu
            }
            func emptyPoint() -> NSPoint {
                .init(x: table.bounds.midX, y: table.rect(ofRow: table.numberOfRows - 1).maxY + 12)
            }
            table.selectRowIndexes(profileRows, byExtendingSelection: false)
            let profileMenu = try contextMenu(at: .init(x: 50, y: table.rect(ofRow: 2).midY))
            let titles = profileMenu.items.map { $0.isSeparatorItem ? "separator" : $0.title }
            try diagnosticRequire(titles == [profiles[0].isEnabled ? "Disable Profile" : "Enable Profile",
                "separator", "Rename", "New Folder with Selection", "Delete"],
                "Profile menu has unexpected actions or grouping: \(titles)")
            let blankMenu = try contextMenu(at: emptyPoint())
            try diagnosticRequire(blankMenu.items.map(\.title) == ["New Folder"],
                "Blank-space menu grouped the highlighted profiles")
            click(table, x: emptyPoint().x, y: emptyPoint().y)
            await idle("Sidebar background selection", milliseconds: 200)
            try diagnosticRequire(table.selectedRowIndexes == IndexSet(integer: 2) && commands.selection == displayed,
                "Blank-space click did not retain only the displayed profile")
            window.makeFirstResponder(table)
            let selectAll = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            window.sendEvent(selectAll)
            table.selectAll(nil)
            try diagnosticRequire(table.selectedRowIndexes == IndexSet(integer: 2),
                "Command-A still selected all sidebar profiles")
            // Cancel navigation queued by a row click before the next run-loop turn.
            table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
            click(table, x: emptyPoint().x, y: emptyPoint().y)
            await idle("Sidebar cancelled navigation", milliseconds: 200)
            try diagnosticRequire(table.selectedRowIndexes == IndexSet(integer: 2) && commands.selection == displayed,
                "Blank-space click allowed pending navigation to replace the displayed profile")
            table.selectRowIndexes(profileRows, byExtendingSelection: false)
            let createMenu = try contextMenu(at: emptyPoint())
            let create = createMenu.items[0]
            guard let action = create.action else { throw DiagnosticFailure(message: "New Folder has no action") }
            NSApp.sendAction(action, to: create.target, from: create)
            await idle("Sidebar empty folder creation", milliseconds: 300)
            try diagnosticRequire(box.profiles.folders.count == 1 && box.profiles.folders[0].profileIDs.isEmpty,
                "New Folder moved highlighted profiles into the folder")
            if let editor = window.firstResponder as? NSTextView {
                editor.selectAll(nil)
                try diagnosticRequire(editor.selectedRange().length == editor.string.utf16.count,
                    "Disabling profile Select All also disabled Select All in the rename field")
            } else { throw DiagnosticFailure(message: "New folder did not enter inline rename") }
            click(table, x: emptyPoint().x, y: emptyPoint().y)
            box.profiles.deleteFolder(id: box.profiles.folders[0].id)
            await idle("Sidebar folder cleanup", milliseconds: 200)
            print("Sidebar menus, blank-space selection, and Select All checks passed")
        }
        for row in 0..<table.numberOfRows where table.delegate?.tableView?(table, shouldSelectRow: row) != false {
            let before = ProcessInfo.processInfo.systemUptime
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await idle("Sidebar row \(row)")
            let expected: SidebarDestination = row == 0 ? .applications : .profile(profiles[row - 2].id)
            try diagnosticRequire(commands.selection == expected, "Sidebar selection stalled on row \(row)")
            if row == 0 {
                let priorMuted = box.perApp.applications.filter { $0.settings.isMuted }.count
                // App Audio uses a native drop destination for each fixed-height
                // row; exercise the SwiftUI controls through real mouse events.
                guard let appRow = descendants(controller.view).first(where: {
                    String(describing: type(of: $0)).hasPrefix("DestinationView<")
                        && abs($0.bounds.height - 64) < 1 && !$0.visibleRect.isEmpty
                }) else { throw DiagnosticFailure(message: "Missing visible application row") }
                click(appRow, x: 218, y: appRow.bounds.midY)
                await idle("Application mute", milliseconds: 300)
                try diagnosticRequire(box.perApp.applications.filter { $0.settings.isMuted }.count == priorMuted + 1,
                    "Application mute did not update its setting")
                let fieldsBefore = descendants(controller.view).filter { $0 is NSTextField }.count
                click(appRow, x: appRow.bounds.maxX - 55, y: appRow.bounds.midY)
                await idle("Expand application equalizer", milliseconds: 400)
                try diagnosticRequire(descendants(controller.view).filter { $0 is NSTextField }.count > fieldsBefore,
                    "Application equalizer did not expand")
                click(appRow, x: appRow.bounds.maxX - 55, y: appRow.bounds.midY)
                await idle("Collapse application equalizer", milliseconds: 400)
                try diagnosticRequire(descendants(controller.view).filter { $0 is NSTextField }.count == fieldsBefore,
                    "Application equalizer did not collapse")
                print("App Audio rendered \(box.perApp.applications.count) applications")
            }
            print("Destination \(commands.selection), total \(ProcessInfo.processInfo.systemUptime - before)s"); fflush(stdout)
        }
        commands.send(.settings)
        await idle("Open settings")
        for category in ["Section Layout", "Drivers & Components", "Diagnostics", "Confirmations", "General"] {
            commands.settingsCategory = category
            await idle("Settings: \(category)", milliseconds: 500)
        }
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        await idle("Return to headphones", milliseconds: 1800)
        }
        guard let page = descendants(controller.view).compactMap({ $0 as? NSScrollView })
            .first(where: { ($0.documentView?.frame.height ?? 0) > $0.contentSize.height + 500 }) else {
            throw DiagnosticFailure(message: "Missing complete profile scroll view")
        }
        // Exercise correction controls in the complete profile, alongside all
        // other sections and live telemetry, rather than only in a small fixture.
        func pressCorrection(_ identifier: String, disclosure: Bool = false) async throws {
            guard let marker = descendants(controller.view).first(where: { $0.identifier?.rawValue == identifier }) else {
                throw DiagnosticFailure(message: "Missing whole-window correction control \(identifier)")
            }
            var target = marker
            if disclosure {
                let area = marker.convert(marker.bounds, to: controller.view)
                guard let title = descendants(controller.view).first(where: {
                    $0.identifier?.rawValue == "disclosure-label" && area.contains($0.convert($0.bounds, to: controller.view))
                }) else { throw DiagnosticFailure(message: "Missing whole-window correction disclosure label") }
                target = title
            }
            target.scrollToVisible(target.bounds)
            await idle("Locate \(identifier)", milliseconds: 100)
            let before = ProcessInfo.processInfo.systemUptime
            click(target, x: target.bounds.midX, y: target.bounds.midY)
            let dispatchMS = (ProcessInfo.processInfo.systemUptime - before) * 1000
            measurements.append(["action": "Dispatch \(identifier)", "maxGapMS": dispatchMS, "memoryMB": memoryMB()])
            await idle("Correction \(identifier)", milliseconds: 450)
        }
        for pass in 0..<(editOnly ? 0 : 3) {
            for method in [DeviceCorrectionPage.convolution, .crossfeed, .automaticEQ] {
                try await pressCorrection("correction-page-\(method.rawValue)")
                try diagnosticRequire(descendants(controller.view).contains { $0.identifier?.rawValue == "correction-content-\(method.rawValue)" },
                    "Whole-window correction navigation did not select \(method.rawValue)")
                if method == .convolution {
                    try diagnosticRequire(descendants(controller.view).contains { $0.identifier?.rawValue == "correction-fir-all-channels" },
                        "Whole-window personal FIR correction did not display the shared all-channel editor")
                }
                if method == .automaticEQ {
                    let initialHeight = page.documentView!.frame.height
                    try await pressCorrection("correction-auto-advanced", disclosure: true)
                    try diagnosticRequire(abs(page.documentView!.frame.height - initialHeight) > 10,
                        "Whole-window disclosure did not update the document height: \(initialHeight) -> \(page.documentView!.frame.height)")
                    try await pressCorrection("correction-auto-advanced", disclosure: true)
                    if abs(page.documentView!.frame.height - initialHeight) >= 1,
                       let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
                        for view in descendants(controller.view) { view.needsDisplay = true }
                        window.effectiveAppearance.performAsCurrentDrawingAppearance { controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap) }
                        try bitmap.representation(using: .png, properties: [:])?.write(to: artifacts.appendingPathComponent("correction-failure.png"))
                        print(descendants(controller.view).filter { $0.identifier?.rawValue.hasPrefix("correction-") == true }.map { "\($0.identifier!.rawValue): \($0.convert($0.bounds, to: controller.view))" }.joined(separator: "\n"))
                    }
                    try diagnosticRequire(abs(page.documentView!.frame.height - initialHeight) < 1,
                        "Whole-window disclosure retained a stale document height: \(initialHeight) -> \(page.documentView!.frame.height)")
                }
                if pass == 2, let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
                    window.effectiveAppearance.performAsCurrentDrawingAppearance { controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap) }
                    try bitmap.representation(using: .png, properties: [:])?.write(to: artifacts.appendingPathComponent("whole-correction-\(method.rawValue).png"))
                }
            }
        }
        if ProcessInfo.processInfo.environment["CAMITUNE_UI_CORRECTION_ONLY"] == "1" { return }
        for round in 0..<(editOnly ? 0 : 3) {
            let maximum = max(0, (page.documentView?.frame.height ?? 0) - page.contentSize.height)
            var gaps: [Double] = []
            let before = ProcessInfo.processInfo.systemUptime
            for step in 0..<120 {
                let start = ProcessInfo.processInfo.systemUptime
                let fraction = Double(step < 60 ? step : 119 - step) / 59
                page.contentView.scroll(to: NSPoint(x: 0, y: maximum * fraction))
                page.reflectScrolledClipView(page.contentView)
                try? await Task.sleep(for: .milliseconds(16))
                gaps.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            let sorted = gaps.sorted()
            print("Scroll round \(round): \(ProcessInfo.processInfo.systemUptime - before)s, max gap \(Int(gaps.max() ?? 0))ms, p95 \(Int(sorted[Int(Double(sorted.count) * 0.95)]))ms")
            measurements.append(["action": "Scroll round \(round)", "maxGapMS": sorted.last ?? 0,
                "p95GapMS": sorted[Int(Double(sorted.count) * 0.95)], "memoryMB": memoryMB()])
            fflush(stdout)
            await idle("Between scrolling \(round)", milliseconds: 1500)
        }
        // Keep telemetry and the full page alive, including several complete
        // scroll traversals. This catches degradation hidden by short previews.
        let soakSeconds = Double(ProcessInfo.processInfo.environment["CAMITUNE_UI_SOAK_SECONDS"] ?? "0") ?? 0
        let soakStart = ProcessInfo.processInfo.systemUptime
        let memoryBeforeSoak = memoryMB()
        var round = 0
        while ProcessInfo.processInfo.systemUptime - soakStart < soakSeconds {
            let maximum = max(0, (page.documentView?.frame.height ?? 0) - page.contentSize.height)
            var gaps: [Double] = []
            for step in 0..<90 {
                let before = ProcessInfo.processInfo.systemUptime
                page.contentView.scroll(to: NSPoint(x: 0, y: maximum * Double(step < 45 ? step : 89 - step) / 44))
                page.reflectScrolledClipView(page.contentView)
                try? await Task.sleep(for: .milliseconds(16))
                gaps.append((ProcessInfo.processInfo.systemUptime - before) * 1000)
            }
            let sorted = gaps.sorted()
            measurements.append(["action": "Sustained scroll \(round)", "maxGapMS": sorted.last ?? 0,
                "p95GapMS": sorted[Int(Double(sorted.count) * 0.95)], "memoryMB": memoryMB()])
            print("Sustained scroll \(round): max \(Int(sorted.last ?? 0))ms, p95 \(Int(sorted[Int(Double(sorted.count) * 0.95)]))ms")
            try diagnosticRequire((sorted.last ?? 0) < 150, "Sustained scrolling stalled for more than 150ms")
            await idle("Sustained run \(round)", milliseconds: 3000)
            round += 1
        }
        if soakSeconds > 0 {
            let growth = memoryMB() - memoryBeforeSoak
            print("Sustained memory growth: \(growth) MB over \(Int(soakSeconds)) seconds")
            try diagnosticRequire(growth < 100, "UI memory grew without settling during sustained scrolling")
        }
        // Edit an actual native field in the full page, then leave via sidebar.
        var editedChannelGain = false
        for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
            let maximum = max(0, (page.documentView?.frame.height ?? 0) - page.contentSize.height)
            page.contentView.scroll(to: NSPoint(x: 0, y: maximum * fraction))
            page.reflectScrolledClipView(page.contentView)
            try? await Task.sleep(for: .milliseconds(80))
            if let field = descendants(controller.view).compactMap({ $0 as? NSTextField })
                .first(where: { $0.placeholderString == "Channel gain" && !$0.visibleRect.isEmpty }) {
                if editOnly {
                    print("Channel edit ready for sampling"); fflush(stdout)
                    try? await Task.sleep(for: .seconds(5))
                }
                window.makeFirstResponder(field)
                if let editor = field.currentEditor() as? NSTextView {
                    editor.insertText("-2.0", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    window.makeFirstResponder(nil)
                    await idle("Channel gain edit", milliseconds: 400)
                    try diagnosticRequire((measurements.last?["maxGapMS"] as? Double ?? .infinity) < navigationBudget,
                        "Native channel editing exceeded the interaction budget")
                    editedChannelGain = true
                    break
                }
            }
        }
        try diagnosticRequire(editedChannelGain, "The full-window channel gain field was not editable")
        try diagnosticRequire(box.profiles.profiles[0].processing.settings(forChannel: 0)?.gainDB == -2,
            "The full-window channel gain edit was not saved")
        if editOnly { return }
        page.contentView.scroll(to: .zero)
        page.reflectScrolledClipView(page.contentView)
        await idle("Return to profile header", milliseconds: 300)
        try diagnosticRequire(state.errorMessage == nil, "Editing failed: \(state.errorMessage ?? "")")
        commands.send(.profileSettings(profiles[0].id))
        await idle("Open profile settings", milliseconds: 500)
        try diagnosticRequire(window.attachedSheet != nil, "Profile settings did not open")
        if let sheet = window.attachedSheet {
            sheet.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(100))
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            if let root = sheet.contentView,
               let cancel = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.keyEquivalent == "\u{1b}" }) {
                cancel.performClick(nil)
            } else {
                NSApp.sendEvent(escape)
            }
            await idle("Close profile settings", milliseconds: 500)
            try diagnosticRequire(window.attachedSheet == nil, "Profile settings did not close")
        }
        window.setContentSize(.init(width: 800, height: 620))
        await idle("Resize complete window to minimum size", milliseconds: 600)
        try diagnosticRequire((page.documentView?.frame.width ?? 0) <= page.contentSize.width + 1,
            "The complete profile forced horizontal page overflow at minimum window size")
        window.setContentSize(.init(width: 1000, height: 700))
        await idle("Restore complete window size", milliseconds: 600)
        if let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
            window.effectiveAppearance.performAsCurrentDrawingAppearance { controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap) }
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: artifacts.appendingPathComponent("whole-window.png"))
            }
        }
        var navigationMemory = 0
        for pass in 0..<3 {
            for row in 2..<table.numberOfRows {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                await idle("Repeated profile visit \(pass)/\(row)", milliseconds: 600)
            }
            table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            await idle("Repeated profile visit settled", milliseconds: 800)
            if pass == 0 { navigationMemory = memoryMB() }
        }
        try diagnosticRequire(memoryMB() - navigationMemory < 100,
            "Repeated navigation retained departed profile editors")
        let menu = WindowFixture(MenuBarRootView(state: state), size: .init(width: 370, height: 650))
        await menu.settle()
        await idle("Menu bar with application rows", milliseconds: 1500)
        try menu.snapshot(to: artifacts.appendingPathComponent("menu-bar.png"))
        menu.close()
        await idle("After closing menu bar", milliseconds: 500)
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifacts.appendingPathComponent("whole-window-performance.json"))
        try diagnosticRequire(worstNavigationGap < navigationBudget, "Profile navigation blocked the main loop for \(Int(worstNavigationGap))ms")
    }

    private static func memoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }

}

#endif
