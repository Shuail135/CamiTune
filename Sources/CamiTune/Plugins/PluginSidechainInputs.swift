import AVFoundation
import CamiTuneAudio
import CamiTuneDomain
import Combine
import Foundation

struct PluginAudioInput: Identifiable, Hashable {
    let id: String
    let name: String
    let channels: Int
}

/// Owns input devices only while an active rack references them. Capture,
/// conversion and device changes never run on the main audio writer.
@MainActor
final class PluginSidechainInputs: ObservableObject {
    @Published private(set) var devices: [PluginAudioInput] = []
    @Published private(set) var errors: [String: String] = [:]
    private let hub: PluginSidechainHub
    private var wanted: Set<String> = []
    private var captures: [String: PluginInputCapture] = [:]
    private var revision: UInt64 = 0
    private var reconciliation: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []

    init(hub: PluginSidechainHub) {
        self.hub = hub
        for name in [NSNotification.Name.AVCaptureDeviceWasConnected, NSNotification.Name.AVCaptureDeviceWasDisconnected] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh(); self?.schedule() }
            })
        }
    }
    deinit { notifications.forEach(NotificationCenter.default.removeObserver) }
    func refresh() {
        devices = PluginInputCapture.devices.map { device in
            let description = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee
            return PluginAudioInput(id: device.uniqueID, name: device.localizedName,
                channels: min(32, max(1, Int(description?.mChannelsPerFrame ?? 2))))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func configure(_ sources: [PluginSidechainSource]) {
        let next = Set(sources.filter { $0.kind == .audioInput }.map(\.id))
        guard next != wanted else { return }
        wanted = next; schedule()
    }
    func retry() { schedule() }
    private func schedule() {
        revision &+= 1
        guard reconciliation == nil else { return }
        reconciliation = Task { [weak self] in
            guard let self else { return }
            while true {
                let current = revision
                let available = Set(PluginInputCapture.devices.map(\.uniqueID))
                for id in Array(captures.keys) where !wanted.contains(id) || !available.contains(id) || errors[id] != nil {
                    if let capture = captures.removeValue(forKey: id) { await capture.stop() }
                    hub.invalidate(kind: .audioInput, id: id)
                }
                for id in wanted.sorted() where captures[id] == nil {
                    guard available.contains(id) else { errors[id] = "This audio input is disconnected."; continue }
                    let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                    guard current == revision else { break }
                    guard allowed else { errors[id] = "Allow microphone access for CamiTune in System Settings to use audio inputs."; continue }
                    let capture = PluginInputCapture(id: id, hub: hub) { [weak self] message in
                        Task { @MainActor [weak self] in self?.errors[id] = message }
                    }
                    do {
                        try await capture.start()
                        if current == revision { captures[id] = capture; errors[id] = nil }
                        else { await capture.stop(); hub.invalidate(kind: .audioInput, id: id) }
                    } catch { await capture.stop(); errors[id] = error.localizedDescription }
                }
                errors = errors.filter { self.wanted.contains($0.key) }
                if current == revision { break }
            }
            reconciliation = nil
        }
    }
}

private final class PluginInputCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    static var devices: [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.microphone, .external] }
        else { types = [.builtInMicrophone, .externalUnknown] }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
    }
    let id: String
    private let hub: PluginSidechainHub
    private let report: @Sendable (String) -> Void
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "CamiTune.sidechain.input", qos: .userInitiated)
    private let callbackQueue = DispatchQueue(label: "CamiTune.sidechain.samples", qos: .userInitiated)
    private var notification: NSObjectProtocol?
    init(id: String, hub: PluginSidechainHub, report: @escaping @Sendable (String) -> Void) {
        self.id = id; self.hub = hub; self.report = report
        super.init()
        notification = NotificationCenter.default.addObserver(forName: NSNotification.Name.AVCaptureSessionRuntimeError,
            object: session, queue: nil) { [weak self] note in
                guard let self else { return }
                self.hub.invalidate(kind: .audioInput, id: self.id)
                self.report((note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "The audio input stopped.")
            }
    }
    deinit { if let notification { NotificationCenter.default.removeObserver(notification) } }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard let device = Self.devices.first(where: { $0.uniqueID == self.id }) else {
                        throw PluginHostError(message: "This audio input is disconnected.")
                    }
                    let description = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee
                    let channels = min(32, max(1, Int(description?.mChannelsPerFrame ?? 2)))
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false]
                    output.setSampleBufferDelegate(self, queue: self.callbackQueue)
                    self.session.beginConfiguration()
                    guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                        self.session.commitConfiguration()
                        throw PluginHostError(message: "CamiTune could not open this audio input.")
                    }
                    self.session.addInput(input); self.session.addOutput(output)
                    self.session.commitConfiguration()
                    self.session.startRunning()
                    guard self.session.isRunning else { throw PluginHostError(message: "This audio input could not start.") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.session.stopRunning()
                self.callbackQueue.sync {}
                continuation.resume()
            }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM, description.mBitsPerChannel == 32,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              description.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              (1...32).contains(description.mChannelsPerFrame),
              let data = CMSampleBufferGetDataBuffer(buffer) else { return }
        let frames = CMSampleBufferGetNumSamples(buffer), channels = Int(description.mChannelsPerFrame)
        guard frames > 0, frames <= 8192, description.mSampleRate.isFinite,
              (8000...384000).contains(description.mSampleRate) else { return }
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
        var samples = [Float](repeating: 0, count: frames * channels)
        let result = samples.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard result == kCMBlockBufferNoErr else { return }
        samples.withUnsafeBufferPointer {
            hub.offer(kind: .audioInput, id: id, samples: $0, channels: channels, rate: description.mSampleRate,
                sampleTime: timestamp * description.mSampleRate, stream: 0)
        }
    }
}
