import Foundation

/// Exact selected coefficients and their graph identity. File acquisition lives
/// in the app; the numerical owner consumes these immutable preparation inputs.
package struct NativeFIRAsset: Sendable {
    package init(source: ProcessingGraph.Processor.Implementation.Convolution,
                 sampleRate: Int, coefficients: [Double]) {
        self.source = source
        self.sampleRate = sampleRate
        self.coefficients = coefficients
    }
    package var source: ProcessingGraph.Processor.Implementation.Convolution
    package var sampleRate: Int
    package var coefficients: [Double]
}

package struct PreparedRuntimeAssets: Hashable, Sendable {
    package init(impulseResponses: [UUID: Asset]) {
        self.impulseResponses = impulseResponses
    }

    package struct Asset: Hashable, Sendable {
        package init(metadata: ImpulseResponseAsset, url: URL, sha256: String) {
            self.metadata = metadata
            self.url = url
            self.sha256 = sha256
        }

        package let metadata: ImpulseResponseAsset
        package let url: URL
        package let sha256: String
    }
    package let impulseResponses: [UUID: Asset]
    package static let empty = Self(impulseResponses: [:])
}
