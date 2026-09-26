import Foundation
import Network
import SatelliteKit

// E2E probe: act as a Relay sender toward an iOS/macOS Satellite receiver.
// Sends paced RLR1 v2 data packets (48 kHz stereo) with one deliberate gap,
// then listens for the receiver's NACK proving its pump/NACK path works.
// Exits 0 when the NACK for the gap arrives within the window.

let host = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "127.0.0.1"
let durationSeconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 5.0 : 5.0
let streamID: UInt32 = 0xC0FFEE
let samplesPerPacket = SatelliteProtocol.samplesPerPacket
let packetsPerSecond = Double(SatelliteProtocol.samplesPerSecond) / Double(samplesPerPacket)
let totalPackets = Int(packetsPerSecond * durationSeconds)
let gapSequence: UInt64 = UInt64(totalPackets / 2)

let queue = DispatchQueue(label: "e2e")
let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: SatelliteProtocol.defaultPort)!, using: .udp)
let lock = NSLock()
var sent = 0
var receivedNack = false
var nackForGap = false
var nacksSeen = 0

conn.stateUpdateHandler = { state in
    if case .failed(let error) = state {
        fputs("connection failed: \(error)\n", stderr)
        exit(2)
    }
}
conn.start(queue: queue)

func armReceive() {
    conn.receiveMessage { data, _, _, _ in
        if let data, let nack = SatelliteProtocol.decodeNack(data), nack.streamID == streamID {
            lock.lock()
            nacksSeen += 1
            receivedNack = true
            let coversGap = UInt64(gapSequence) >= nack.missingSequence &&
                            UInt64(gapSequence) < nack.missingSequence + UInt64(nack.count)
            if coversGap { nackForGap = true }
            lock.unlock()
        }
        armReceive() // keep listening for the whole window
    }
}
armReceive()

// Wait for the local socket to be ready, then stream in real time.
Thread.sleep(forTimeInterval: 0.5)

var sampleValue: Float = 0
for i in 0..<totalPackets {
    var samples = [Float](repeating: 0, count: samplesPerPacket * 2)
    for f in 0..<samplesPerPacket {
        sampleValue += 0.01
        samples[f * 2] = sin(Float(i) + Float(f) * 0.02)
        samples[f * 2 + 1] = samples[f * 2]
    }
    let seq = UInt64(i)
    if seq == gapSequence {
        // Deliberately skip this packet: the receiver must NACK it.
        Thread.sleep(forTimeInterval: 1.0 / packetsPerSecond)
        continue
    }
    let packet = samples.withUnsafeBufferPointer { buffer in
        SatelliteProtocol.encodeDataPacket(
            streamID: streamID,
            sequence: seq,
            producerFrame: UInt64(i) * UInt64(samplesPerPacket),
            payload: UnsafeRawBufferPointer(buffer),
            sampleRate: Double(SatelliteProtocol.samplesPerSecond)
        )
    }
    conn.send(content: packet, completion: .contentProcessed { _ in })
    lock.lock()
    sent += 1
    lock.unlock()
    Thread.sleep(forTimeInterval: 1.0 / packetsPerSecond)
}

// Grace window for the final NACK round trip.
Thread.sleep(forTimeInterval: 1.5)

lock.lock()
let sentFinal = sent
let nackSeen = receivedNack
let gapAcked = nackForGap
lock.unlock()
conn.cancel()

print("sent \(sentFinal) packets over \(durationSeconds)s; NACKs received: \(nackSeen ? "yes" : "none")\(nackSeen && gapAcked ? " (gap-acknowledging)" : "")")
if nackSeen && gapAcked {
    print("E2E PASS: receiver decoded the stream and NACKed the injected gap")
    exit(0)
} else if nackSeen {
    print("E2E PARTIAL: NACKs arrived but none covered the injected gap")
    exit(1)
} else {
    print("E2E FAIL: no NACK observed — receiver pump did not react to the gap")
    exit(1)
}
