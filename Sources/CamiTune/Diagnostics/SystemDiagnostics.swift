import Foundation

@MainActor
enum SystemDiagnostics {
    static func cases(state: AppState) -> [DiagnosticCase] {
        func check(_ id: String, _ suite: String, _ name: String,
                   _ run: @escaping @MainActor () async throws -> DiagnosticObservation) -> DiagnosticCase {
            DiagnosticCase(id: id, suite: suite, name: name, safety: .readOnly) {
                do { return try await run() }
                catch is CancellationError { throw CancellationError() }
                catch {
                    // Parser errors can contain preset text, profile names, or asset paths.
                    // Keep the report useful without exporting those private inputs.
                    return .init(status: .failed, summary: "\(name) failed. Review the selected profile or component settings.",
                                 evidence: [.init(name: "Error type", value: String(describing: type(of: error)))])
                }
            }
        }
        func component(_ status: DependencyManager.Status) -> DiagnosticObservation {
            switch status {
            case .checking: return .init(status: .skipped, summary: "Installation check has not completed. Open Drivers & Components.")
            case .missing: return .init(status: .failed, summary: "Not installed. Open Drivers & Components.")
            case .failed: return .init(status: .failed, summary: "Component needs attention. Open Drivers & Components.")
            case .installed(let version): return .init(summary: "Installed", evidence: [.init(name: "Version", value: version ?? "Unavailable")])
            case .working: return .init(summary: "Working")
            }
        }
        let profile = state.profiles.selectedProfile
        return [
            check("S01", "Components", "CamillaDSP installation") {
                var result = component(await state.dependencies.diagnosticCamillaDSPStatus())
                result.details = "Executable and UID capability marker checked read-only. Version uses the last component observation; no process was launched."
                return result
            },
            check("S02", "Components", "System Audio Bridge") {
                let present = await state.coreAudio.resolveSystemAudioBridgeWithoutBlockingUI() != nil
                let supported = await state.coreAudio.systemAudioBridgePresentationIsSupportedWithoutBlockingUI()
                var result = component(!present ? .missing : supported ? .working("Supported") : .failed("Unsupported"))
                if let layout = state.coreAudio.installedSystemAudioBridgeChannelLayout {
                    result.evidence.append(.init(name: "Bridge channels", value: "\(layout.channelCount)"))
                } else if present {
                    result.status = .failed
                    result.summary = "Driver channel layout unavailable. Open Drivers & Components."
                }
                result.details = "Driver presence, presentation/version compatibility, and channel layout were observed without reconfiguration."
                return result
            },
            check("S03", "Hardware", "Core Audio snapshot") {
                .init(status: state.coreAudio.hasCompletedInitialRefresh ? .passed : .skipped,
                      summary: state.coreAudio.hasCompletedInitialRefresh ? "Device snapshot available" : "Waiting for the initial device snapshot",
                      evidence: [.init(name: "Physical outputs", value: "\(state.coreAudio.physicalOutputDevices.count)"),
                                 .init(name: "Default output", value: state.coreAudio.defaultOutputUID.flatMap { state.coreAudio.cachedDevice(uid: $0)?.name } ?? "Unavailable")])
            },
            check("S04", "Hardware", "Configured physical output") {
                guard let profile else { return .init(status: .skipped, summary: "No profile selected") }
                guard state.coreAudio.hasCompletedInitialRefresh else { return .init(status: .skipped, summary: "Device snapshot unavailable") }
                let output = state.coreAudio.cachedDevice(uid: profile.outputDeviceUID)
                return .init(status: output != nil && output?.isRoutingDevice == false ? .passed : .failed,
                             summary: output == nil ? "Configured output is disconnected" : "Configured output is available",
                             evidence: [.init(name: "Device", value: output?.name ?? "Unavailable")])
            },
            check("S05", "Hardware", "Sample rate support") {
                guard let profile else { return .init(status: .skipped, summary: "No profile selected") }
                guard let bridge = await state.coreAudio.resolveSystemAudioBridgeWithoutBlockingUI(),
                      state.coreAudio.cachedDevice(uid: profile.outputDeviceUID) != nil else {
                    return .init(status: .skipped, summary: "Bridge or physical output unavailable")
                }
                let physical = await state.coreAudio.supportsSampleRateWithoutBlockingUI(uid: profile.outputDeviceUID, rate: Double(profile.sampleRate))
                let routing = await state.coreAudio.supportsSampleRateWithoutBlockingUI(uid: bridge.id, rate: Double(profile.sampleRate))
                return .init(status: physical && routing ? .passed : .failed,
                             summary: physical && routing ? "Both devices support the configured rate" : "Configured rate is unsupported",
                             evidence: [.init(name: "Sample rate", value: "\(profile.sampleRate) Hz")])
            },
            check("S06", "Profile", "Profile and processing graph") {
                guard let profile else { return .init(status: .skipped, summary: "No profile selected") }
                if state.profiles.persistenceError != nil {
                    return .init(status: .failed, summary: "Profile storage could not be read or saved; original storage is protected")
                }
                let plan = try await state.prepareRuntimePlan(profile: profile)
                return DiagnosticObservation(summary: "Profile, processing graph, and required assets validate",
                    evidence: [.init(name: "Processing stages", value: "\(plan.processingGraph.pipeline.count)"),
                               .init(name: "Plan revision", value: "\(plan.revision.generation)")])
            },
            check("S07", "Profile", "Runtime plan with hardware evidence") {
                guard let profile else { return .init(status: .skipped, summary: "No profile selected") }
                let plan = try await state.prepareRuntimePlan(profile: profile)
                return DiagnosticObservation(summary: "Runtime plan matches detected hardware",
                    evidence: [.init(name: "Source channels", value: "\(plan.sourceFormat.channelCount)"),
                               .init(name: "Hardware channels", value: "\(plan.hardwareOutputFormat.channelCount)")])
            },
            check("S08", "Runtime", "Runtime session and engine") {
                guard state.isActive else { return .init(status: .skipped, summary: "CamiTune is not processing audio") }
                return .init(status: state.activeSession != nil && state.dsp.isRunning ? .passed : .failed,
                             summary: state.dsp.isRunning ? "Engine is running" : "Engine is not running")
            },
            check("S09", "Runtime", "Audio delivery and PCM pipeline") {
                guard state.isActive else { return .init(status: .skipped, summary: "CamiTune is not processing audio") }
                var status = state.meters.status
                status.isActive = state.isActive
                status.engineIsRunning = state.dsp.isRunning
                status.transportError = state.driverTransport.runtimeError
                status.route = AudioRouteDiagnostics(transport: state.driverTransport.statistics, router: state.pcmRouter.statistics)
                return pipelineObservation(status)
            },
            check("S10", "Runtime", "DSP telemetry") {
                var status = state.meters.status
                status.isActive = state.isActive
                return telemetryObservation(status)
            }
        ]
    }

