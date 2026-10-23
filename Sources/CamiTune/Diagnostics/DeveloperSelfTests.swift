import CamiTuneAudio
import CamiTuneDomain
import Foundation

@MainActor
enum DeveloperSelfTests {
    static func cases() -> [DiagnosticCase] {
        profileCases() + audioBufferCases() + automaticBufferCases() + preparedBufferHandoffCases() + planningCases() + pcmCases() + lifecycleCases() + healthCases() + performanceCases() + presentationCases() + runtimePlanCases() + runtimePlanDifferCases() + runtimeCoordinatorCases() + coreAudioHandoffCases() + profileRepositoryCases() + profilePersistenceCases() + timelineStorageCases() + timelineMixerCases() + timelineIntegrationCases() + timelineBenchmarkCases() + reorderPolicyCases() + reorderMatrixCases() + pcmDeliveryCases() + producerCompletionCases() + pcmSinkCases() + audioClockCases() + architectureOwnerCases() + uiStateCases() + roomRecordingCases() + pluginCases()
    }

    static func roomRecordingCases() -> [DiagnosticCase] {
        [
            test("RC01", "Room recordings", "Acoustic compatibility ignores editor-only changes") { _ in
                let topology = try DiagnosticHardware().topology(for: "fixture", sampleRate: 48000).speakerTopology
                let stageID = UUID()
                let band = EQBand(kind: .peaking, frequency: 120, gain: -3, q: 2)
                let original = RoomMeasurementContext(topology: topology, listener: .init(x: 0, y: 0, z: 0),
                    processing: .init(global: .init(stages: [.init(id: stageID, processor: .equalizer(.init(bands: [band])))])))
                var equivalent = original
                var replacement = EQBand(kind: band.kind, frequency: band.frequency, gain: band.gain, q: band.q)
                replacement.isLocked = true
                equivalent.processing.global.stages[0].processor = .equalizer(.init(bands: [replacement]))
                equivalent.processing.global.stages.append(.init(isEnabled: false, processor: .limiter(.standard)))
                try diagnosticRequire(original.canReprocess(to: equivalent) && Set([original, equivalent]).count == 1,
                    "Recreated band identities and a disabled limiter must not invalidate the recording")
                var changed = equivalent
                replacement.gain = -6
                changed.processing.global.stages[0].processor = .equalizer(.init(bands: [replacement]))
                try diagnosticRequire(!original.canReprocess(to: changed), "An audible EQ change must still invalidate the recording")
                changed = equivalent; changed.processing.global.stages[1].isEnabled = true
                try diagnosticRequire(!original.canReprocess(to: changed), "Enabling processing must still invalidate the recording")
                changed = equivalent; changed.listener.x += 1
                try diagnosticRequire(!original.canReprocess(to: changed), "A moved listening position must still invalidate the recording")
                return .init(summary: "Non-audible changes remain compatible; actual EQ, processing and geometry changes are detected")
            },
            test("RC02", "Room recordings", "Quit cleanup deletes detached copies and preserves live files") { box in
                let store = RoomMeasurementStore(directory: box.directory.appendingPathComponent("RoomMeasurements"))
                let topology = try DiagnosticHardware().topology(for: "fixture", sampleRate: 48000).speakerTopology
                let point = SpatialVector3(x: 0, y: 0, z: 0)
                var session = RoomMeasurementSession(context: .init(topology: topology, listener: point, processing: .init()),
                    source: .init(), positions: [.init(coordinate: point, isMain: true)])
                let original = box.directory.appendingPathComponent("Original.wav")
                try Data("original file".utf8).write(to: original)
                let removed = try store.retain(original, sessionID: session.id, blocks: [], format: "wav", isLossy: false)
                let kept = try store.retain(original, sessionID: session.id, blocks: [], format: "wav", isLossy: false)
                session.recordings = [removed, kept]; try store.save(session)
                session.recordings = [kept]; try store.save(session)
                let pending = try store.retain(original, sessionID: session.id, blocks: [], format: "wav", isLossy: false)
                let oldOrphan = store.folder(session.id).appendingPathComponent("\(UUID()).wav")
                try Data().write(to: oldOrphan)
                let unknown = store.folder(session.id).appendingPathComponent("notes.wav")
                try Data().write(to: unknown)
                let link = store.folder(session.id).appendingPathComponent("\(UUID()).wav")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
                let unreadableFolder = store.folder(UUID())
                try FileManager.default.createDirectory(at: unreadableFolder, withIntermediateDirectories: true)
                try Data("invalid manifest".utf8).write(to: unreadableFolder.appendingPathComponent("session.plist"))
                let protected = unreadableFolder.appendingPathComponent("\(UUID()).wav")
                try Data().write(to: protected)
                let deleted = try store.removeUnreferencedRecordings()
                let removedURL = try store.recordingURL(removed, sessionID: session.id)
                try diagnosticRequire(deleted == 2 && !FileManager.default.fileExists(atPath: removedURL.path)
                    && !FileManager.default.fileExists(atPath: oldOrphan.path), "Detached copies must be deleted at cleanup")
                for url in [original, try store.recordingURL(kept, sessionID: session.id),
                            try store.recordingURL(pending, sessionID: session.id), unknown, link, protected] {
                    try diagnosticRequire(FileManager.default.fileExists(atPath: url.path), "Cleanup removed a protected file")
                }
                session.recordings.append(pending); try store.save(session)
                session.recordings.removeAll { $0 == pending }; try store.save(session)
                let nextCleanup = try store.removeUnreferencedRecordings()
                try diagnosticRequire(nextCleanup == 1, "A completed import can be removed at the next cleanup")
                let repeatedCleanup = try store.removeUnreferencedRecordings()
                try diagnosticRequire(repeatedCleanup == 0, "Cleanup must be repeatable")
                return .init(summary: "Removed copies are deleted; referenced, pending, original and unknown files survive")
            },
            test("RC03", "Room correction", "Imports map filter types and preserve other processing") { box in
                var profile = DiagnosticSandbox.profile()
                profile.endpointKind = .speakers
                profile.speakerTopology = SpeakerTopology(deviceUID: profile.outputDeviceUID,
                    sampleRate: Double(profile.sampleRate), declaredChannelCount: 2,
                    endpoints: (0..<2).map { .init(id: .init(deviceUID: profile.outputDeviceUID, channelIndex: $0),
                        role: $0 == 0 ? .left : .right, displayName: "Channel \($0 + 1)", connectionState: .confirmedByUser) })
                profile.spatialSettings.seating = .init(outputDeviceUID: profile.outputDeviceUID)
                let oldBand = EQBand(kind: .peaking, frequency: 90, gain: -1, q: 2)
                for channel in 0..<2 {
                    try profile.setChannelProcessing(index: channel, role: channel == 0 ? .left : .right,
                        gainDB: -2, bands: [oldBand], delayMilliseconds: 3, limiterEnabled: false)
                }
                let wav = box.directory.appendingPathComponent("test-response.wav")
                let store = ImpulseResponseStore()
                try RoomMeasurementStore.writeWAV(samples: [1] + Array(repeating: 0, count: 511),
                    sampleRate: Double(profile.sampleRate), to: wav)
                let oldFIR = ConvolutionProcessor(asset: try store.importWAV(at: wav, expectedSampleRate: profile.sampleRate))
                defer { try? FileManager.default.removeItem(at: store.url(for: oldFIR.asset)) }
                try RoomMeasurementStore.writeWAV(samples: [0.8] + Array(repeating: 0, count: 1023),
                    sampleRate: Double(profile.sampleRate), to: wav)
                let newFIR = ConvolutionProcessor(asset: try store.importWAV(at: wav, expectedSampleRate: profile.sampleRate))
                defer { try? FileManager.default.removeItem(at: store.url(for: newFIR.asset)) }
                box.profiles.profiles = [profile]
                let app = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
                try app.mutateSavedProcessing(profileID: profile.id) { $0.setConvolution(oldFIR, forChannel: 0) }
                profile = box.profiles.profiles[0]
                let original = try profile.resolvedProcessing()
                let shared = EQBand(kind: .peaking, frequency: 120, gain: -3, q: 2)
                let individual = EQBand(kind: .peaking, frequency: 220, gain: -2, q: 3)
                for method in RoomCorrectionMethod.allCases {
                    var result = RoomCorrectionResult(sessionID: UUID(), context: try profile.roomMeasurementContext(),
                        method: method, settings: .init(), lowHz: 25, highHz: 800, positionCount: 5)
                    if method != .fir { result.sharedBands = [shared]; result.channelBands = [0: [individual]] }
                    if method == .fir || method == .hybrid { result.channelFIR = [0: newFIR] }
                    let plan = try RoomCorrectionImportPlan(result: result, profile: profile)
                    let message = try plan.replacementMessage(profile: profile)
                    try diagnosticRequire(message != nil, "Replacing occupied channel EQ/FIR slots must use the existing confirmation")
                    let candidate = try plan.applying(to: profile)
                    _ = try AudioRuntimePlanPreparer.prepareForStorage(profile: candidate,
                        revision: .init(profileID: candidate.id, generation: 0))
                    let processing = try candidate.resolvedProcessing()
                    let left = processing.settings(forChannel: 0)!, right = processing.settings(forChannel: 1)!
                    try diagnosticRequire(left.bands == (method == .fir ? [oldBand] : [shared, individual])
                        && right.bands == (method == .fir ? [oldBand] : [shared]), "EQ must appear in the channel editor; FIR-only import preserves existing EQ")
                    try diagnosticRequire(processing.convolution(forChannel: 0)?.processor == (method == .fir || method == .hybrid ? newFIR : oldFIR),
                        "FIR must appear in its channel editor; EQ-only import preserves existing FIR")
                    let leftStages = processing.channels.first { $0.index == 0 }!.chain.stages
                    let rightStages = processing.channels.first { $0.index == 1 }!.chain.stages
                    try diagnosticRequire(!(leftStages + rightStages).contains { ProcessingProfile.isRoomStage($0.id) },
                        "Imported filters must not also run in a hidden room stage")
                    try diagnosticRequire(candidate.effectiveSpatialSettings.seating?.roomCorrectionEnabled == false,
                        "Channel editors own imported filters")
                    try diagnosticRequire(left.gainDB == -2 && left.delayMilliseconds == 3
                        && right.gainDB == -2 && processing.global == original.global,
                        "Import must preserve gain, delay and global processing")
                    try diagnosticRequire(plan.matches(profile: candidate), "Imported filters must remain compatible with their original measurement")
                    var changed = candidate
                    try changed.setChannelProcessing(index: 0, role: .left, gainDB: -8, bands: left.bands)
                    try diagnosticRequire(plan.matches(profile: changed), "Bypassed channel gain must not invalidate measurements")
                    changed.setGlobalEqualizer(preampDB: -8, bands: processing.globalEqualizer.bands)
                    try diagnosticRequire(!plan.matches(profile: changed), "A global EQ change must invalidate measurements")
                    let before = try app.roomCorrectionImportSnapshot(profile: profile)
                    let after = try app.roomCorrectionImportSnapshot(profile: candidate)
                    try app.storeRoomCorrectionImport(after, profileID: profile.id)
                    let stored = try box.profiles.profiles[0].resolvedProcessing()
                    try diagnosticRequire(stored == processing, "Imported chains must survive physical-channel storage")
                    try app.storeRoomCorrectionImport(before, profileID: profile.id)
                    let restored = try box.profiles.profiles[0].resolvedProcessing()
                    try diagnosticRequire(restored == original, "Undo must restore the exact previous chains")
                }
                return .init(summary: "EQ/FIR imports reach their physical-channel editors exactly once; replacement, other processing and undo are verified")
            }
        ]
    }

    private static func test(_ id: String, _ suite: String, _ name: String,
                             _ body: @escaping @MainActor (DiagnosticSandbox) async throws -> DiagnosticObservation) -> DiagnosticCase {
        DiagnosticCase(id: id, suite: suite, name: name, safety: .simulated) {
            let sandbox = try DiagnosticSandbox()
            defer { sandbox.cleanUp() }
            return try await body(sandbox)
        }
    }

