import Foundation
import CoreAudio

extension AudioObjectID {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let unknownObject = AudioObjectID(kAudioObjectUnknown)

    var isValidObject: Bool { self != .unknownObject }

    /// Reads a fixed-size property value.
    func readProperty<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T,
        qualifier: UnsafeRawPointer? = nil,
        qualifierSize: UInt32 = 0
    ) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, qualifierSize, qualifier, &dataSize)
        guard status == noErr else {
            throw RelayError.coreAudio(status, "getting size of \(fourCC(selector))")
        }

        var value = defaultValue
        status = withUnsafeMutableBytes(of: &value) { rawBuffer in
            AudioObjectGetPropertyData(self, &address, qualifierSize, qualifier, &dataSize, rawBuffer.baseAddress!)
        }
        guard status == noErr else {
            throw RelayError.coreAudio(status, "reading \(fourCC(selector))")
        }
        return value
    }

    /// Reads a variable-length array of AudioObjectIDs (device list, process list, …).
    func readObjectIDArray(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw RelayError.coreAudio(status, "getting size of \(fourCC(selector))")
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: count)
        status = ids.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, UnsafeMutableRawPointer(buffer.baseAddress!))
        }
        guard status == noErr else {
            throw RelayError.coreAudio(status, "reading \(fourCC(selector))")
        }
        return ids
    }

    func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> String {
        let cfString: CFString = try readProperty(selector, scope: scope, defaultValue: "" as CFString)
        return cfString as String
    }

    func readUInt32(_ selector: AudioObjectPropertySelector) throws -> UInt32 {
        try readProperty(selector, defaultValue: UInt32(0))
    }

    func readBoolProperty(_ selector: AudioObjectPropertySelector) throws -> Bool {
        try readUInt32(selector) != 0
    }

    /// Current nominal sample rate in Hz (0 if unreadable).
    func nominalSampleRate() -> Double {
        (try? readProperty(kAudioDevicePropertyNominalSampleRate, defaultValue: Float64(0))) ?? 0
    }

    /// Sets the device's nominal sample rate. Returns false if the device
    /// refuses (some Bluetooth/transport devices reject rate changes while
    /// running, and not every rate is in the device's supported list).
    @discardableResult
    func setNominalSampleRate(_ rate: Double) -> Bool {
        var value = Float64(rate)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), buffer.baseAddress!)
        }
        return status == noErr
    }

    func readStreamCount(scope: AudioObjectPropertyScope) -> Int {
        guard let size = try? propertyDataSize(
            kAudioDevicePropertyStreams,
            scope: scope
        ) else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.stride
    }

    private func propertyDataSize(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw RelayError.coreAudio(status, "getting size of \(fourCC(selector))")
        }
        return dataSize
    }

    // MARK: Well-known lookups

    /// Translates a PID into the Core Audio "process object" that taps target.
    static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var pidValue = pid
        let objectID: AudioObjectID = try withUnsafeBytes(of: &pidValue) { pidBuffer in
            try AudioObjectID.systemObject.readProperty(
                kAudioHardwarePropertyTranslatePIDToProcessObject,
                defaultValue: AudioObjectID.unknownObject,
                qualifier: pidBuffer.baseAddress,
                qualifierSize: UInt32(MemoryLayout<pid_t>.size)
            )
        }
        guard objectID.isValidObject else {
            throw RelayError.message("No audio process found for PID \(pid)")
        }
        return objectID
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        try AudioObjectID.systemObject.readProperty(
            kAudioHardwarePropertyDefaultOutputDevice,
            defaultValue: AudioObjectID.unknownObject
        )
    }

    /// Resolves a device UID (e.g. from our saved preferences) to its object ID.
    /// The property takes an AudioValueTranslation (CFStringRef in,
    /// AudioDeviceID out) and does NOT support a GetPropertyDataSize probe.
    static func device(forUID uid: String) throws -> AudioObjectID {
        var uidRef: CFString = uid as CFString
        var objectID = AudioObjectID.unknownObject
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = withUnsafeMutableBytes(of: &uidRef) { inputBuffer in
            withUnsafeMutableBytes(of: &objectID) { outputBuffer in
                var translation = AudioValueTranslation(
                    mInputData: inputBuffer.baseAddress!,
                    mInputDataSize: UInt32(inputBuffer.count),
                    mOutputData: outputBuffer.baseAddress!,
                    mOutputDataSize: UInt32(outputBuffer.count)
                )
                var dataSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return withUnsafeMutableBytes(of: &translation) { translationBuffer in
                    AudioObjectGetPropertyData(
                        AudioObjectID.systemObject,
                        &address,
                        0,
                        nil,
                        &dataSize,
                        translationBuffer.baseAddress!
                    )
                }
            }
        }
        guard status == noErr else {
            throw RelayError.coreAudio(status, "resolving device UID \(uid)")
        }
        guard objectID.isValidObject else {
            throw RelayError.message("No audio device found for UID \(uid)")
        }
        return objectID
    }
}
