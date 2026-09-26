import Foundation
import CoreAudio

func fourCC(_ value: UInt32) -> String {
    let bytes = [
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value),
    ]
    if bytes.allSatisfy({ (32...126).contains($0) }), let t = String(bytes: bytes, encoding: .ascii) {
        return "'\(t)'"
    }
    return String(value)
}

func readScalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, default defaultValue: T) -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return defaultValue }
    var value = defaultValue
    let status = withUnsafeMutableBytes(of: &value) { buffer in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!)
    }
    return status == noErr ? value : defaultValue
}

func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
    var cfString: CFString = "" as CFString
    let status = withUnsafeMutablePointer(to: &cfString) { pointer in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else { return nil }
    return (cfString as String).isEmpty ? nil : (cfString as String)
}

func readAvailableRates(_ id: AudioObjectID) -> [AudioValueRange] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioValueRange>.stride
    var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: count)
    let status = ranges.withUnsafeMutableBufferPointer { buffer in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!)
    }
    return status == noErr ? ranges : []
}

func deviceStreamCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
    return Int(size) / MemoryLayout<AudioStreamID>.stride
}

struct ProbeError: Error { let message: String }
func resolveUID(_ uid: String) -> Result<AudioObjectID, ProbeError> {
    // Documented contract: the property data is an AudioValueTranslation with
    // the CFStringRef UID on the way in and an AudioDeviceID on the way out.
    var uidRef: CFString = uid as CFString
    var outDevice = AudioObjectID(kAudioObjectUnknown)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDeviceForUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    let status = withUnsafeMutableBytes(of: &uidRef) { inputBuffer in
        withUnsafeMutableBytes(of: &outDevice) { outputBuffer in
            var translation = AudioValueTranslation(
                mInputData: inputBuffer.baseAddress!,
                mInputDataSize: UInt32(inputBuffer.count),
                mOutputData: outputBuffer.baseAddress!,
                mOutputDataSize: UInt32(outputBuffer.count)
            )
            var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
            return withUnsafeMutableBytes(of: &translation) { translationBuffer in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, translationBuffer.baseAddress!)
            }
        }
    }
    if status != noErr { return .failure(ProbeError(message: "status \(status) (\(fourCC(UInt32(bitPattern: status))))")) }
    if outDevice == AudioObjectID(kAudioObjectUnknown) { return .failure(ProbeError(message: "device not found")) }
    return .success(outDevice)
}

// MARK: Scan devices

var systemAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var listSize: UInt32 = 0
guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &systemAddress, 0, nil, &listSize) == noErr else {
    print("FAILED to read device list size")
    exit(1)
}
let count = Int(listSize) / MemoryLayout<AudioObjectID>.stride
var deviceIDs = [AudioObjectID](repeating: 0, count: count)
_ = deviceIDs.withUnsafeMutableBufferPointer { buffer in
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &systemAddress, 0, nil, &listSize, UnsafeMutableRawPointer(buffer.baseAddress!))
}

print("Found \(count) audio devices; checking which have output streams:")
print()

for deviceID in deviceIDs {
    let outputStreams = deviceStreamCount(deviceID, scope: kAudioObjectPropertyScopeOutput)
    guard outputStreams > 0 else { continue }
    let name = readString(deviceID, kAudioObjectPropertyName) ?? "?"
    let uid = readString(deviceID, kAudioDevicePropertyDeviceUID) ?? "?"
    let transport: UInt32 = readScalar(deviceID, kAudioDevicePropertyTransportType, default: 0)

    print("• \(name)")
    print("  uid: \(uid)")
    print("  transport: \(fourCC(transport)), output streams: \(outputStreams)")

    let nominal: Float64 = readScalar(deviceID, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
    print("  nominal sample rate: \(Int(nominal)) Hz")
    let rates = readAvailableRates(deviceID).map { range -> String in
        range.mMinimum == range.mMaximum ? "\(Int(range.mMinimum))" : "\(Int(range.mMinimum))–\(Int(range.mMaximum))"
    }.sorted { Int($0) ?? 0 < Int($1) ?? 0 }
    if !rates.isEmpty {
        print("  available rates: \(rates.joined(separator: ", "))")
    }

    switch resolveUID(uid) {
    case let .success(resolved):
        print("  resolve-by-UID: OK → AudioObjectID \(resolved)")
    case let .failure(error):
        print("  resolve-by-UID: FAILED → \(error)")
    }
    print()
}
