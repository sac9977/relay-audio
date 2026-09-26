import Foundation
import Network
import os.log
import SatelliteKit

/// One receiver found on the local network via Bonjour.
struct DiscoveredReceiver: Identifiable, Equatable {
    /// Stable identity across browse result updates.
    let id: String
    /// Human-readable name (the receiver Mac's name).
    let name: String
    /// Resolved IPv4/IPv6 address string to send audio to.
    let host: String
    /// 4-digit pairing code from the receiver's TXT record (nil if absent).
    let code: String?

    static func == (lhs: DiscoveredReceiver, rhs: DiscoveredReceiver) -> Bool { lhs.id == rhs.id }
}

/// Browses the local network for Relay Satellite receivers advertising
/// `_relay-sat._udp` and resolves each to an IP host string.
///
/// Non-isolated engine + snapshot pattern (mirrors SatelliteEngine): browse
/// and resolve callbacks arrive on arbitrary Network.framework queues, so all
/// state lives behind `NSLock`, and the MainActor polls `currentResults`.
final class ReceiverDiscovery {
    private let log = Logger(subsystem: "app.relay", category: "discovery")

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "app.relay.discovery", qos: .userInitiated)
    private let lock = NSLock()

    /// id → (name, resolved host or nil while still resolving, advertised code)
    private var known: [String: (name: String, host: String?, code: String?)] = [:]

    struct Snapshot {
        var receivers: [DiscoveredReceiver] = []
        var browsing = false
    }
    private var snapshot = Snapshot()

    var currentResults: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func start() {
        stop()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: SatelliteProtocol.bonjourServiceType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResults(results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let browsing: Bool
            switch state {
            case .ready: browsing = true
            case .failed, .cancelled: browsing = false
            default: return
            }
            self.lock.lock()
            self.snapshot.browsing = browsing
            self.lock.unlock()
        }
        browser.start(queue: queue)
        self.browser = browser
        log.info("Browsing for \(SatelliteProtocol.bonjourServiceType, privacy: .public) services")
    }

    func stop() {
        browser?.cancel()
        browser = nil
        lock.lock()
        known.removeAll()
        snapshot = Snapshot()
        lock.unlock()
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var seenIDs = Set<String>()
        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint else { continue }
            let id = "\(name).\(type).\(domain)"
            seenIDs.insert(id)
            let code: String?
            if case let .bonjour(txtRecord) = result.metadata {
                code = PairingCode.code(fromTXT: txtRecord)
            } else {
                code = nil
            }
            lock.lock()
            let isNew = known[id] == nil
            if isNew {
                known[id] = (name, nil, nil)
            }
            known[id]?.code = code
            lock.unlock()

            if isNew {
                resolve(result: result, id: id, name: name)
            }
        }

        // Drop services that disappeared.
        lock.lock()
        for gone in known.keys where !seenIDs.contains(gone) {
            known.removeValue(forKey: gone)
        }
        rebuildSnapshotLocked()
        lock.unlock()
    }

    /// Resolves a browse result to an IP address by connecting a throwaway
    /// UDP connection to the service endpoint and reading its "resolved"
    /// remote address. No packets are sent — UDP connect is local-only.
    private func resolve(result: NWBrowser.Result, id: String, name: String) {
        let connection = NWConnection(to: result.endpoint, using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let endpoint = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, _) = endpoint {
                    let hostString = Self.hostString(host)
                    self.lock.lock()
                    self.known[id]?.host = hostString
                    self.rebuildSnapshotLocked()
                    self.lock.unlock()
                    self.log.info("Resolved \(name, privacy: .public) → \(hostString, privacy: .public)")
                }
                connection.cancel()
            case .failed, .cancelled:
                // Unresolvable: drop it so a later browse re-attempts.
                self.lock.lock()
                self.known.removeValue(forKey: id)
                self.rebuildSnapshotLocked()
                self.lock.unlock()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            // IPv4 descriptions can carry an interface scope ("10.0.0.5%en0")
            // that plain host strings don't want. IPv6 zones stay — link-local
            // addresses need them.
            let raw = "\(address)"
            return raw.contains(".") ? String(raw.prefix { $0 != "%" }) : raw
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return "\(host)"
        }
    }

    /// Caller holds `lock`.
    private func rebuildSnapshotLocked() {
        var receivers: [DiscoveredReceiver] = []
        for (id, entry) in known {
            guard let host = entry.host else { continue }
            receivers.append(DiscoveredReceiver(id: id, name: entry.name, host: host, code: entry.code))
        }
        receivers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        snapshot.receivers = receivers
    }
}