    static func pipelineObservation(_ status: AudioRuntimeStatus, at now: Date = Date()) -> DiagnosticObservation {
        let assessment = status.pipelineAssessment(at: now)
        let route = status.route
        return .init(status: diagnosticStatus(assessment.health),
            summary: assessment.reasons.isEmpty ? "No audio-pipeline issues observed" : assessment.explanation,
            evidence: [.init(name: "Sample rate", value: "\(route.sampleRate) Hz"),
                       .init(name: "Channels", value: "\(route.activeChannels)"),
                       .init(name: "Bridge dropped frames", value: "\(route.bridgeDroppedFrames)"),
                       .init(name: "Bridge consumer overruns", value: "\(route.bridgeConsumerOverrunCount)"),
                       .init(name: "Client registry overflows", value: "\(route.bridgeClientRegistryOverflowCount)"),
                       .init(name: "Client use-count saturations", value: "\(route.bridgeClientUseCountSaturationCount)"),
                       .init(name: "Malformed packets", value: "\(route.bridgeMalformedPacketCount)"),
                       .init(name: "Bridge packets observed", value: "\(route.bridgePacketCount)"),
                       .init(name: "Bridge packet frames latest / min / max", value: "\(route.bridgeLatestPacketFrames) / \(route.bridgeMinimumPacketFrames) / \(route.bridgeMaximumPacketFrames)"),
                       .init(name: "PCM dropped frames", value: "\(route.camillaDroppedFrames)"),
                       .init(name: "PCM write failures", value: "\(route.camillaWriteFailures)"),
                       .init(name: "Queue recoveries", value: "\(route.camillaQueueRecoveries)"),
                       .init(name: "Rejected source frames", value: "\(route.rejectedSourceFrames)"),
                       .init(name: "PCM queue current", value: "\(route.pcmQueue.queuedFrames) frames / \(route.pcmQueue.durationMilliseconds) ms @ \(route.pcmQueue.sampleRate) Hz"),
                       .init(name: "PCM queue peak", value: "\(route.pcmQueue.peakQueuedFrames) frames / \(route.pcmQueue.peakDurationMilliseconds) ms"),
                       .init(name: "PCM queue capacity", value: "\(route.pcmQueue.capacityFrames) frames / \(route.pcmQueue.capacityMilliseconds) ms"),
                       .init(name: "Latest writer block", value: "\(route.pcmQueue.latestBlockFrames) frames"),
                       .init(name: "Last recovery age", value: route.pcmQueue.lastRecoveryUptime.map {
                           String(format: "%.1f seconds ago", PerformanceClock.milliseconds(.init(rawValue: $0), PerformanceClock.now()) / 1000)
                       } ?? "None"),
                       .init(name: "Last recovery uptime (ns)", value: route.pcmQueue.lastRecoveryUptime.map(String.init) ?? "None"),
                       .init(name: "Last recovery queue / incoming / dropped", value: "\(route.pcmQueue.lastRecoveryQueuedFrames) / \(route.pcmQueue.lastRecoveryIncomingFrames) / \(route.pcmQueue.lastRecoveryDroppedFrames) frames @ \(route.pcmQueue.lastRecoverySampleRate) Hz")],
            details: "Delivery counters are cumulative for the current runtime. DSP state and load are assessed only while telemetry is fresh; RPC availability is reported separately.")
    }

    static func telemetryObservation(_ status: AudioRuntimeStatus, at now: Date = Date()) -> DiagnosticObservation {
        let assessment = status.telemetryAssessment(at: now)
        var evidence = [DiagnosticEvidence(name: "Polling", value: status.telemetryPollingActive ? "Active" : "Paused"),
                        .init(name: "Last successful diagnostic RPC", value: status.lastTelemetryUpdatedAt?.ISO8601Format() ?? "None")]
        if status.hasFreshTelemetry(at: now) {
            evidence += [.init(name: "DSP engine state", value: status.engineState),
                         .init(name: "DSP stop reason", value: status.stopReason),
                         .init(name: "DSP processing load", value: "\(status.processingLoadPercent)%")]
        }
        return .init(status: diagnosticStatus(assessment.health),
                     summary: assessment.reasons.isEmpty ? "DSP diagnostic RPC is current" : assessment.explanation,
                     evidence: evidence)
    }

    private static func diagnosticStatus(_ health: AudioRuntimeHealth) -> DiagnosticStatus {
        switch health {
        case .inactive: return .skipped
        case .healthy: return .passed
        case .warning: return .warning
        case .fault: return .failed
        }
    }

}
