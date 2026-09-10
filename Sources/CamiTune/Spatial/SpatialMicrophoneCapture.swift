import AVFoundation
import Foundation

/// Capture callbacks only copy bounded mono samples; analysis happens after stop.
final class SpatialMicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "CamiTune.microphone.session")
    private let callbackQueue = DispatchQueue(label: "CamiTune.microphone.samples")
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate = 48_000.0
    private var failed = false
    private var previousEnd: Double?

    static var microphones: [MeasurementMicrophone] {
        AVCaptureDevice.devices(for: .audio).map {
            MeasurementMicrophone(id: $0.uniqueID, name: $0.localizedName,
                                  isBuiltIn: $0.deviceType == .builtInMicrophone)
        }
    }

    func start(id: String) async throws {
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else { throw AcousticMeasurementError.permissionDenied }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard let device = AVCaptureDevice.devices(for: .audio).first(where: { $0.uniqueID == id }) else {
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
                let recording = AcousticRecording(samples: self.samples, sampleRate: self.rate, discontinuity: self.failed)
                self.samples.removeAll()
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
              let data = CMSampleBufferGetDataBuffer(buffer) else { failed = true; return }
        let count = CMSampleBufferGetNumSamples(buffer)
        guard description.mSampleRate == 48_000, count > 0,
              samples.count + count <= 48_000 * 16 else { failed = true; return }
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
        if let previousEnd, abs(timestamp - previousEnd) > 0.025 { failed = true }
        previousEnd = timestamp + Double(count) / description.mSampleRate
        var chunk = [Float](repeating: 0, count: count)
        let status = chunk.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { failed = true; return }
        rate = description.mSampleRate
        samples.append(contentsOf: chunk)
    }
}
