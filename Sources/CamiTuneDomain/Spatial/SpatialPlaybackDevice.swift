import Foundation

/// The plain-language Spatial choices map to the existing correction contracts.
/// This is an editing intent; the saved device correction remains authoritative.
package enum SpatialSoundSignature: String, CaseIterable, Sendable {
    case original, natural, balanced

    package var target: DeviceCorrectionTargetPreset? {
        switch self {
        case .original: return nil
        case .natural: return .diffuseFieldReference
        case .balanced: return .neutral
        }
    }

    package init?(device: SpatialPlaybackDevice) {
        guard let correction = device.correction, correction.isEnabled, device.strength > 0 else {
            self = .original
            return
        }
        switch correction.targetSelection.preset {
        case .diffuseFieldReference: self = .natural
        case .neutral: self = .balanced
        default: return nil
        }
    }
}

package enum HeadphoneEnclosure: String, Codable, Hashable, CaseIterable, Sendable {
    case unknown, openBack, closedBack, semiOpen

    package var title: String {
        switch self {
        case .unknown: return "Not sure"
        case .openBack: return "Open back"
        case .closedBack: return "Closed back"
        case .semiOpen: return "Semi-open"
        }
    }
}

/// Wearing type describes the playback transducer, not the measurement fixture
/// or the listener's HRTF. Nil form is an explicit unresolved identification.
package struct SpatialDeviceType: Codable, Hashable, Sendable {
    package var form: DeviceForm?
    package var enclosure: HeadphoneEnclosure

    package init(form: DeviceForm? = nil, enclosure: HeadphoneEnclosure = .unknown) {
        self.form = form
        self.enclosure = form?.hasEnclosure == true ? enclosure : .unknown
    }

    package var summary: String {
        guard let form else { return "Device type not identified" }
        return form.title + (form.hasEnclosure && enclosure != .unknown ? " · \(enclosure.title.lowercased())" : "")
    }

    package var needsDetails: Bool { form == nil || (form?.hasEnclosure == true && enclosure == .unknown) }

    package func validate() throws {
        guard form?.hasEnclosure == true || enclosure == .unknown else {
            throw PersonalSpatialError.invalidDeviceType
        }
    }

    package func supportsCorrection(from sources: [DeviceMeasurementReference]) -> Bool {
        guard let form else { return true }
        if form == .boneConduction || form == .other { return false }
        let forms = Set(sources.compactMap { DeviceForm(catalogValue: $0.form) })
        if form == .openEar { return forms == [.openEar] }
        return forms.isEmpty || forms == [form]
    }
}

package struct SpatialDeviceTypeEvidence: Codable, Hashable, Sendable {
    package var type: SpatialDeviceType
    package var model: String
    package var sourceName: String
    package var sourceURL: String
    package var revision: String
    package var reviewedAt: Date
    package var rights: String

    package init(type: SpatialDeviceType, model: String, sourceName: String, sourceURL: String,
                 revision: String, reviewedAt: Date, rights: String) {
        self.type = type; self.model = model; self.sourceName = sourceName; self.sourceURL = sourceURL
        self.revision = revision; self.reviewedAt = reviewedAt; self.rights = rights
    }
}

/// One physical-device description shared by both personal Spatial experiences.
/// User confirmation never rewrites the original measurement form or fixture.
package struct SpatialPlaybackDevice: Codable, Hashable, Sendable {
    /// Nil identifies generic playback with optional user-confirmed wearing type.
    package var id: String?
    package var name: String
    package var source: String
    package var correction: DeviceCorrectionProfile?
    package var strength: Float
    package var catalogForm: DeviceForm?
    package var verifiedType: SpatialDeviceTypeEvidence?
    package var typeOverride: SpatialDeviceType?

    package init(id: String? = nil, name: String, source: String, correction: DeviceCorrectionProfile? = nil,
                 strength: Float = 1, catalogForm: DeviceForm? = nil,
                 verifiedType: SpatialDeviceTypeEvidence? = nil, typeOverride: SpatialDeviceType? = nil) {
        self.id = id; self.name = name; self.source = source; self.correction = correction
        self.strength = strength; self.catalogForm = catalogForm
        self.verifiedType = verifiedType; self.typeOverride = typeOverride
    }

    package var measurementForms: Set<DeviceForm> {
        Set(correction?.sources.compactMap { DeviceForm(catalogValue: $0.form) } ?? [])
    }

    package var resolvedType: SpatialDeviceType {
        if let typeOverride { return typeOverride }
        if let verifiedType { return verifiedType.type }
        let forms = measurementForms
        return .init(form: catalogForm ?? (forms.count == 1 ? forms.first : nil))
    }

    package var typeProvenance: String {
        if typeOverride != nil { return "Your selection" }
        if let verifiedType { return verifiedType.sourceName + " · verified model specifications" }
        if resolvedType.form != nil { return source + " · measurement catalog" }
        return "Not identified"
    }

    package var correctionMatchesType: Bool {
        correction.map { resolvedType.supportsCorrection(from: $0.sources) } ?? true
    }

    package mutating func removeCorrection() {
        // Older saved models derive their wearing type from the measurement.
        // Keep that catalog fact when the user chooses the device's own sound.
        if catalogForm == nil, measurementForms.count == 1 { catalogForm = measurementForms.first }
        correction = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, source, correction, strength, catalogForm, verifiedType, typeOverride
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        source = try c.decode(String.self, forKey: .source)
        correction = try c.decodeIfPresent(DeviceCorrectionProfile.self, forKey: .correction)
        strength = try c.decodeIfPresent(Float.self, forKey: .strength) ?? 1
        catalogForm = try c.decodeIfPresent(DeviceForm.self, forKey: .catalogForm)
        verifiedType = try c.decodeIfPresent(SpatialDeviceTypeEvidence.self, forKey: .verifiedType)
        typeOverride = try c.decodeIfPresent(SpatialDeviceType.self, forKey: .typeOverride)
        try validate()
    }

    package func validate() throws {
        try typeOverride?.validate()
        try verifiedType?.type.validate()
        guard correctionMatchesType else { throw PersonalSpatialError.incompatibleDeviceType }
        guard strength.isFinite, (0...1).contains(strength), correction.map({
            $0.filters.count <= 20 && ReferenceCorrection.validFilters($0.filters, sampleRate: 44_100) &&
            $0.filters.allSatisfy { band in
                let q = band.q ?? band.bandwidth.map { BiquadCoefficients.q(fromBandwidth: $0) } ?? 0.70710678
                return band.kind.usesGain && (20...10_000).contains(band.frequency) &&
                    (-12...6).contains(band.gain ?? 0) && (0.3...6).contains(q)
            }
        }) ?? true else { throw PersonalSpatialError.invalidHeadphoneCorrection }
    }

    package var filters: [EQBand] {
        guard let correction, correction.isEnabled, strength > 0 else { return [] }
        return correction.filters.map { var band = $0; band.gain = (band.gain ?? 0) * Double(strength); return band }
    }
}
