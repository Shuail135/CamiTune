import CamiTuneDomain
import Foundation
import SystemAudioBridgeC

extension ProfileRoutingDescriptor {
    func formatPayload() throws -> [String: Any] {
        let payload: [String: Any] = [
            "deviceUID": uid, "displayName": name,
            "profileFormatVersion": Int(SABR_PROFILE_FORMAT_VERSION),
            "channelCount": channelCount, "channelLayoutTag": channelLayoutTag,
            "supportedSampleRates": supportedSampleRates
        ]
        var format = SABRProfileFormat()
        guard !uid.isEmpty, uid.utf16.count <= 256, !name.isEmpty, name.utf16.count <= 128,
              sabr_profile_format_parse(payload as CFDictionary, &format) else {
            throw ProfileSettingsError.runtime("The profile's source channel layout or sample rate is unsupported.")
        }
        return payload
    }
}