    private static func audioBufferCases() -> [DiagnosticCase] {
        [
            test("AB01", "Audio Buffer", "Global inheritance, local overrides and persistence") { box in
                let inherited = DiagnosticSandbox.profile()
                var local = DiagnosticSandbox.profile(); local.name = "Local"; local.audioBufferOverride = 512
                box.profiles.profiles = [inherited, local]
                try await box.profiles.commitAudioBufferDefault(256)
                try diagnosticRequire(box.profiles.profiles.map(\.chunkSize) == [256, 512], "Global change replaced a local buffer")
                var pinned = box.profiles.profiles[0]; pinned.audioBufferOverride = 256
                box.profiles.update(pinned)
                try await box.profiles.commitAudioBufferDefault(128)
                try diagnosticRequire(box.profiles.profiles[0].chunkSize == 256, "Explicit matching size failed to pin an override")
                try await box.profiles.commitAudioBufferDefault(128, inheritingProfileIDs: [inherited.id])
                var new = DiagnosticSandbox.profile(); new.name = "New"
                _ = try await box.profiles.insertConfiguredProfile(new)
                let restored = ProfileStore(storageURL: box.directory.appendingPathComponent("profiles.json"), userDefaults: box.defaults)
                try diagnosticRequire(restored.audioBufferDefault == 128 && restored.profiles.map(\.chunkSize) == [128, 512, 128]
                    && restored.profiles.map(\.usesGlobalAudioBuffer) == [true, false, true], "Inheritance or global default did not survive reload")
                return .init(summary: "Local overrides stay pinned, reset resumes inheritance, and new profiles inherit")
            },
            test("AB02", "Audio Buffer", "Legacy custom sizes and open settings drafts remain valid") { box in
                for frames in [256, 1024] {
                    var old = DiagnosticSandbox.profile(); old.chunkSize = frames
                    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
                    json.removeValue(forKey: "usesGlobalAudioBuffer")
                    let restored = try JSONDecoder().decode(DeviceProfile.self, from: JSONSerialization.data(withJSONObject: json))
                    try diagnosticRequire(restored.usesGlobalAudioBuffer == (frames == 1024) && restored.chunkSize == frames,
                        "Legacy custom buffer was lost")
                }
                let original = DiagnosticSandbox.profile()
                var draft = ProfileSettingsDraft(profile: original, activation: .manual)
                draft.name = "Edited name"
                var fresh = original; fresh.resolveAudioBuffer(default: 128)
                let candidate = try draft.candidate(applyingTo: fresh)
                try diagnosticRequire(candidate.chunkSize == 128 && candidate.usesGlobalAudioBuffer, "Open draft restored an outdated global buffer")
                draft.audioBufferOverride = 256
                fresh.audioBufferOverride = 512
                do { _ = try draft.candidate(applyingTo: fresh); throw DiagnosticFailure(message: "Conflicting local edits accepted") }
                catch ProfileSettingsError.staleDraft { }
                return .init(summary: "Legacy custom sizes survive and drafts merge only their own edits")
            },
            test("AB03", "Audio Buffer", "Settings update the active engine and reset local inheritance") { box in
                let profile = DiagnosticSandbox.profile(); box.profiles.profiles = [profile]
                let fake = DiagnosticRuntimeFakes(.init(transportResults: Array(repeating: true, count: 20)))
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                defer { state.shutdownSynchronously() }
                await state.activate(profile: profile)
                try await state.saveGlobalAudioBuffer(256)
                try diagnosticRequire(state.runtimeCoordinator.appliedProfile?.chunkSize == 256, "Global buffer did not reach the engine")
                var draft = ProfileSettingsDraft(profile: box.profiles.profiles[0], activation: box.profiles.activationMode(for: box.profiles.profiles[0]))
                draft.audioBufferOverride = 128
                try await state.saveProfileSettings(draft)
                try await state.saveGlobalAudioBuffer(512)
                try diagnosticRequire(state.runtimeCoordinator.appliedProfile?.chunkSize == 128, "Global change replaced active local override")
                draft = ProfileSettingsDraft(profile: box.profiles.profiles[0], activation: box.profiles.activationMode(for: box.profiles.profiles[0]))
                draft.audioBufferOverride = nil
                try await state.saveProfileSettings(draft)
                try diagnosticRequire(state.runtimeCoordinator.appliedProfile?.chunkSize == 512 && box.profiles.profiles[0].usesGlobalAudioBuffer,
                    "Reset did not apply the current global value")
                return .init(summary: "Global and local settings reconfigure the live engine; reset restores inheritance")
            },
            test("AB04", "Audio Buffer", "Failed global save restores buffer and live engine") { _ in
                let f = try ProfileRepositoryFixture(); defer { f.cleanUp() }
                try await f.prepareStore()
                await f.state.activate(profile: f.profile)
                f.io.arm()
                let saving = Task { try await f.state.saveGlobalAudioBuffer(256) }
                await f.io.waitUntilEntered()
                let publishedEarly = f.store.audioBufferDefault != 1024
                f.io.release(failing: true)
                if case .success = await saving.result { throw DiagnosticFailure(message: "Failed save succeeded") }
                try diagnosticRequire(!publishedEarly && f.store.audioBufferDefault == 1024
                    && f.store.profiles.allSatisfy { $0.chunkSize == 1024 && $0.usesGlobalAudioBuffer }
                    && f.state.runtimeCoordinator.appliedProfile?.chunkSize == 1024,
                    "Failed buffer save left runtime or preferences changed")
                return .init(summary: "Persistence failure rolls back the live engine without publishing the global value")
            },
            test("AB05", "Audio Buffer", "Global save follows a newer profile switch and preserves Stop") { _ in
                for stop in [false, true] {
                    let f = try ProfileRepositoryFixture(); defer { f.cleanUp() }
                    try await f.prepareStore()
                    await f.state.activate(profile: f.profile)
                    f.io.arm()
                    let saving = Task { try await f.state.saveGlobalAudioBuffer(256) }
                    await f.io.waitUntilEntered()
                    if stop { await f.state.deactivate(manual: true) }
                    else { await f.state.activate(profile: f.other) }
                    f.io.release(); try await saving.value
                    try diagnosticRequire(f.store.audioBufferDefault == 256 && f.state.activeProfileID == (stop ? nil : f.other.id),
                        "Global save replaced newer lifecycle intent")
                    if !stop {
                        try diagnosticRequire(f.state.runtimeCoordinator.appliedProfile?.chunkSize == 256,
                            "Newly active inherited profile retained the old global buffer")
                    }
                }
                return .init(summary: "A concurrent switch gets the saved default; Stop stays stopped")
            },
            test("AB06", "Audio Buffer", "Disabled plug-in racks use no processor or additional buffer") { _ in
                for empty in [false, true] {
                    var profile = diffProfile(); profile.chunkSize = 128
                    profile.pluginRack.slots = empty ? [] : [.init(plugin: pluginTestDescriptor())]
                    profile.pluginRack.isEnabled = false
                    let plan = try diffPlan(profile)
                    let manager = PluginRackManager(); defer { manager.stop() }
                    try await manager.prepare(plan)
                    let processor = manager.commit(plan)
                    try diagnosticRequire(processor == nil && manager.statuses[profile.id]?.latencyMilliseconds == 0
                        && plan.processingGraph.chunkSize == 128, "Disabled rack retained buffering or a live processor")
                }
                return .init(summary: "Disabled and empty racks bypass the host while retaining only CamiTune's engine buffer")
            }
        ]
    }

