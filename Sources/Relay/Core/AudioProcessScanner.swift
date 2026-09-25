import Foundation
import CoreAudio
import AppKit

/// A process known to Core Audio that can be tapped as an audio source.
struct AudioProcess: Identifiable, Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
    /// True while the process is actively producing output audio.
    let isPlaying: Bool
    /// Live app icon for the UI (ignored in equality to avoid churn).
    let icon: NSImage?

    var id: AudioObjectID { objectID }

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.objectID == rhs.objectID
            && lhs.pid == rhs.pid
            && lhs.bundleID == rhs.bundleID
            && lhs.name == rhs.name
            && lhs.isPlaying == rhs.isPlaying
    }
}

enum AudioProcessScanner {
    /// Scans all Core Audio process objects. Never throws: a partial list is
    /// better than none, since the UI refreshes every few seconds anyway.
    static func scan() -> [AudioProcess] {
        let objectIDs: [AudioObjectID]
        do {
            objectIDs = try AudioObjectID.systemObject.readObjectIDArray(kAudioHardwarePropertyProcessObjectList)
        } catch {
            return []
        }

        let ownBundleID = Bundle.main.bundleIdentifier

        var processes: [AudioProcess] = []
        for objectID in objectIDs {
            guard let pid: pid_t = try? objectID.readProperty(
                kAudioProcessPropertyPID,
                defaultValue: pid_t(0)
            ), pid != 0 else { continue }

            let bundleID = (try? objectID.readString(kAudioProcessPropertyBundleID)) ?? nil
            if let bundleID, bundleID == ownBundleID { continue } // never show ourselves as a source

            let isPlaying = ((try? objectID.readUInt32(kAudioProcessPropertyIsRunningOutput)) ?? 0) != 0

            let runningApp = NSRunningApplication(processIdentifier: pid)
            let name = runningApp?.localizedName
                ?? bundleID.map { ($0 as NSString).lastPathComponent }
                ?? "Process \(pid)"

            processes.append(
                AudioProcess(
                    objectID: objectID,
                    pid: pid,
                    bundleID: bundleID,
                    name: name,
                    isPlaying: isPlaying,
                    icon: runningApp?.icon
                )
            )
        }

        return processes.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
