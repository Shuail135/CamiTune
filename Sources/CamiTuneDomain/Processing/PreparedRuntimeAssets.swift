import Foundation

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