    private static func automaticBufferCases() -> [DiagnosticCase] {
        [
            test("AB07", "Automatic Buffer", "Automatic preference inherits and survives persistence") { box in
                let profile = DiagnosticSandbox.profile(); box.profiles.profiles = [profile]
                try await box.profiles.commitAudioBufferDefault(.automatic)
                var local = box.profiles.profiles[0]; local.audioBufferOverride = 256
                box.profiles.update(local)
                var other = DiagnosticSandbox.profile(); other.name = "Automatic local"; other.audioBufferOverride = .automatic
                _ = try await box.profiles.insertConfiguredProfile(other)
                let restored = ProfileStore(storageURL: box.directory.appendingPathComponent("profiles.json"), userDefaults: box.defaults)
                try diagnosticRequire(restored.audioBufferDefault == .automatic
                    && restored.profiles.map(\.audioBufferOverride) == [256, .automatic]
                    && restored.profiles.allSatisfy { $0.chunkSize > 0 }, "Automatic mode or local overrides changed on reload")
                try await box.profiles.commitAudioBufferDefault(.automatic, inheritingProfileIDs: [profile.id])
                try diagnosticRequire(box.profiles.profiles[0].usesGlobalAudioBuffer
                    && box.profiles.profiles[0].audioBufferSetting == .automatic, "Reset failed to inherit Automatic")
                return .init(summary: "Automatic is a preference, never a zero-sized block; local/global choices round-trip")
            },
            test("AB08", "Automatic Buffer", "Only sustained complete evidence lowers the recommendation") { _ in
                var policy = AutomaticAudioBufferPolicy(frames: 1024)
                for _ in 0..<90 {
                    policy.observe(.init(audioSeconds: 0, dspLoad: 0, writerLoad: 0, pluginLoad: 0, underruns: 0), currentFrames: 1024)
                    policy.observe(.init(audioSeconds: 1, dspLoad: nil, writerLoad: 0, pluginLoad: 0, underruns: nil), currentFrames: 1024)
                }
                try diagnosticRequire(policy.recommendedFrames == 1024, "Silence or missing telemetry authorized a reduction")
                for _ in 0..<59 { policy.observe(.init(audioSeconds: 1, dspLoad: 0.05, writerLoad: 0.05, pluginLoad: 0.02, underruns: 0), currentFrames: 1024) }
                try diagnosticRequire(policy.recommendedFrames == 1024, "Short clean sample authorized a reduction")
                for _ in 0..<100 { policy.observe(.init(audioSeconds: 1, dspLoad: 0.05, writerLoad: 0.05, pluginLoad: 0.02, underruns: 0), currentFrames: 1024) }
                try diagnosticRequire(policy.recommendedFrames == 512, "Recommendation skipped an untested size or failed to learn")
                return .init(summary: "Sixty seconds of clean active audio permit one step down; silence and unknown evidence do not")
            },
            test("AB09", "Automatic Buffer", "Underruns and plug-in pressure establish a remembered safety floor") { _ in
                for failure in 0..<3 {
                    var policy = AutomaticAudioBufferPolicy(frames: 256)
                    for _ in 0..<3 {
                        policy.observe(.init(audioSeconds: 1, dspLoad: 0.1, writerLoad: failure == 2 ? 0.7 : 0.05,
                            pluginLoad: failure == 2 ? 0.6 : 0.02, underruns: failure == 0 ? 1 : 0,
                            pluginFailed: failure == 1), currentFrames: 256)
                    }
                    try diagnosticRequire(policy.recommendedFrames == 512 && policy.minimumFrames == 512, "Fault did not raise the safety floor")
                    for _ in 0..<180 { policy.observe(.init(audioSeconds: 1, dspLoad: 0.01, writerLoad: 0.01, pluginLoad: 0, underruns: 0), currentFrames: 512) }
                    try diagnosticRequire(policy.recommendedFrames == 512, "Controller retried a size already known to fail")
                }
                var interrupted = AutomaticAudioBufferPolicy(frames: 256)
                for _ in 0..<4 {
                    interrupted.observe(.init(audioSeconds: 1, dspLoad: 0.8, writerLoad: 0.1, pluginLoad: 0, underruns: 0), currentFrames: 256)
                    interrupted.observe(.init(audioSeconds: 0, dspLoad: nil, writerLoad: 0, pluginLoad: 0, underruns: nil), currentFrames: 256)
                }
                try diagnosticRequire(interrupted.recommendedFrames == 256, "Interrupted observations counted as sustained overload")
                try diagnosticRequire(AutomaticAudioBufferPolicy.startingFrames(sampleRate: 192000) == 4096,
                    "High sample rates lost the initial safety margin")
                return .init(summary: "DSP underruns, plug-in faults and sustained processing pressure recommend more headroom without oscillation")
            },
            test("AB10", "Automatic Buffer", "Live sessions pin their buffer across settings and processing edits") { box in
                var profile = DiagnosticSandbox.profile(); profile.audioBufferOverride = .automatic
                box.profiles.profiles = [profile]
                let fake = DiagnosticRuntimeFakes(.init(transportResults: Array(repeating: true, count: 30)))
                var recommendation = 512
                var services = fake.services(); services.automaticBufferSize = { _ in recommendation }
                var simulatedRate = 48000.0
                let setRate = services.setRate
                services.setRate = { uid, rate in try await setRate(uid, rate); simulatedRate = rate }
                services.nominalRate = { _ in simulatedRate }
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
                defer { state.shutdownSynchronously() }
                await state.activate(profile: profile)
                try diagnosticRequire(state.runtimeCoordinator.appliedProfile?.chunkSize == 512, "Activation ignored recommendation")
                let starts = fake.events.filter { $0 == "start engine" }.count
                recommendation = 128
                var draft = ProfileSettingsDraft(profile: box.profiles.profiles[0], activation: box.profiles.activationMode(for: profile))
                draft.name = "Updated name"
                try await state.saveProfileSettings(draft)
                let saved = box.profiles.profiles[0]
                await state.apply(profile: saved)
                try diagnosticRequire(state.runtimeCoordinator.appliedProfile?.chunkSize == 512
                    && fake.events.filter { $0 == "start engine" }.count == starts, "Recommendation restarted a live engine")
                await state.deactivate(manual: true)
                let nextSessionProfile = box.profiles.profiles[0]
                await state.activate(profile: nextSessionProfile)
                try diagnosticRequire(state.runtimeCoordinator.appliedProfile?.chunkSize == 128, "Next session did not apply learned size")
                var newRate = ProfileSettingsDraft(profile: nextSessionProfile, activation: box.profiles.activationMode(for: nextSessionProfile))
                newRate.sampleRate = 96000; recommendation = 2048
                try await state.saveProfileSettings(newRate)
                try diagnosticRequire(state.runtimeCoordinator.appliedProfile?.chunkSize == 2048,
                    "A new sample-rate session borrowed the old setup's buffer")
                return .init(summary: "New sessions use learned sizes; ordinary live edits keep the buffer fixed")
            },
            test("AB11", "Automatic Buffer", "Learning keys isolate hardware, processing and active plug-ins") { _ in
                var profile = DiagnosticSandbox.profile()
                let original = AutomaticAudioBufferController.setupKey(for: profile)
                profile.name = "Renamed"; profile.chunkSize = 128; profile.audioBufferOverride = .automatic
                try diagnosticRequire(AutomaticAudioBufferController.setupKey(for: profile) == original, "Presentation or buffer choice invalidated processing evidence")
                profile.pluginRack.slots = [.init(plugin: pluginTestDescriptor())]
                profile.pluginRack.isEnabled = false
                try diagnosticRequire(AutomaticAudioBufferController.setupKey(for: profile) == original, "Bypassed effects affected buffer learning")
                profile.pluginRack.isEnabled = true
                let withPlugins = AutomaticAudioBufferController.setupKey(for: profile)
                try diagnosticRequire(withPlugins != original, "Active effects borrowed bypass evidence")
                profile.sampleRate = 96000
                try diagnosticRequire(AutomaticAudioBufferController.setupKey(for: profile) != withPlugins, "Sample rates shared learned settings")
                return .init(summary: "Evidence is specific to the setup; disabled plug-ins do not contribute")
            },
            test("AB12", "Automatic Buffer", "Recommendations persist without changing user preferences or samples") { _ in
                var profile = DiagnosticSandbox.profile(); profile.audioBufferOverride = .automatic
                var data: Data?
                let controller = AutomaticAudioBufferController(persist: { data = $0 })
                let start = Date().addingTimeInterval(-120)
                controller.begin(profile: profile, now: start)
                var work = AudioBufferWorkObservation(); work.audioSeconds = 1; work.writerLoad = 0.02
                for second in 1...65 {
                    controller.observe(work: work, dspLoadPercent: 3, clockEpoch: 7, underrunFrames: 0,
                        droppedFrames: 0, now: start.addingTimeInterval(Double(second)))
                }
                try diagnosticRequire(controller.statuses[profile.id]?.nextFrames == 512 && data != nil
                    && profile.chunkSize == 1024 && profile.audioBufferSetting == .automatic, "Learning mutated the active profile or failed to persist")
                let restored = AutomaticAudioBufferController(cache: data)
                try diagnosticRequire(restored.recommendedFrames(for: profile) == 512, "Learned recommendation did not survive restart")
                let now = Date()
                try diagnosticRequire(controller.hasPendingChange(profileID: profile.id, now: now), "Learned change was not pending")
                controller.noteChangeAttempt(now: now)
                try diagnosticRequire(!controller.hasPendingChange(profileID: profile.id, now: now.addingTimeInterval(29))
                    && controller.hasPendingChange(profileID: profile.id, now: now.addingTimeInterval(30)),
                    "Automatic retries did not respect their cooldown")
                controller.end()
                try diagnosticRequire(controller.statuses[profile.id] == nil, "Stopped session retained a live buffer status")
                return .init(summary: "Only recommendations are cached; the active profile and audio remain unchanged")
            },
            test("AB13", "Automatic Buffer", "Silence requires exact zero on every channel and a fresh output clock") { _ in
                let graph = try diffPlan(diffProfile()).processingGraph
                let zero = SignalLevels(capturePeak: Array(repeating: -1000, count: graph.channelCount), captureRMS: [],
                    playbackPeak: Array(repeating: -1000, count: graph.outputFormat.channelCount), playbackRMS: [])
                let clock = CamillaPlaybackClock(epoch: 1, sampleTime: 48000, hostTime: 1_000_000,
                    nominalRate: Double(graph.sampleRate), timestampFlags: 3, demandFrames: 48000, underrunFrames: 0,
                    callbackFrames: 256, bufferedFrames: 512)
                func accepts(_ levels: SignalLevels, now: UInt64 = 1_000_000) -> Bool {
                    AutomaticAudioBufferController.confirmsSilentOutput(levels, clock: clock, graph: graph, nowHostTime: now)
                }
                try diagnosticRequire(accepts(zero), "Verified digital silence was rejected")
                for peak in [-150.0, -300, -.infinity, .nan, 0] {
                    var levels = zero; levels.playbackPeak[0] = peak
                    try diagnosticRequire(!accepts(levels), "Quiet music or invalid output counted as exact silence")
                    levels = zero; levels.capturePeak[0] = peak
                    try diagnosticRequire(!accepts(levels), "Nonzero engine input counted as silence")
                }
                var missing = zero; missing.playbackPeak = []
                try diagnosticRequire(!accepts(missing) && !accepts(zero, now: 999_999)
                    && !accepts(zero, now: 1_000_000_000_000_000), "Missing/stale/future telemetry authorized a change")
                return .init(summary: "All channels must report digital zero; meter floors and stale/missing clocks fail closed")
            },
            test("AB14", "Automatic Buffer", "Pending sizes apply only after the final silence check") { box in
                var profile = DiagnosticSandbox.profile(); profile.audioBufferOverride = .automatic
                box.profiles.profiles = [profile]
                let fake = DiagnosticRuntimeFakes(.init(transportResults: Array(repeating: true, count: 10)))
                var frames = 1024, quietReads = 0
                var quiet: [Bool] = []
                var services = fake.services()
                services.automaticBufferSize = { _ in frames }
                services.automaticBufferIsQuiet = { quietReads += 1; return quiet.isEmpty ? false : quiet.removeFirst() }
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
                defer { state.shutdownSynchronously() }
                await state.activate(profile: profile)
                let starts = fake.events.filter { $0 == "start engine" }.count
                let session = state.activeSession?.id
                frames = 512
                quiet = [false]
                await state.runtimeCoordinator.applyAutomaticBufferIfQuiet()
                quiet = [true, false] // Playback resumes during preparation.
                await state.runtimeCoordinator.applyAutomaticBufferIfQuiet()
                try diagnosticRequire(state.runtimeCoordinator.appliedProfile?.chunkSize == 1024
                    && fake.events.filter { $0 == "start engine" }.count == starts, "Resumed audio was restarted")
                quiet = [true, true]
                await state.runtimeCoordinator.applyAutomaticBufferIfQuiet()
                try diagnosticRequire(state.runtimeCoordinator.appliedProfile?.chunkSize == 512
                    && box.profiles.profiles[0].audioBufferOverride == .automatic && quietReads == 5,
                    "Silence did not apply the learned size, or Automatic was replaced by a manual preference")
                try diagnosticRequire(state.activeSession?.id == session
                    && fake.events.filter { $0 == "start engine" }.count == starts
                    && !fake.events.contains("stop PCM") && !fake.events.contains("stop transport")
                    && !fake.events.contains("begin handoff"), "Automatic tuning interrupted the live signal path")
                let reads = quietReads
                frames = 256; var manual = box.profiles.profiles[0]; manual.audioBufferOverride = 1024
                box.profiles.update(manual)
                await state.runtimeCoordinator.applyAutomaticBufferIfQuiet()
                try diagnosticRequire(quietReads == reads, "Automatic tuning ignored a newer manual choice")
                return .init(summary: "Pending tuning respects resumed playback and manual choices; verified silence applies without changing preferences")
            },
            test("AB15", "Automatic Buffer", "Failed preparation leaves the live engine and size untouched") { box in
                var profile = DiagnosticSandbox.profile(); profile.audioBufferOverride = .automatic
                box.profiles.profiles = [profile]
                let fake = DiagnosticRuntimeFakes(.init(transportResults: Array(repeating: true, count: 10)))
                var frames = 1024
                var services = fake.services(); services.automaticBufferSize = { _ in frames }
                services.automaticBufferIsQuiet = { true }
                services.prepareAutomaticBuffer = { _ in throw DiagnosticFailure(message: "Rejected smaller buffer") }
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
                defer { state.shutdownSynchronously() }
                await state.activate(profile: profile); frames = 512
                await state.runtimeCoordinator.applyAutomaticBufferIfQuiet()
                try diagnosticRequire(state.isActive && state.runtimeCoordinator.appliedProfile?.chunkSize == 1024
                    && !fake.events.contains("stop engine") && !fake.events.contains("stop PCM")
                    && !fake.events.contains("commit buffer engine"),
                    "Optional tuning failure abandoned the working audio setup")
                return .init(summary: "A rejected standby never replaces or restarts the active audio path")
            },
            test("AB16", "Automatic Buffer", "Source silence ignores mute and includes alternate PCM buses") { box in
                let path = box.directory.appendingPathComponent("silence.pcm")
                FileManager.default.createFile(atPath: path.path, contents: nil)
                let file = try FileHandle(forWritingTo: path), router = PCMRouter()
                defer { router.stop(); try? file.close() }
                await router.start(camillaSink: file, renderConfiguration: .init(),
                    deliveryConfiguration: .legacy(sampleRate: 48000, chunkSize: 128), backendChunkFrames: 128)
                let afterQuietWindow = PerformanceClock.now().advanced(seconds: 3)
                router.route(.init(interleaved: Array(repeating: 0, count: 512), channelCount: 2, sampleRate: 48000))
                router.finishProducerEpoch()
                let deadline = PerformanceClock.now().advanced(seconds: 2)
                while !router.isQuietForBufferChange(now: afterQuietWindow), PerformanceClock.now() < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try diagnosticRequire(router.isQuietForBufferChange(now: afterQuietWindow), "Drained digital silence never became eligible")
                router.setSystemMaster(linearGain: 0, muted: true)
                var frame = PCMFrame(interleaved: Array(repeating: 0, count: 512), channelCount: 2, sampleRate: 48000)
                frame.playbackModeSamples[.spatialRender] = Array(repeating: Float.leastNonzeroMagnitude, count: 512)
                router.route(frame)
                try diagnosticRequire(!router.isQuietForBufferChange(now: afterQuietWindow), "Muted/alternate-bus signal did not invalidate silence")
                router.stop()
                try diagnosticRequire(!router.isQuietForBufferChange(now: afterQuietWindow), "Stopped writer was treated as verified silence")
                return .init(summary: "Only exact zero qualifies; system mute and alternate routing cannot hide activity")
            },
            test("AB17", "Automatic Buffer", "Stop supersedes a silent buffer plan still being prepared") { box in
                var profile = DiagnosticSandbox.profile(); profile.audioBufferOverride = .automatic
                box.profiles.profiles = [profile]
                let fake = DiagnosticRuntimeFakes(.init(transportResults: Array(repeating: true, count: 10)))
                let gate = DiagnosticManualGate()
                var frames = 1024, pausePreparation = false
                var services = fake.services(); services.automaticBufferSize = { _ in frames }
                services.automaticBufferIsQuiet = { true }
                services.prepareAssets = { _ in
                    if pausePreparation { try await gate.enter() }
                    return .empty
                }
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: services)
                defer { gate.release(); state.shutdownSynchronously() }
                await state.activate(profile: profile)
                let starts = fake.events.filter { $0 == "start engine" }.count
                frames = 512; pausePreparation = true
                let adjustment = Task { await state.runtimeCoordinator.applyAutomaticBufferIfQuiet() }
                try await gate.waitUntilEntered()
                await state.deactivate(manual: true)
                gate.release(); await adjustment.value
                try diagnosticRequire(!state.isActive && fake.events.filter { $0 == "start engine" }.count == starts,
                    "Background buffer tuning resurrected a stopped session")
                return .init(summary: "A newer Stop cancels prepared background tuning before any restart")
            },
            test("AB18", "Automatic Buffer", "Elapsed quiet time cannot erase a pending effect history") { box in
                final class DelayedSilentProcessor: PluginAudioProcessor, @unchecked Sendable {
                    let tailFrames = 0
                    func bufferChangeTailSeconds(sampleRate: Double) -> Double { 2 }
                    func process(_ samples: inout [Float], sampleRate: Double, reset: Bool) -> Bool { true }
                }
                let path = box.directory.appendingPathComponent("silent-tail.pcm")
                FileManager.default.createFile(atPath: path.path, contents: nil)
                let file = try FileHandle(forWritingTo: path), router = PCMRouter()
                defer { router.stop(); try? file.close() }
                await router.start(camillaSink: file, renderConfiguration: .init(),
                    deliveryConfiguration: .legacy(sampleRate: 48000, chunkSize: 128), backendChunkFrames: 128,
                    pluginProcessor: DelayedSilentProcessor())
                let later = PerformanceClock.now().advanced(seconds: 15)
                func drain(_ samples: Int, count: UInt64) async throws {
                    router.route(.init(interleaved: Array(repeating: 0, count: samples), channelCount: 2, sampleRate: 48000))
                    router.finishProducerEpoch()
                    let deadline = PerformanceClock.now().advanced(seconds: 2)
                    while router.statistics.producerDrains.completedDrains < count, PerformanceClock.now() < deadline {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    try diagnosticRequire(router.statistics.producerDrains.completedDrains == count, "Silent fixture did not drain")
                }
                try await drain(512, count: 1)
                try diagnosticRequire(!router.isQuietForBufferChange(now: later), "Wall time alone authorized discarding delayed audio")
                try await drain(240_000, count: 2)
                try diagnosticRequire(router.isQuietForBufferChange(now: later), "Fully flushed silent history never became eligible")
                let bytes = try Data(contentsOf: path)
                try diagnosticRequire(!bytes.isEmpty && bytes.allSatisfy { $0 == 0 }, "Silence observation altered PCM")
                return .init(summary: "Effect history must receive enough silent samples; waiting while paused is insufficient")
            }
        ]
    }

