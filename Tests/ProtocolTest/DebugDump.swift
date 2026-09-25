import Foundation
import SatelliteKit

var samples: [Float] = [0.0, 0.25, 0.5, -1.5]
let packet = samples.withUnsafeBufferPointer { buffer in
    SatelliteProtocol.encodeDataPacket(
        streamID: 4242, sequence: 1, producerFrame: 100,
        payload: UnsafeRawBufferPointer(buffer)
    )
}

print("packet size:", packet.count, "(header", SatelliteProtocol.headerSize, "+ payload", samples.count * 4, ")")
print("header hex:", packet.prefix(SatelliteProtocol.headerSize).map { String(format: "%02x", $0) }.joined(separator: " "))
print("payload hex:", packet.dropFirst(SatelliteProtocol.headerSize).prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))
print("expected float bytes: 0x00000000 0x3e800000 0x3f000000 0xbfc00000")

if let header = SatelliteProtocol.decodeDataPacket(packet) {
    print("decoded: streamID", header.streamID, "seq", header.sequence, "producerFrame", header.producerFrame)
    let decoded = packet.subdata(in: header.payloadRange).withUnsafeBytes { $0.bindMemory(to: Float.self) }
    print("decoded floats:", Array(decoded))
    print("payloadRange:", header.payloadRange)
}
