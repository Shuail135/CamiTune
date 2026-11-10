import CamiTuneAudio
import CamiTuneDomain
import CoreAudio
import Foundation

/// Exclusive plug-in output retains its mapping, protection and configured
/// cadence. The shared transport owns only device delivery and teardown.
package final class DirectCoreAudioOutput: PCMOutputSink, @unchecked Sendable {
    private let transport: CoreAudioOutputTransport
    private var finalProcessor: FinalOutputProcessor
    package let requestedFrames: Int
    package var sampleRate: Double { transport.sampleRate }
    package var bufferFrames: Int { transport.bufferFrames }
    package var processingBlockFrames: Int? { requestedFrames }
    package var pacesContinuousRendering: Bool { true }

    package init(deviceID: AudioDeviceID, sampleRate: Double, inputChannels: Int,
                 outputChannels: Int, channelMap: [Int], requestedFrames: Int) throws {
        guard (32...8192).contains(requestedFrames),
              let processor = FinalOutputProcessor(inputChannels: inputChannels, outputChannels: outputChannels,
                channelMap: channelMap, sampleRate: sampleRate) else { throw Failure() }
        finalProcessor = processor
        self.requestedFrames = requestedFrames
        transport = try CoreAudioOutputTransport(deviceID: deviceID, sampleRate: sampleRate,
            outputChannels: outputChannels, bufferPolicy: .exclusive(requestedFrames: requestedFrames))
    }

    package func write(_ bytes: Data) throws {
        let mapped = try finalProcessor.process(bytes)
        try mapped.withUnsafeBufferPointer { try transport.write($0) }
    }
    package func waitForInstrumentCapacity(frames: Int) throws { try transport.waitForInstrumentCapacity(frames: frames) }
    package func cancel() { transport.cancel() }
    package func finish() { transport.finish() }
    package func stop() { transport.stop() }
    package func snapshot(readMeters: Bool = false) -> CoreAudioOutputTransport.Snapshot { transport.snapshot(readMeters: readMeters) }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "Unsupported direct output format or mapping." }
    }
}