    private static func profileCases() -> [DiagnosticCase] {
        [
            test("P01", "Profiles", "Profile persistence round trip") { box in
                let profile = DiagnosticSandbox.profile()
                box.profiles.profiles = [profile]
                box.profiles.flushPendingSaveSynchronously()
                let restored = ProfileStore(storageURL: box.directory.appendingPathComponent("profiles.json"), userDefaults: box.defaults)
                try diagnosticRequire(restored.profiles == [profile], "Profile fields changed during persistence")
                return .init(summary: "All profile fields survived save and reload")
            },
            test("P02", "Profiles", "Legacy document migration") { box in
                let profile = DiagnosticSandbox.profile()
                let url = box.directory.appendingPathComponent("legacy.json")
                try JSONEncoder().encode([profile]).write(to: url)
                let restored = ProfileStore(storageURL: url, userDefaults: box.defaults)
                try diagnosticRequire(restored.profiles.first?.id == profile.id, "Legacy array was not loaded")
                restored.profiles[0].name = "Migrated fixture"
                restored.flushPendingSaveSynchronously()
                let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
                try diagnosticRequire(document?["schemaVersion"] != nil, "Legacy document did not save in the current schema")
                return .init(summary: "Legacy array migrated and saved as a versioned document")
            },
            test("P03", "Profiles", "Future schema protection") { box in
                let url = box.directory.appendingPathComponent("future.json")
                let bytes = Data(#"{"schemaVersion":2147483647,"profiles":[]}"#.utf8)
                try bytes.write(to: url)
                let restored = ProfileStore(storageURL: url, userDefaults: box.defaults)
                try diagnosticRequire(restored.persistenceError != nil, "Future schema did not report an error")
                restored.profiles = [DiagnosticSandbox.profile()]
                restored.flushPendingSaveSynchronously()
                let after = try Data(contentsOf: url)
                try diagnosticRequire(after == bytes, "Future schema storage was overwritten")
                return .init(summary: "Unsupported storage remained byte-for-byte unchanged")
            }
        ]
    }

    private static func planningCases() -> [DiagnosticCase] {
        [
            test("P04", "Planning & Configuration", "Stereo graph construction") { _ in
                let profile = DiagnosticSandbox.profile()
                let graph = try ActiveAudioRoute(profile: profile).buildGraph(profile: profile, assets: .empty)
                try graph.validate()
                try diagnosticRequire(graph.inputFormat.channelCount == 2 && graph.outputFormat.channelCount == 2, "Unexpected stereo formats")
                return .init(summary: "Stereo graph validates", evidence: [.init(name: "Stages", value: "\(graph.pipeline.count)")])
            },
            test("P05", "Planning & Configuration", "Multichannel runtime plan") { _ in
                var profile = DiagnosticSandbox.profile()
                let hardware = DiagnosticHardware(channels: 6)
                profile.endpointKind = .speakers
                profile.speakerTopology = try SpeakerLayoutGeometry.acceptingDefaultRoles(hardware.topology(for: profile.outputDeviceUID, sampleRate: 48_000).speakerTopology)
                let plan = try AudioRuntimePlanPreparer.prepare(profile: profile, hardware: hardware)
                let route = try ActiveAudioRoute(profile: profile)
                try diagnosticRequire(plan.sourceFormat == route.sourceFormat && plan.dspInputFormat == route.dspInputFormat, "Plan source/DSP formats differ from the current route")
                try diagnosticRequire(plan.hardwareOutputFormat.channelCount == 6 && plan.physicalEndpointFormat.channelCount == 6, "Expected six physical channels")
                try diagnosticRequire(plan.profileRoutingDescriptor.uid == ProfileRoutingDescriptor.uid(for: profile.id), "Routing identity changed")
                let fingerprint = try hardware.topology(for: profile.outputDeviceUID, sampleRate: 48_000).fingerprint
                try diagnosticRequire(plan.hardwareFingerprint == fingerprint, "Hardware fingerprint mismatch")
                try plan.processingGraph.validate()
                return .init(summary: "All plan formats, routing identity, fingerprint, and graph verified")
            },
            test("P06", "Planning & Configuration", "Hardware channel mismatch") { _ in
                do {
                    _ = try AudioRuntimePlanPreparer.prepare(profile: DiagnosticSandbox.profile(), hardware: DiagnosticHardware(channels: 6))
                } catch SpeakerTopologyError.hardwareLayoutChanged {
                    return .init(summary: "Mismatched channel count rejected")
                }
                throw DiagnosticFailure(message: "Expected hardware layout mismatch")
            },
            test("P07", "Planning & Configuration", "Malformed processing input") { _ in
                var profile = DiagnosticSandbox.profile()
                profile.equalizerAPOText = "Filter 1: ON PK Fc invalid Hz Gain broken dB Q nope"
                do { _ = try ActiveAudioRoute(profile: profile).buildGraph(profile: profile, assets: .empty) }
                catch { return .init(summary: "Malformed processing was rejected") }
                throw DiagnosticFailure(message: "Malformed EQ unexpectedly produced a graph")
            },
            test("P08", "Planning & Configuration", "Headroom invariants") { _ in
                let profile = DiagnosticSandbox.profile()
                let first = try ActiveAudioRoute(profile: profile).buildGraph(profile: profile, assets: .empty)
                let second = try ActiveAudioRoute(profile: profile).buildGraph(profile: profile, assets: .empty)
                try diagnosticRequire(first.automaticHeadroomDB.isFinite && first.automaticHeadroomDB <= 0 && first.automaticHeadroomDB >= -120, "Headroom outside the legal range")
                try diagnosticRequire(first.automaticHeadroomDB == second.automaticHeadroomDB, "Headroom is not deterministic")
                var disabled = profile
                disabled.processing.global.stages.append(.init(isEnabled: false, processor: .gain(.init(gainDB: 30))))
                let ignored = try ActiveAudioRoute(profile: disabled).buildGraph(profile: disabled, assets: .empty)
                try diagnosticRequire(first.automaticHeadroomDB == ignored.automaticHeadroomDB, "Disabled gain affected headroom")
                return .init(summary: "Finite, bounded, repeatable headroom; disabled gain ignored")
            },
            test("P09", "Planning & Configuration", "Graph update behavior") { _ in
                let profile = DiagnosticSandbox.profile()
                let graph = try ActiveAudioRoute(profile: profile).buildGraph(profile: profile, assets: .empty)
                let differ = ProcessingGraphDiffer()
                try diagnosticRequire(differ.update(from: graph, to: graph) == .unchanged, "Identical graph is not unchanged")
                var next = graph
                next.sampleRate = 96_000
                try diagnosticRequire(differ.update(from: graph, to: next) == .replaceConfiguration, "Format change did not require replacement")
                if let index = next.processors.firstIndex(where: { if case .gain = $0.implementation { return true }; return false }) {
                    next = graph
                    next.processors[index].implementation = .gain(db: -3)
                    guard case .patch = differ.update(from: graph, to: next) else { throw DiagnosticFailure(message: "Gain change did not use a patch") }
                } else { throw DiagnosticFailure(message: "Fixture lacks a gain processor") }
                return .init(summary: "Unchanged, gain patch, and full replacement paths verified")
            }
        ]
    }

    private static let instant = Date(timeIntervalSince1970: 1_000)
    private static func packet(_ client: UInt32 = 1, _ start: Double = 0, _ frames: Int = 4, _ value: Float = 0.25,
                               rate: Double = 48_000, channels: Int = 2) -> PerAppAudioPacket {
        PerAppAudioPacket(deviceObjectID: 100, clientID: client, processID: 0,
                         cycleCounter: UInt64(max(0, start / 4)), sampleTime: start,
                         interleaved: Array(repeating: value, count: frames * channels),
                         channelCount: channels, sampleRate: rate)
    }
    private static func flush(_ controller: TimelineMixerFixture) throws -> PCMFrame {
        guard case .flushed(let frame) = controller.flushExpiredMix(now: instant.addingTimeInterval(1)) else {
            throw DiagnosticFailure(message: "Expected pending audio to flush")
        }
        return frame
    }
    private static func flush(_ controller: PerAppAudioController) throws -> PCMFrame {
        guard case .flushed(let frame) = controller.flushExpiredMix(now: instant.addingTimeInterval(1), policyNow: PerformanceClock.now().advanced(seconds: 1)) else {
            throw DiagnosticFailure(message: "Expected pending audio to flush")
        }
        return frame
    }
    private static func samples(_ actual: [Float], _ expected: [Float]) throws {
        try diagnosticRequire(actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) < 0.0001 }, "PCM samples or frame count differ from the expected timeline")
    }

    private static func pcmCases() -> [DiagnosticCase] {
        [
            test("A09", "Speaker Identification", "Physical tests silence unselected outputs") { _ in
                for channels in [1, 2, 8, 32] {
                    let topology = try SpeakerTopologyResolver().resolve(deviceUID: "test:audition",
                        sampleRate: 8_000, channelCount: channels, channels: [])
                    for selected in Set([0, channels - 1]) {
                        let id = PhysicalOutputID(deviceUID: topology.deviceUID, channelIndex: selected)
                        guard let clip = SpatialCalibrationClip(physicalOutput: id, topology: topology) else {
                            throw DiagnosticFailure(message: "Could not prepare the physical test")
                        }
                        // Stand in for the driver-protection stage: its output
                        // must survive packing without restoring the raw clip.
                        let mono = SpeakerOutputAudition.monoSamples(clip, output: selected).map { $0 * 0.5 }
                        let output = try SpeakerOutputAudition.interleavedSamples(mono,
                            output: selected, channelCount: channels)
                        try diagnosticRequire(output.count == clip.samples.count && mono.contains { $0 != 0 },
                            "Identification lost its signal or frame count")
                        for channel in 0..<channels {
                            let values = stride(from: channel, to: output.count, by: channels).map { output[$0] }
                            try diagnosticRequire(channel == selected ? values == mono : values.allSatisfy { $0 == 0 },
                                "Identification leaked into output \(channel + 1) or changed the protected signal")
                        }
                    }
                }
                do {
                    _ = try SpeakerOutputAudition.interleavedSamples([0.01], output: 2, channelCount: 2)
                    throw DiagnosticFailure(message: "An unavailable output was accepted")
                } catch SpeakerTopologyError.invalidChannelIndex { }
                return .init(summary: "Left/right and multichannel tests preserve the selected signal and send exact zeros to every other output")
            },
            test("A01", "PCM / Timeline", "One client") { _ in
                let mixer = TimelineMixerFixture()
                _ = mixer.ingest(packet(), now: instant)
                try samples(flush(mixer).interleaved, Array(repeating: 0.25, count: 8))
                return .init(summary: "Single-client samples preserved")
            },
            test("A02", "PCM / Timeline", "Two clients, same interval") { _ in
                let mixer = TimelineMixerFixture()
                _ = mixer.ingest(packet(1), now: instant)
                _ = mixer.ingest(packet(2), now: instant)
                try samples(flush(mixer).interleaved, Array(repeating: 0.5, count: 8))
                return .init(summary: "Coincident intervals summed")
            },
            test("A03", "PCM / Timeline", "Overlapping intervals") { _ in
                let mixer = TimelineMixerFixture()
                _ = mixer.ingest(packet(1, 0), now: instant)
                _ = mixer.ingest(packet(2, 2), now: instant)
                try samples(flush(mixer).interleaved, [0.25, 0.25, 0.25, 0.25, 0.5, 0.5, 0.5, 0.5, 0.25, 0.25, 0.25, 0.25])
                return .init(summary: "Overlap summed; both non-overlapping tails preserved")
            },
            test("A04", "PCM / Timeline", "Unequal packet sizes") { _ in
                let mixer = TimelineMixerFixture()
                let first = mixer.ingest(packet(1, 0, 256), now: instant)
                let second = mixer.ingest(packet(2, 0, 1024), now: instant)
                try diagnosticRequire(first == nil && second == nil, "Current holdback policy changed")
                try samples(flush(mixer).interleaved, Array(repeating: 0.5, count: 512) + Array(repeating: 0.25, count: 1536))
                return .init(summary: "256/1024-frame packets retain holdback and mix correctly")
            },
            test("A05", "PCM / Timeline", "Late packet") { _ in
                let mixer = TimelineMixerFixture()
                _ = mixer.ingest(packet(1, 400, 4, 1), now: instant)
                _ = mixer.ingest(packet(1, 404, 4, 0), now: instant)
                _ = mixer.ingest(packet(2, 400, 4, 2), now: instant)
                let emitted = mixer.ingest(packet(1, 408, 4, 0), now: instant)
                try samples(emitted?.interleaved ?? [], Array(repeating: 3, count: 8))
                let late = mixer.ingest(packet(2, 400, 4, 4), now: instant)
                try diagnosticRequire(late == nil, "Already emitted audio was replayed")
                _ = mixer.ingest(packet(2, 402, 4, 4), now: instant)
                let next = mixer.ingest(packet(1, 412, 4, 0), now: instant)
                try samples(next?.interleaved ?? [], [4, 4, 4, 4, 0, 0, 0, 0])
                return .init(summary: "Stale audio rejected; only the unrendered suffix of a partially late packet retained")
            },
            test("A06", "PCM / Timeline", "Short sound idle flush") { _ in
                let mixer = TimelineMixerFixture()
                _ = mixer.ingest(packet(), now: instant)
                guard case .retryAfter = mixer.flushExpiredMix(now: instant.addingTimeInterval(0.003)) else {
                    throw DiagnosticFailure(message: "Tail flushed before its deadline")
                }
                guard case .flushed(let frame) = mixer.flushExpiredMix(now: instant.addingTimeInterval(0.020)) else {
                    throw DiagnosticFailure(message: "Short sound tail was lost")
                }
                try samples(frame.interleaved, Array(repeating: 0.25, count: 8))
                return .init(summary: "Tail emitted after an explicit 20 ms advance; no sleep")
            },
            test("A07", "PCM / Timeline", "Format change") { _ in
                let mixer = TimelineMixerFixture()
                _ = mixer.ingest(packet(), now: instant)
                _ = mixer.ingest(packet(1, 0, 4, 0.5, rate: 96_000, channels: 1), now: instant)
                let frame = try flush(mixer)
                try diagnosticRequire(frame.sampleRate == 96_000 && frame.channelCount == 1, "New format did not replace pending timeline")
                try samples(frame.interleaved, Array(repeating: 0.5, count: 4))
                return .init(summary: "Rate/channel/layout change reset pending audio")
            },
            test("A08", "PCM / Timeline", "Runtime reset") { _ in
                let mixer = TimelineMixerFixture()
                _ = mixer.ingest(packet(), now: instant)
                mixer.resetRuntime()
                guard case .idle = mixer.flushExpiredMix(now: instant.addingTimeInterval(1)) else {
                    throw DiagnosticFailure(message: "Old pending audio survived reset")
                }
                _ = mixer.ingest(packet(1, 0, 4, 0.5), now: instant)
                try samples(flush(mixer).interleaved, Array(repeating: 0.5, count: 8))
                return .init(summary: "Reset discarded prior stream and accepted a fresh timeline")
            }
        ]
    }

    private static func lifecycleCases() -> [DiagnosticCase] {
        func lifecycle(_ id: String, _ name: String, scenario: DiagnosticRuntimeFakes.Scenario = .init(),
                       body: @escaping @MainActor (AppState, DiagnosticRuntimeFakes, DeviceProfile) async throws -> Void) -> DiagnosticCase {
            test(id, "Runtime Lifecycle", name) { box in
                let fake = DiagnosticRuntimeFakes(scenario)
                let profile = DiagnosticSandbox.profile()
                box.profiles.profiles = [profile]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                do {
                    try await body(state, fake, profile)
                    if state.isActive { await state.deactivate() }
                    try fake.assertStopped(state)
                } catch {
                    await state.deactivate()
                    throw DiagnosticFailure(message: "\(error.localizedDescription)\nEvents: \(fake.events.joined(separator: " → "))")
                }
                return .init(summary: "Production lifecycle assertions passed", evidence: fake.evidence)
            }
        }
        return [
            lifecycle("L01", "Normal activation") { state, fake, profile in
                await state.activate(profile: profile)
                try diagnosticRequire(state.isActive && state.activeSession?.profileID == profile.id, "Activation did not publish its session")
                for resource in ["engine", "volume", "PCM", "transport", "observations", "spectrum"] {
                    try diagnosticRequire(fake.events.filter { $0 == "start \(resource)" }.count == 1, "Expected one start for \(resource)")
                }
            },
            lifecycle("L02", "Missing physical output", scenario: .init(outputPresent: false)) { state, fake, profile in
                await state.activate(profile: profile)
                try diagnosticRequire(!state.isActive && !fake.events.contains("start engine") && fake.transportAttempts == 0, "Missing output reached pipeline startup")
            },
            lifecycle("L03", "Graph failure rollback", scenario: .init(graphFails: true)) { state, fake, profile in
                await state.activate(profile: profile)
                try diagnosticRequire(!state.isActive && fake.events.contains("start engine") && fake.events.contains("apply graph"), "Graph failure scenario did not run")
            },
            lifecycle("L04", "Stop during activation — never acknowledged") { state, fake, profile in
                let gate = DiagnosticManualGate()
                fake.scenario.routingGate = gate
                async let activation: Void = state.activate(profile: profile)
                do {
                    try await gate.waitUntilEntered()
                    try diagnosticRequire(state.transitionInProgress, "Activation was not suspended")
                    await state.deactivate()
                    try diagnosticRequire(state.transitionInProgress, "Suspended activation lost its transition context")
                    gate.release()
                    await activation
                    // The worker cleans the superseded provisional attempt.
                    try await fake.stopped.enter()
                    try diagnosticRequire(!fake.events.contains("notify activation"), "Superseded activation was acknowledged")
                } catch {
                    gate.cancel()
                    await activation
                    throw error
                }
            },
            lifecycle("L05", "Transport retries", scenario: .init(transportResults: [false, false, true])) { state, fake, profile in
                await state.activate(profile: profile)
                try diagnosticRequire(state.isActive && fake.transportAttempts == 3, "Expected activation after exactly three attempts")
            },
            lifecycle("L06", "Transport retry exhaustion", scenario: .init(transportResults: [false, false, false])) { state, fake, profile in
                await state.activate(profile: profile)
                try diagnosticRequire(!state.isActive && fake.transportAttempts == 3, "Expected rollback after three failures")
            },
            lifecycle("L07", "Output restoration failure", scenario: .init(restoreFails: true)) { state, _, profile in
                await state.activate(profile: profile)
                try diagnosticRequire(state.isActive, "Fixture failed to activate")
                await state.deactivate()
                try diagnosticRequire(state.errorMessage?.contains("could not switch back") == true, "Restoration failure was not reported")
            },
            lifecycle("L08", "Physical device disappearance") { state, fake, profile in
                await state.activate(profile: profile)
                try diagnosticRequire(state.isActive, "Fixture failed to activate")
                fake.scenario.outputPresent = false
                await state.monitorRouting()
                try diagnosticRequire(!state.isActive, "Removed output left runtime active")
            },
            test("L09", "Runtime Lifecycle", "Delayed old-session observation") { _ in
                let monitor = AudioRuntimeMonitor()
                let profileID = UUID()
                let a = AudioRuntimeSession(profileID: profileID)
                let b = AudioRuntimeSession(profileID: profileID)
                monitor.setPresentationActive(true, profileID: profileID)
                monitor.start(controller: nil, session: a, routeDiagnosticsProvider: { AudioRouteDiagnostics() })
                monitor.stop()
                monitor.start(controller: nil, session: b, routeDiagnosticsProvider: { AudioRouteDiagnostics() })
                let snapshot = PCMLevelSnapshot(peak: [0, 0], rms: [-3, -3], clippedSamples: 7, clippedSamplesByChannel: [4, 3])
                monitor.ingest(snapshot, session: a)
                try diagnosticRequire(monitor.activeSession == b && monitor.status.sourceClippedSamples == 0, "Old session changed replacement observations")
                monitor.ingest(snapshot, session: b)
                try diagnosticRequire(monitor.status.sourceClippedSamples == 7, "Current session was not accepted")
                monitor.stop()
                return .init(summary: "Delayed A observation rejected; B observation accepted for the same profile")
            }
        ]
    }

    private static func healthCases() -> [DiagnosticCase] {
        let now = Date(timeIntervalSince1970: 2_000)
        let healthyDSP = CamillaDSPDiagnostics(engineState: "Running", stopReason: "None",
            processingLoadPercent: 10, resamplerLoadPercent: 0, bufferLevelFrames: 256,
            rateAdjustment: 1, clippedSamples: 0, lastGraphUpdate: nil, patchedFilterCount: 0)
        return [
            test("H01", "Runtime Health", "Paused telemetry is independent of audio health") { _ in
                var status = AudioRuntimeStatus(isActive: true, engineIsRunning: true)
                status.route.sampleRate = 48_000
                status.route.activeChannels = 2
                try diagnosticRequire(status.pipelineAssessment(at: now) == .init(reasons: []), "Paused polling degraded the audio pipeline")
                try diagnosticRequire(status.telemetryAssessment(at: now) == .init(reasons: [.telemetryPaused]), "Paused polling was not identified")
                try diagnosticRequire(SystemDiagnostics.pipelineObservation(status, at: now).status == .passed, "S09 falsely warned about missing telemetry")
                try diagnosticRequire(SystemDiagnostics.telemetryObservation(status, at: now).status == .skipped, "S10 did not skip intentional polling suspension")
                return .init(summary: "Clean audio passes; intentionally paused telemetry is skipped separately")
            },
            test("H02", "Runtime Health", "Pending and failed diagnostic RPC") { _ in
                var status = AudioRuntimeStatus(isActive: true, telemetryPollingActive: true)
                try diagnosticRequire(status.telemetryAssessment(at: now).reasons == [.telemetryPending], "Initial polling was not pending")
                status.recordTelemetryFailure("Simulated RPC failure", at: now)
                try diagnosticRequire(status.telemetryAssessment(at: now).reasons == [.telemetryRPCFailed("Simulated RPC failure")], "RPC failure lost its cause")
                try diagnosticRequire(status.pipelineAssessment(at: now).health == .healthy, "RPC failure became an audio fault")
                try diagnosticRequire(SystemDiagnostics.telemetryObservation(status, at: now).summary.contains("Simulated RPC failure"), "RPC failure was absent from report")
                return .init(summary: "RPC failure explains the telemetry warning without degrading clean delivery")
            },
            test("H03", "Runtime Health", "All pipeline reasons and fault precedence") { _ in
                var status = AudioRuntimeStatus(isActive: true, engineIsRunning: false, transportError: "Simulated transport failure",
                    clippingIsRecent: true, telemetryPollingActive: true)
                var diagnostic = healthyDSP
                diagnostic.engineState = "Stalled"; diagnostic.stopReason = "Capture error"; diagnostic.processingLoadPercent = 90
                status.recordTelemetry(diagnostic, at: now)
                status.route.sourceFormatError = "Simulated format error"
                status.route.bridgeDroppedFrames = 1; status.route.bridgeConsumerOverrunCount = 2
                status.route.bridgeClientRegistryOverflowCount = 3; status.route.bridgeClientUseCountSaturationCount = 4
                status.route.bridgeMalformedPacketCount = 5; status.route.camillaDroppedFrames = 6
                status.route.camillaQueueRecoveries = 7; status.route.camillaWriteFailures = 8; status.route.rejectedSourceFrames = 9
                let expected: [AudioRuntimeHealthReason] = [.engineUnavailable, .transportFailure("Simulated transport failure"),
                    .sourceFormatError("Simulated format error"), .engineStalled, .engineStopped("Capture error"),
                    .processingOverload(90), .recentClipping, .bridgeDroppedFrames(1), .bridgeOverruns(2),
                    .clientRegistryOverflows(3), .clientUseCountSaturations(4), .malformedPackets(5),
                    .pcmDroppedFrames(6), .pcmQueueRecoveries(7), .pcmWriteFailures(8), .rejectedSourceFrames(9)]
                let assessment = status.pipelineAssessment(at: now)
                try diagnosticRequire(assessment.health == .fault && assessment.reasons == expected, "Pipeline reasons were dropped or fault severity was masked")
                let report = SystemDiagnostics.pipelineObservation(status, at: now)
                try diagnosticRequire(report.status == .failed && expected.allSatisfy { report.summary.contains($0.summary) }, "Report omitted a pipeline cause")
                try diagnosticRequire(status.telemetryAssessment(at: now).health == .healthy, "A reported DSP fault was confused with RPC availability")
                return .init(summary: "All observed causes retained; faults take precedence over warnings")
            },
            test("H04", "Runtime Health", "Stale DSP values do not become current audio faults") { _ in
                var status = AudioRuntimeStatus(isActive: true, telemetryPollingActive: true)
                var diagnostic = healthyDSP
                diagnostic.engineState = "Stalled"; diagnostic.stopReason = "Capture error"; diagnostic.processingLoadPercent = 95
                status.recordTelemetry(diagnostic, at: now)
                let later = now.addingTimeInterval(3)
                // Route refreshes must never refresh the DSP RPC timestamp.
                status.lastUpdated = later
                try diagnosticRequire(status.telemetryAssessment(at: later).reasons == [.telemetryStale], "Stale DSP observation appeared current")
                try diagnosticRequire(status.pipelineAssessment(at: later).health == .healthy, "Stale DSP state/load was treated as current")
                status.route.camillaWriteFailures = 1
                try diagnosticRequire(status.pipelineAssessment(at: later).reasons == [.pcmWriteFailures(1)], "Missing telemetry masked a PCM failure")
                return .init(summary: "DSP freshness uses its own timestamp; independent delivery faults remain visible")
            },
            test("H05", "Runtime Health", "Telemetry failure and recovery") { _ in
                var status = AudioRuntimeStatus(isActive: true, telemetryPollingActive: true)
                status.recordTelemetry(healthyDSP, at: now)
                status.recordTelemetryFailure("Simulated timeout", at: now.addingTimeInterval(1))
                try diagnosticRequire(status.hasFreshTelemetry(at: now.addingTimeInterval(1)), "Transient failure prematurely expired recent telemetry")
                status.recordTelemetryFailure("Simulated timeout", at: now.addingTimeInterval(3))
                try diagnosticRequire(!status.telemetryAvailable, "Expired telemetry remained available")
                try diagnosticRequire(status.telemetryAssessment(at: now.addingTimeInterval(3)).reasons == [.telemetryRPCFailed("Simulated timeout"), .telemetryStale], "Failure and stale evidence were not both retained")
                status.recordTelemetry(healthyDSP, at: now.addingTimeInterval(4))
                try diagnosticRequire(status.telemetryAssessment(at: now.addingTimeInterval(4)).health == .healthy && status.lastTelemetryError == nil, "Successful RPC did not clear telemetry failure")
                return .init(summary: "Transient error, expiration, and successful recovery are distinguished")
            },
            test("H06", "Runtime Health", "Monitor presentation does not own runtime activity") { _ in
                let monitor = AudioRuntimeMonitor()
                let session = AudioRuntimeSession(profileID: UUID())
                monitor.start(controller: nil, session: session, routeDiagnosticsProvider: { AudioRouteDiagnostics() })
                monitor.setPresentationActive(true, profileID: session.profileID)
                monitor.setPresentationActive(false, profileID: session.profileID)
                try diagnosticRequire(monitor.status.isActive && monitor.status.pipelineAssessment().health == .healthy, "Hiding the monitor marked the pipeline inactive or unhealthy")
                try diagnosticRequire(monitor.status.telemetryAssessment().reasons == [.telemetryPaused], "Hidden monitor did not report paused telemetry")
                monitor.stop()
                try diagnosticRequire(monitor.status.pipelineAssessment().reasons == [.runtimeInactive] && monitor.status.telemetryAssessment().reasons == [.runtimeInactive], "Stopped runtime retained active health")
                return .init(summary: "Presentation suspension preserves runtime activity; Stop clears both assessments")
            },
            test("H07", "Runtime Health", "Added delay excludes shared output latency and duplicate queues") { _ in
                let tick = PerformanceTick(rawValue: 1_000_000_000)
                var status = AudioRuntimeStatus(isActive: true, telemetryPollingActive: true)
                var diagnostic = healthyDSP
                diagnostic.sampleRate = 48_000; diagnostic.blockFrames = 480
                diagnostic.bufferLevelFrames = 960
                status.recordTelemetry(diagnostic, at: now)
                status.route.sampleRate = 48_000
                status.route.transit = .init(receivedAt: tick, completedAt: tick.advanced(seconds: 0.012))
                // Both queues are already reflected by the source-to-write timer.
                // Bridge storage can also contain overlapping audio from many apps.
                status.route.bridgeBufferedFrames = 96_000
                status.route.rateMatchBufferedFrames = 48_000
                let estimate = status.addedDelayEstimate(at: now, tick: tick.advanced(seconds: 0.02))
                try diagnosticRequire(estimate?.milliseconds == 42 && estimate?.appMilliseconds == 12,
                    "Delay double-counted queues or converted frames incorrectly")
                diagnostic.sampleRate = 96_000; status.route.sampleRate = 96_000
                status.recordTelemetry(diagnostic, at: now)
                try diagnosticRequire(status.addedDelayEstimate(at: now, tick: tick.advanced(seconds: 0.02))?.milliseconds == 27,
                    "Delay ignored the active sample rate")
                // A 3.4 ms transit, 128-frame DSP block and ~6.8 ms
                // playback queue must show ~12.9 ms, without the speakers' 33.5 ms.
                diagnostic.sampleRate = 48_000; diagnostic.blockFrames = 128
                diagnostic.bufferLevelFrames = 326; status.route.sampleRate = 48_000
                status.recordTelemetry(diagnostic, at: now)
                status.route.transit = .init(receivedAt: tick, completedAt: tick.advanced(seconds: 0.0034))
                let added = status.addedDelayEstimate(at: now, tick: tick.advanced(seconds: 0.02))
                try diagnosticRequire(abs((added?.milliseconds ?? 0) - 12.8583333333) < 0.001,
                    "Added delay must exclude the output latency shared with direct playback")
                return .init(summary: "Added transit and buffering exclude shared device delay and duplicate queues")
            },
            test("H08", "Runtime Health", "Delay hides missing, stale and invalid timing") { _ in
                let tick = PerformanceTick(rawValue: 1_000_000_000)
                var status = AudioRuntimeStatus(isActive: true, telemetryPollingActive: true)
                var diagnostic = healthyDSP
                diagnostic.sampleRate = 48_000; diagnostic.blockFrames = 480
                diagnostic.bufferLevelFrames = 0
                status.recordTelemetry(diagnostic, at: now)
                status.route.sampleRate = 48_000
                status.route.transit = .init(receivedAt: tick, completedAt: tick)
                func missing(_ changed: AudioRuntimeStatus) throws {
                    try diagnosticRequire(changed.addedDelayEstimate(at: now, tick: tick) == nil,
                        "Missing or invalid evidence produced a delay")
                }
                try diagnosticRequire(status.addedDelayEstimate(at: now, tick: tick)?.milliseconds == 10,
                    "Added delay should be available without any hardware-latency observation")
                var changed = status; changed.route.transit = nil; try missing(changed)
                changed = status; changed.dspSampleRate = 0; try missing(changed)
                changed = status; changed.dspSampleRate = .infinity; try missing(changed)
                changed = status; changed.route.sampleRate = 96_000; try missing(changed)
                changed = status; changed.dspBlockFrames = 0; try missing(changed)
                changed = status; changed.isActive = false; try missing(changed)
                changed = status; changed.telemetryPollingActive = false; try missing(changed)
                changed = status; changed.engineState = "Stalled"; try missing(changed)
                changed = status; changed.route.deliveryError = "Disconnected"; try missing(changed)
                changed = status; changed.lastTelemetryUpdatedAt = now.addingTimeInterval(-3); try missing(changed)
                try diagnosticRequire(status.addedDelayEstimate(at: now, tick: tick.advanced(seconds: 3)) == nil,
                    "An idle source retained an old delay")
                try diagnosticRequire(status.addedDelayEstimate(at: now, tick: .init(rawValue: 0)) == nil,
                    "A future observation produced a delay")
                return .init(summary: "Inactive, idle, stale, unavailable and invalid observations show no delay")
            },
            test("H09", "Runtime Health", "Live transit survives mixing and writing without detailed tracing") { box in
                let received = PerformanceClock.now()
                let source = ProducerCompletionRecord(generation: 1, sequence: 0, epoch: 1, kind: .pcm,
                    device: 100, client: 1, process: 0, cycle: 1, start: 0, frames: 256,
                    channels: 2, layout: .stereo, rate: 48_000, received: received,
                    samples: Array(repeating: 0.125, count: 512))
                let interval = ProducerCompletedInterval(device: 100, epoch: 1, start: 0, end: 256,
                    channels: 2, layout: .stereo, rate: 48_000, contributions: [source],
                    terminal: false, beginsEpoch: true)
                let frame = try box.perApp.ingestCompletedInterval(interval)
                try diagnosticRequire(frame.sourceReceivedAt == received && frame.performanceTrace == nil,
                    "Mixing lost the receipt timestamp or enabled detailed tracing")
                let url = box.directory.appendingPathComponent("delay.pcm")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                let router = PCMRouter()
                defer { router.stop(); try? handle.close() }
                await router.startFixture(camillaSink: handle)
                try await Task.sleep(for: .milliseconds(20))
                router.route(frame)
                let deadline = PerformanceClock.now().advanced(seconds: 2)
                while router.statistics.transit == nil && PerformanceClock.now() < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try diagnosticRequire((router.statistics.transit?.milliseconds ?? 0) >= 20,
                    "Writer failed to publish source-to-write time")
                await router.stopWithoutBlockingUI()
                await router.startFixture(camillaSink: handle)
                try diagnosticRequire(router.statistics.transit == nil,
                    "A replacement route inherited the old delay")
                return .init(summary: "Live receipt-to-write timing works independently of tracing and resets with the route")
            }
        ]
    }
}

