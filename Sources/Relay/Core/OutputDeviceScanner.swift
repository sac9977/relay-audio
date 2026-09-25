import Foundation
import CoreAudio

/// An output device on the system that Relay can fan audio out to.
struct AudioOutputDevice: Identifiable, Hashable {
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let transportLabel: String

    var id: String { uid }
}

enum OutputDeviceScanner {
    /// Devices created by Relay itself use this UID prefix and are filtered out.
    static let ownAggregateUIDPrefix = "relay-agg-"

    static func scan() -> [AudioOutputDevice] {
        let deviceIDs: [AudioObjectID]
        do {
            deviceIDs = try AudioObjectID.systemObject.readObjectIDArray(kAudioHardwarePropertyDevices)
        } catch {
            return []
        }

        var devices: [AudioOutputDevice] = []
        for deviceID in deviceIDs {
            guard deviceID.readStreamCount(scope: kAudioObjectPropertyScopeOutput) > 0 else { continue }
            guard let uid = try? deviceID.readString(kAudioDevicePropertyDeviceUID), !uid.isEmpty else { continue }
            if uid.hasPrefix(ownAggregateUIDPrefix) { continue }

            let name = (try? deviceID.readString(kAudioObjectPropertyName)) ?? "Unknown device"
            let transportType = (try? deviceID.readUInt32(kAudioDevicePropertyTransportType)) ?? 0
            devices.append(
                AudioOutputDevice(objectID: deviceID, uid: uid, name: name, transportLabel: transportLabel(for: transportType))
            )
        }

        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static let transportLabels: [UInt32: String] = [
        kAudioDeviceTransportTypeBuiltIn: "Built-in",
        kAudioDeviceTransportTypeBluetooth: "Bluetooth",
        kAudioDeviceTransportTypeBluetoothLE: "Bluetooth",
        kAudioDeviceTransportTypeAirPlay: "AirPlay",
        kAudioDeviceTransportTypeUSB: "USB",
        kAudioDeviceTransportTypeDisplayPort: "DisplayPort",
        kAudioDeviceTransportTypeThunderbolt: "Thunderbolt",
        kAudioDeviceTransportTypeFireWire: "FireWire",
        kAudioDeviceTransportTypeVirtual: "Virtual",
        kAudioDeviceTransportTypeAggregate: "Aggregate",
    ]

    private static func transportLabel(for rawType: UInt32) -> String {
        transportLabels[rawType] ?? "Other"
    }
}
