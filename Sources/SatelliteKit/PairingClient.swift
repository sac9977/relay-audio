import Foundation
import Network
import SatelliteKit

/// Client side of Relay's 4-digit code pairing: sends a pair request to a
/// host's bridge listener (UDP :51511), waits for PairOK carrying a stream
/// ID, then reports the paired endpoint. Callbacks arrive on `queue`.
public final class PairingClient {
    private let queue = DispatchQueue(label: "app.relay.pairing", qos: .userInitiated)

    public enum Outcome {
        case paired(host: String, streamID: UInt32)
        case rejected
        case timedOut
    }

    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var completed = false

    public init() {}

    public func pair(
        host: String,
        code: String,
        deviceName: String,
        timeout: TimeInterval = 6,
        completion: @escaping (Outcome) -> Void
    ) {
        completed = false
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: SatelliteProtocol.bridgePort)!,
            using: .udp
        )
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let request = SatelliteProtocol.encodePairRequest(code: code, deviceName: deviceName)
                conn.send(content: request, completion: .contentProcessed { _ in })
            case .failed:
                self?.complete(conn, outcome: .timedOut, completion: completion)
            default:
                break
            }
        }

        // Await the PairOK reply on the same socket.
        receiveLoop(on: conn) { [weak self] outcome in
            self?.complete(conn, outcome: outcome, completion: completion)
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + timeout)
        t.setEventHandler { [weak self] in
            self?.complete(conn, outcome: .timedOut, completion: completion)
        }
        t.resume()
        timer = t

        connection = conn
        conn.start(queue: queue)
    }

    private func receiveLoop(
        on conn: NWConnection,
        completion: @escaping (Outcome) -> Void
    ) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.connection === conn else { return }
            if let data, let streamID = SatelliteProtocol.decodePairOK(data) {
                let host = self.endpointHost(of: conn) ?? "unknown"
                self.complete(conn, outcome: .paired(host: host, streamID: streamID), completion: completion)
                return
            }
            if error == nil {
                self.receiveLoop(on: conn, completion: completion)
            } else {
                self.complete(conn, outcome: .timedOut, completion: completion)
            }
        }
    }

    private func endpointHost(of conn: NWConnection) -> String? {
        guard let path = conn.currentPath,
              case let .hostPort(host, _) = path.remoteEndpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)".split(separator: "%").first.map(String.init) ?? "\(a)"
        case .ipv6(let a): return "\(a)"
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }

    /// Single completion funnel: first outcome wins, socket is torn down,
    /// the armed timeout can never re-complete.
    private func complete(
        _ conn: NWConnection,
        outcome: Outcome,
        completion: @escaping (Outcome) -> Void
    ) {
        guard !completed, connection === conn else { return }
        completed = true
        timer?.cancel()
        timer = nil
        connection = nil
        conn.cancel()
        completion(outcome)
    }
}
