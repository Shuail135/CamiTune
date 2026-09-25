import CryptoKit
import Foundation

package struct GroupProcessing: Identifiable, Codable, Hashable, Sendable {
    package init(id: SpeakerGroupID, chain: ProcessingChain = ProcessingChain()) {
        self.id = id
        self.chain = chain
    }

    package var id: SpeakerGroupID
    package var chain: ProcessingChain = ProcessingChain()
}

extension SpeakerGroupID {
    package func stageID(_ component: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("CamiTune.group.\(rawValue).\(component)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
