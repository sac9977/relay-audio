import Foundation
import SatelliteKit

// Round-trip test for the Satellite wire protocol.
var samples = [Float]()
for i in 0..<(SatelliteProtocol.samplesPerPacket * 2) {
    samples.append(Float(i) * 0.25)
}

let streamID: UInt32 = 4242
let sequence: UInt64 = 987654321
let producerFrame: UInt64 = 55_000_000

let packet = samples.withUnsafeBufferPointer { buffer in
    SatelliteProtocol.encodeDataPacket(
        streamID: streamID,
        sequence: sequence,
        producerFrame: producerFrame,
        payload: UnsafeRawBufferPointer(buffer)
    )
}

guard let header = SatelliteProtocol.decodeDataPacket(packet) else {
    print("FAIL: decodeDataPacket returned nil")
    exit(1)
}
assert(header.streamID == streamID, "streamID mismatch")
assert(header.sequence == sequence, "sequence mismatch")
assert(header.producerFrame == producerFrame, "producerFrame mismatch")
assert(packet.count == SatelliteProtocol.headerSize + samples.count * 4, "size mismatch")

let decodedSamples: [Float] = packet.subdata(in: header.payloadRange).withUnsafeBytes {
    Array($0.bindMemory(to: Float.self))
}
for i in 0..<samples.count where decodedSamples[i] != samples[i] {
    print("FAIL: sample mismatch at \(i)")
    exit(1)
}

// NACK round trip.
let nack = SatelliteProtocol.encodeNack(streamID: 7, missingSequence: 12345, count: 8)
guard let decodedNack = SatelliteProtocol.decodeNack(nack) else {
    print("FAIL: decodeNack returned nil")
    exit(1)
}
assert(decodedNack.streamID == 7)
assert(decodedNack.missingSequence == 12345)
assert(decodedNack.count == 8)

print("PASS: data packet + NACK round-trip, \(packet.count) byte data packet, \(samples.count) samples bit-exact")
