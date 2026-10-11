import CamiTuneDomain
import AVFoundation
import Foundation

struct MicrophoneInputLevel: Equatable, Sendable {
    var peakDBFS: Double
    var rmsDBFS: Double
    var clipped: Bool
}

/// The same bounded input validation is exercised by synthetic capture tests.
/// Level-check mode meters continuously without retaining an unbounded recording.
struct MicrophoneCaptureAccumulator {
    var retainsAudio = true
    private(set) var samples: [Float] = []
    private(set) var rate = 48_000.0
    private(set) var failed = false
    private(set) var level: MicrophoneInputLevel?
    private var previousEnd: Double?
    private var clippedSamples = 0
    init(retainsAudio: Bool = true) { self.retainsAudio = retainsAudio }
    mutating func invalidate() { failed = true }
    mutating func append(_ chunk: [Float], sampleRate: Double, timestamp: Double) {
        guard !chunk.isEmpty, chunk.allSatisfy(\.isFinite), timestamp.isFinite,
              sampleRate.isFinite, (8000...192000).contains(sampleRate),
              previousEnd == nil || sampleRate == rate,
              !retainsAudio || samples.count + chunk.count <= Int(sampleRate * 16) else { failed = true; return }
        if let previousEnd, abs(timestamp - previousEnd) > 2 / sampleRate { failed = true }
        previousEnd = timestamp + Double(chunk.count) / sampleRate
        rate = sampleRate
        let peak = chunk.reduce(0.0) { max($0, abs(Double($1))) }
        let power = chunk.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(chunk.count)
        if !retainsAudio { clippedSamples = 0 }
        clippedSamples += chunk.filter { abs($0) >= 0.999 }.count
        let peakDB: Double = 20.0 * log10(max(0.000001, peak))
        let rmsDB: Double = 10.0 * log10(max(0.000000000001, power))
        level = MicrophoneInputLevel(peakDBFS: max(-120.0, peakDB), rmsDBFS: max(-120.0, rmsDB), clipped: clippedSamples >= 3)
        if retainsAudio { samples.append(contentsOf: chunk) }
    }
}

/// Capture callbacks only copy bounded mono samples; analysis happens after stop.
final class SpatialMicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "CamiTune.microphone.session")
    private let callbackQueue = DispatchQueue(label: "CamiTune.microphone.samples")
    private let lock = NSLock()
    private var accumulator = MicrophoneCaptureAccumulator()

    var inputLevel: MicrophoneInputLevel? {
        lock.lock(); defer { lock.unlock() }; return accumulator.level
    }
    var hasDiscontinuity: Bool {
        lock.lock(); defer { lock.unlock() }; return accumulator.failed
    }

    private static var audioDevices: [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes, mediaType: .audio, position: .unspecified
        ).devices
    }

    static var microphones: [MeasurementMicrophone] {
        audioDevices.map {
            MeasurementMicrophone(id: $0.uniqueID, name: $0.localizedName,
                                  isBuiltIn: $0.deviceType == .builtInMicrophone)
        }
    }

    func start(id: String, retainAudio: Bool = true) async throws {
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else { throw AcousticMeasurementError.permissionDenied }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    self.lock.lock()
                    self.accumulator = MicrophoneCaptureAccumulator(retainsAudio: retainAudio)
                    self.lock.unlock()
                    guard let device = Self.audioDevices.first(where: { $0.uniqueID == id }) else {
                        throw AcousticMeasurementError.noMicrophone
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false]
                    output.setSampleBufferDelegate(self, queue: self.callbackQueue)
                    self.session.beginConfiguration()
                    guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                        self.session.commitConfiguration()
                        throw AcousticMeasurementError.captureFailed
                    }
                    self.session.addInput(input)
                    self.session.addOutput(output)
                    self.session.commitConfiguration()
                    self.session.startRunning()
                    guard self.session.isRunning else { throw AcousticMeasurementError.captureFailed }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() async -> AcousticRecording {
        await withCheckedContinuation { continuation in
            queue.async {
                self.session.stopRunning()
                self.callbackQueue.sync {}
                self.lock.lock()
                let recording = AcousticRecording(samples: self.accumulator.samples, sampleRate: self.accumulator.rate,
                    discontinuity: self.accumulator.failed)
                self.accumulator = MicrophoneCaptureAccumulator()
                self.lock.unlock()
                continuation.resume(returning: recording)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        defer { lock.unlock() }
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM,
              description.mChannelsPerFrame == 1, description.mBitsPerChannel == 32,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              let data = CMSampleBufferGetDataBuffer(buffer) else { accumulator.invalidate(); return }
        let count = CMSampleBufferGetNumSamples(buffer)
        guard description.mSampleRate == 48_000, count > 0, count <= 48_000 else { accumulator.invalidate(); return }
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
        var chunk = [Float](repeating: 0, count: count)
        let status = chunk.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { accumulator.invalidate(); return }
        accumulator.append(chunk, sampleRate: description.mSampleRate, timestamp: timestamp)
    }
}