extension DeveloperSelfTests {
    private static func traceIdentity(_ capture: AudioLatencyCapture, session: UUID, start: Int64 = 0,
                                      frames: Int = 512, epoch: UInt64 = 1) -> AudioTraceIdentity {
        .init(captureID: capture.id, runtimeSessionID: session, transportGeneration: 7, streamEpoch: epoch,
              deviceObjectID: 100, startSampleTime: start, frameCount: frames, sampleRate: 48_000, channelCount: 2)
    }
    private static func performanceCases() -> [DiagnosticCase] {
        [
            test("V01", "Performance Measurement", "Monotonic clock and percentile units") { _ in
                let a = PerformanceTick(rawValue: 1_000)
                try diagnosticRequire(PerformanceClock.milliseconds(a, a.advanced(seconds: 0.025)) == 25, "Incorrect monotonic conversion")
                try diagnosticRequire(PerformanceClock.duration(from: a, to: .init(rawValue: 0)) == 0, "Reversed ticks underflowed")
                let distribution = LatencyDistribution((1...100).map(Double.init) + [.nan, -.infinity, -1])
                try diagnosticRequire(distribution.sampleCount == 100 && distribution.medianMilliseconds == 50
                    && distribution.p95Milliseconds == 95 && distribution.p99Milliseconds == 99
                    && distribution.maximumMilliseconds == 100, "Percentile or invalid-value handling changed")
                let sizes = FrameSizeDistribution([1024, 256, 1024])
                try diagnosticRequire(sizes.minimumFrames == 256 && sizes.medianFrames == 1024, "Frame sizes lost their units")
                return .init(summary: "Monotonic durations, nearest-rank percentiles, and frame units verified")
            },
            test("V02", "Performance Measurement", "Bounded capture and warm-up exclusion") { _ in
                let start = PerformanceClock.now()
                let capture = AudioLatencyCapture(id: 1, start: start, deadline: start.advanced(seconds: 1), capacity: 2)
                let identity = traceIdentity(capture, session: UUID())
                let before = PerformanceTick(rawValue: start.rawValue - 1)
                capture.append(.packet(.init(identity: identity, received: before, processed: start)))
                for _ in 0..<5 { capture.append(.packet(.init(identity: identity, received: start, processed: start))) }
                try diagnosticRequire(capture.counts().packets == 2 && capture.telemetryDrops == 3, "Full storage changed the bounded/drop contract")
                capture.stop()
                capture.append(.packet(.init(identity: identity, received: start, processed: start)))
                try diagnosticRequire(capture.events().count == 2, "Stopped capture accepted a late observation")
                return .init(summary: "Warm-up excluded, full capture drops telemetry, stopped capture rejects late writes")
            },
            test("V03", "Performance Measurement", "Overlapping contributions and capture identity") { _ in
                let start = PerformanceClock.now()
                let capture = AudioLatencyCapture(id: 2, start: start, deadline: start.advanced(seconds: 60))
                let session = UUID()
                let identity = traceIdentity(capture, session: session, frames: 1024)
                var mix = MixPerformanceTrace(capture: capture, identity: identity, untracedUntil: 0, lastPolicyTick: start)
                for (offset, range) in [(0.0, 0..<1024), (0.002, 512..<1536), (0.004, 2048..<2304)] {
                    let receipt = start.advanced(seconds: offset)
                    let packet = PacketPerformanceContext(capture: capture, identity: identity, received: receipt)
                    mix.add(packet, processed: receipt.advanced(seconds: 0.001), start: Int64(range.lowerBound), end: Int64(range.upperBound), existingEnd: 0)
                }
                let first = mix.emit(start: 0, count: 256, eligible: start.advanced(seconds: 0.01), deadline: nil)
                let overlap = mix.emit(start: 256, count: 512, eligible: start.advanced(seconds: 0.01), deadline: nil)
                try diagnosticRequire(first?.contributingPackets == 1 && overlap?.contributingPackets == 2
                    && overlap?.lastPacketReceived == start.advanced(seconds: 0.002), "Unrelated or already emitted contribution joined the interval")
                let replacement = AudioLatencyCapture(id: 3, start: start, deadline: start.advanced(seconds: 60))
                let nextID = traceIdentity(replacement, session: UUID(), start: 2304, frames: 256)
                mix.add(.init(capture: replacement, identity: nextID, received: start), processed: start,
                        start: 2304, end: 2560, existingEnd: 2304)
                try diagnosticRequire(mix.emit(start: 768, count: 1536, eligible: start, deadline: nil) == nil, "Capture/session boundary joined old audio")
                let next = mix.emit(start: 2304, count: 256, eligible: start, deadline: nil)
                try diagnosticRequire(next?.identity == nextID, "Replacement capture failed to resume after old prefix")
                return .init(summary: "Partial prefixes, overlapping clients, unrelated tails, and capture/session replacement remain distinct")
            },
            test("V04", "Performance Measurement", "Timeline reset changes trace epoch") { box in
                let start = PerformanceClock.now()
                let capture = AudioLatencyCapture(id: 4, start: start, deadline: start.advanced(seconds: 60))
                let session = UUID()
                let identity = traceIdentity(capture, session: session, start: 10000, frames: 4)
                _ = box.perApp.ingest(packet(1, 10000), now: instant,
                    performance: .init(capture: capture, identity: identity, received: start))
                let old = try flush(box.perApp)
                _ = box.perApp.ingest(packet(), now: instant,
                    performance: .init(capture: capture, identity: traceIdentity(capture, session: session, frames: 4), received: start))
                let rewound = try flush(box.perApp)
                try diagnosticRequire(old.performanceTrace != nil && rewound.performanceTrace != nil
                    && old.performanceTrace?.identity.streamEpoch != rewound.performanceTrace?.identity.streamEpoch, "Timeline rewind retained its previous measurement epoch")
                box.perApp.resetRuntime()
                _ = box.perApp.ingest(packet(), now: instant,
                    performance: .init(capture: capture, identity: identity, received: start))
                let reset = try flush(box.perApp)
                try diagnosticRequire(reset.performanceTrace?.identity.streamEpoch != rewound.performanceTrace?.identity.streamEpoch, "Runtime reset retained its measurement epoch")
                capture.stop()
                for index in 1...3 {
                    let output = box.perApp.ingest(packet(1, Double(index * 4)), now: instant)
                    try diagnosticRequire(output?.performanceTrace == nil, "Stopped tracing remained attached to continuing audio")
                }
                return .init(summary: "Rewind and runtime reset prevent cross-stream latency joins")
            },
            test("V05", "Performance Measurement", "Queue observations preserve recovery policy") { _ in
                let start = PerformanceClock.now()
                let capture = AudioLatencyCapture(id: 5, start: start, deadline: start.advanced(seconds: 60), capacity: 1)
                let binding = PerformanceCaptureBinding(capture: capture, sessionID: UUID())
                var traced = LowLatencyPCMQueue(); var plain = LowLatencyPCMQueue()
                for count in [1024, 1024, 1024, 1024, 1024, 6000] {
                    let frame = PCMFrame(interleaved: Array(repeating: Float(0.1), count: count * 2), channelCount: 2, sampleRate: 48_000)
                    let off = plain.append(frame); let on = traced.append(frame, performance: binding)
                    try diagnosticRequire(off == on && plain.queuedFrames == traced.queuedFrames, "Tracing changed clear-on-overflow")
                    if count == 6000 {
                        try diagnosticRequire(traced.snapshot.capacityFrames == 6000 && traced.snapshot.lastRecoveryDroppedFrames == 1024, "Oversized-block capacity/recovery was reported incorrectly")
                    }
                }
                let rateChange = PCMFrame(interleaved: Array(repeating: Float(0.2), count: 1024), channelCount: 2, sampleRate: 96_000)
                try diagnosticRequire(traced.append(rateChange, performance: binding) == plain.append(rateChange), "Rate-change recovery changed")
                try diagnosticRequire(traced.snapshot.lastRecoverySampleRate == 48_000 && traced.snapshot.capacityFrames == 9600, "Recovery lost the dropped audio's sample rate")
                try samples(traced.removeFirst()!.interleaved, plain.removeFirst()!.interleaved)
                try diagnosticRequire(traced.snapshot.queuedFrames == 0 && traced.snapshot.latestBlockFrames == 512, "Dequeue snapshot is inaccurate")
                return .init(summary: "Tracing preserves overflow, rate-change clearing, oversized capacity, and delivered PCM")
            },
            test("V06", "Performance Measurement", "Production operation phases and hidden UI lifetime") { box in
                let fake = DiagnosticRuntimeFakes(.init(transportResults: [true, true]))
                let first = DiagnosticSandbox.profile(); var second = DiagnosticSandbox.profile(); second.name = "Second fixture"
                box.profiles.profiles = [first, second]
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: fake.services())
                let recorder = state.performanceRecorder
                recorder.start(options: .init(duration: 30, warmUp: 0), environment: { state.performanceEnvironment() })
                do {
                    state.setMainWindowPresentationActive(false)
                    await state.activate(profile: first)
                    state.setEQDraft("Preamp: -1 dB", for: first.id)
                    state.setEQDraft("Preamp: -2 dB", for: first.id)
                    await state.apply(profile: try state.applyingSessionEQDrafts(to: first))
                    var draft = ProfileSettingsDraft(profile: first, activation: box.profiles.activationMode(for: first))
                    draft.sectionLayout = ProfileSectionLayout(hidden: [.meters])
                    try await state.saveProfileSettings(draft)
                    await state.activate(profile: second)
                    await state.deactivate()
                    try diagnosticRequire(recorder.isCapturing, "Hiding UI or stopping runtime cancelled the capture")
                    await recorder.stop()
                    guard let baseline = recorder.baseline else { throw DiagnosticFailure(message: "Missing operation baseline") }
                    for kind in ["Activation", "Deactivation", "Profile switch", "Live EQ apply", "Profile Save"] {
                        try diagnosticRequire(baseline.operations.contains { $0.kind == kind && $0.result == "success" }, "Missing successful \(kind) measurement")
                    }
                    try diagnosticRequire(baseline.operations.contains { $0.result == "coalesced" }, "Coalesced draft was counted as applied")
                    try diagnosticRequire(baseline.interactions["UI draft acceptance"]?.sampleCount == 2
                        && baseline.interactions["Live EQ runtime acknowledgement"]?.sampleCount == 1, "UI acceptance and runtime acknowledgement were not separated")
                    try diagnosticRequire(baseline.operations.contains { $0.kind == "Deactivation" && $0.parentID != nil }, "Profile switch lost its teardown child")
                    if let path = ProcessInfo.processInfo.environment["CAMITUNE_PERFORMANCE_BASELINE_PATH"] {
                        try baseline.json().write(to: URL(fileURLWithPath: path + ".operations.json"), options: .atomic)
                    }
                    let decoded = try JSONDecoder.performance.decode(PerformanceBaseline.self, from: baseline.json())
                    try diagnosticRequire(decoded.operations.count == baseline.operations.count && decoded.environment.outputUID == "<redacted>", "JSON round-trip/redaction failed")
                    try fake.assertStopped(state)
                    return .init(summary: "Actual lifecycle, EQ, and Save phases exported; coalescing and hidden capture lifetime preserved")
                } catch {
                    await state.deactivate(); await recorder.stop(); throw error
                }
            },
            test("V07", "Performance Measurement", "Cadence includes recovered blocks and scenario mismatch") { box in
                let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
                let start = PerformanceClock.now()
                let capture = AudioLatencyCapture(id: 7, start: start, deadline: start.advanced(seconds: 10))
                let id = traceIdentity(capture, session: UUID())
                for index in 0..<3 {
                    capture.append(.queue(.init(identity: id, timestamp: start.advanced(seconds: Double(index) * 0.01), isEntry: true,
                        queuedFrames: (index + 1) * 512, capacityFrames: 4800)))
                }
                capture.append(.recovery(.init(captureID: capture.id, runtimeSessionID: id.runtimeSessionID,
                    timestamp: start.advanced(seconds: 0.03), queuedFramesBeforeRecovery: 1536, incomingFrames: 4096,
                    droppedFrames: 1536, sampleRate: 48_000, writerBlockInProgressFrames: 0)))
                var scenario = PerformanceScenario(label: "Mixed sizes"); scenario.requiresMixedPacketSizes = true
                let baseline = PerformanceAggregator.build(capture: capture, startedAt: Date(), end: start.advanced(seconds: 0.04),
                    options: .init(scenario: scenario), environment: state.performanceEnvironment(), observations: [], operations: [], drops: 0, stopReason: "Fixture")
                try diagnosticRequire(baseline.audio["Input block cadence"]?.sampleCount == 2
                    && baseline.audio["Input block cadence"]?.medianMilliseconds == 10, "Recovered entries disappeared from cadence")
                try diagnosticRequire(baseline.samples.isEmpty && baseline.emittedSizes[512] == 3
                    && baseline.droppedFramesDuringCapture == 1536, "Queue observations require completed writes")
                try diagnosticRequire(baseline.scenarioMismatches.contains("Mixed packet sizes were not observed"), "Mismatched scenario was accepted")
                return .init(summary: "Queue cadence includes recovered entries; scenario mismatches remain explicit")
            },
            test("V08", "Performance Measurement", "Tracing OFF/ON PCM and overhead baseline") { box in
                try await performanceBenchmark(box)
            },
            test("V09", "Performance Measurement", "Explicit rate target evidence is passive and signed") { _ in
                var observed = AdaptiveRateController(), control = AdaptiveRateController()
                for index in 0..<300 {
                    let frames = [128, 512, 1024][index % 3]
                    let buffered = index < 150 ? frames : frames * 4
                    let input = RateMatchObservation(bufferedFrames: buffered, targetFrames: 1024,
                        sampleRate: 48_000, elapsedFrames: frames, recoveryGeneration: 0)
                    let a = observed.update(input)
                    let measurement = observed.diagnosticObservation(input, targetSource: "configured")
                    let b = control.update(input)
                    try diagnosticRequire(a == b && measurement.adjustmentPPM == a
                        && measurement.targetFrames == 1024
                        && measurement.bufferedFrames == buffered, "Observation changed controller or target")
                    let decoded = try JSONDecoder().decode(RateMatchMeasurement.self, from: JSONEncoder().encode(measurement))
                    try diagnosticRequire(decoded.targetFrames == measurement.targetFrames
                        && decoded.bufferedFrames == measurement.bufferedFrames
                        && decoded.targetSource == measurement.targetSource
                        && abs(decoded.adjustmentPPM - measurement.adjustmentPPM) < 1e-9
                        && abs(decoded.filteredBufferedFrames - measurement.filteredBufferedFrames) < 1e-9
                        && abs(decoded.normalizedError - measurement.normalizedError) < 1e-9,
                        "Signed rate evidence failed round trip")
                }
                return .init(summary: "Explicit target and signed PPM captured without advancing controller state")
            }
        ]
    }

    private static func performanceBenchmark(_ box: DiagnosticSandbox) async throws -> DiagnosticObservation {
        let state = AppState(profiles: box.profiles, perAppAudio: box.perApp, runtimeServices: DiagnosticRuntimeFakes().services())
        let template = state.performanceEnvironment()
        struct Run {
            let bytes: Data
            let statistics: PCMRouter.Statistics
            let cpu: Double
            let duration: Double
            let baseline: PerformanceBaseline?
        }
        func run(tracing: Bool) async throws -> Run {
            box.perApp.resetRuntime()
            let router = PCMRouter(); let session = UUID()
            router.performanceSource.setSession(session)
            let recorder = RuntimePerformanceRecorder(source: router.performanceSource)
            let url = box.directory.appendingPathComponent(tracing ? "traced.pcm" : "plain.pcm")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let sink = try FileHandle(forWritingTo: url)
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? sink.close(); try? reader.close() }
            await router.startFixture(camillaSink: sink)
            var environment = template
            environment.sessionID = session; environment.sampleRate = 48_000; environment.channelCount = 2
            environment.playbackMode = PlaybackMode.direct.rawValue; environment.activeApplications = 1
            environment.outputName = "Synthetic file sink"; environment.outputUID = "fixture.file"
            if tracing {
                recorder.start(options: .init(duration: 30, warmUp: 0,
                    scenario: .init(label: "Synthetic isolated PCM; file sink; transport receipt simulated")), environment: {
                    var value = environment; let statistics = router.statistics
                    value.queue = statistics.camillaQueue; value.recoveries = statistics.camillaQueueRecoveries
                    value.droppedFrames = statistics.camillaDroppedFrames
                    value.processCPUSeconds = RuntimePerformanceRecorder.cpuSeconds()
                    return value
                })
            }
            let start = PerformanceClock.now(); let cpu = RuntimePerformanceRecorder.cpuSeconds()
            var outputBlocks = 0
            func routeAndWait(_ frame: PCMFrame) async throws {
                let before = try reader.seekToEnd()
                router.route(frame); outputBlocks += 1
                let limit = PerformanceClock.now().advanced(seconds: 2)
                while try reader.seekToEnd() == before {
                    try Task.checkCancellation()
                    guard PerformanceClock.now() < limit else { throw DiagnosticFailure(message: "Fixture writer made no progress") }
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            do {
                for index in 0..<48 {
                    let source = packet(1, Double(index * 512), 512, Float(index % 8 + 1) / 64)
                    let binding = router.performanceSource.snapshot()
                    let context = binding.map { PacketPerformanceContext(capture: $0.capture,
                        identity: traceIdentity($0.capture, session: session, start: Int64(index * 512)), received: PerformanceClock.now()) }
                    if let frame = box.perApp.ingest(source, performance: context) { try await routeAndWait(frame) }
                    try await Task.sleep(for: .milliseconds(11))
                }
                try await Task.sleep(for: .milliseconds(20))
                if case .flushed(let frame) = box.perApp.flushExpiredMix() { try await routeAndWait(frame) }
                if tracing, let capture = router.performanceSource.snapshot()?.capture {
                    let limit = PerformanceClock.now().advanced(seconds: 2)
                    while capture.counts().audio < outputBlocks && PerformanceClock.now() < limit {
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    try diagnosticRequire(capture.counts().audio == outputBlocks, "Writer failed to record a completed block")
                    await recorder.stop()
                }
                let duration = PerformanceClock.milliseconds(start, PerformanceClock.now()) / 1000
                let usedCPU = RuntimePerformanceRecorder.cpuSeconds() - cpu
                await router.stopWithoutBlockingUI()
                return Run(bytes: try Data(contentsOf: url), statistics: router.statistics, cpu: usedCPU,
                           duration: duration, baseline: recorder.baseline)
            } catch { await router.stopWithoutBlockingUI(); await recorder.stop(); throw error }
        }
        let off = try await run(tracing: false)
        let on = try await run(tracing: true)
        try diagnosticRequire(!off.bytes.isEmpty && off.bytes == on.bytes, "Tracing changed deterministic PCM output")
        try diagnosticRequire(off.statistics.camillaQueueRecoveries == 0 && on.statistics.camillaQueueRecoveries == 0
            && off.statistics.camillaDroppedFrames == 0 && on.statistics.camillaDroppedFrames == 0, "Isolated paced fixture recovered its queue")
        guard var baseline = on.baseline else { throw DiagnosticFailure(message: "Missing tracing baseline") }
        try diagnosticRequire(baseline.telemetryDrops == 0 && baseline.packets.count == 48
            && baseline.samples.allSatisfy { $0.packetReceived != nil && $0.identity.runtimeSessionID == baseline.environment.sessionID },
            "Trace coverage or session identity incomplete: \(baseline.telemetryDrops) drops, \(baseline.packets.count)/48 packets, \(baseline.samples.count) writes")
        try diagnosticRequire(!baseline.samples.isEmpty && baseline.samples.allSatisfy { $0.rateMatch != nil },
            "Writer rate evidence missing from detailed tracing")
        for name in ["Per-client processing", "Mixer policy wait", "Mixer emission work", "PCM queue residence",
                     "Rendering (including analysis/reset)", "Resampling/rate-match", "System master", "Payload preparation", "Pipe write", "Receipt → Camilla input"] {
            try diagnosticRequire(baseline.audio[name]?.sampleCount ?? 0 > 0, "Missing timing stage: \(name)")
        }
        baseline.overheadComparison = .init(workload: "48 × 512-frame packets at 48 kHz, 2 channels; file sink; simulated transport receipt; no hardware or CamillaDSP", identicalPCM: off.bytes == on.bytes,
            offRecoveries: off.statistics.camillaQueueRecoveries, onRecoveries: on.statistics.camillaQueueRecoveries,
            offQueuePeakFrames: off.statistics.camillaQueue.peakQueuedFrames, onQueuePeakFrames: on.statistics.camillaQueue.peakQueuedFrames,
            offDroppedFrames: off.statistics.camillaDroppedFrames, onDroppedFrames: on.statistics.camillaDroppedFrames,
            offCPUSeconds: off.cpu, onCPUSeconds: on.cpu, offDurationSeconds: off.duration, onDurationSeconds: on.duration,
            onWriterP99Milliseconds: baseline.audio["Writer execution"]?.p99Milliseconds ?? 0)
        let comparison = "Isolated identical PCM (\(on.bytes.count) bytes). OFF/ON: recoveries \(off.statistics.camillaQueueRecoveries)/\(on.statistics.camillaQueueRecoveries); queue peak \(off.statistics.camillaQueue.peakQueuedFrames)/\(on.statistics.camillaQueue.peakQueuedFrames) frames; CPU seconds \(off.cpu)/\(on.cpu); elapsed \(off.duration)/\(on.duration) s. ON writer p99 \(baseline.audio["Writer execution"]?.p99Milliseconds ?? 0) ms. OFF phase timing is intentionally unavailable. No bridge, CamillaDSP, or physical output was exercised."
        if let path = ProcessInfo.processInfo.environment["CAMITUNE_PERFORMANCE_BASELINE_PATH"] {
            try baseline.json().write(to: URL(fileURLWithPath: path), options: .atomic)
            try (baseline.report() + "\n\nTracing sanity check\n" + comparison).write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        }
        return .init(summary: "Tracing preserves PCM; all stages captured without queue recovery or telemetry loss",
                     evidence: [.init(name: "OFF/ON sanity check", value: comparison)])
    }
}

private extension JSONDecoder {
    static var performance: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}
