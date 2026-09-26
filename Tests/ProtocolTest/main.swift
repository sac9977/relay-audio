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
        payload: UnsafeRawBufferPointer(buffer),
        sampleRate: 44100
    )
}

guard let header = SatelliteProtocol.decodeDataPacket(packet) else {
    print("FAIL: decodeDataPacket returned nil")
    exit(1)
}
assert(header.streamID == streamID, "streamID mismatch")
assert(header.sequence == sequence, "sequence mismatch")
assert(header.producerFrame == producerFrame, "producerFrame mismatch")
assert(abs(header.sampleRate - 44100) < 0.001, "sampleRate mismatch: \(header.sampleRate)")
assert(packet.count == SatelliteProtocol.headerSize + samples.count * 4, "size mismatch")

let decodedSamples: [Float] = packet.subdata(in: header.payloadRange).withUnsafeBytes {
    Array($0.bindMemory(to: Float.self))
}
for i in 0..<samples.count where decodedSamples[i] != samples[i] {
    print("FAIL: sample mismatch at \(i)")
    exit(1)
}

// Pairing packet round trips.
let pairReq = SatelliteProtocol.encodePairRequest(code: "4821", deviceName: "Sachin's iPhone")
guard let decodedPair = SatelliteProtocol.decodePairRequest(pairReq) else {
    print("FAIL: decodePairRequest returned nil")
    exit(1)
}
assert(decodedPair.code == "4821", "pair code mismatch: \(decodedPair.code)")
assert(decodedPair.deviceName == "Sachin's iPhone", "pair name mismatch")

let pairOK = SatelliteProtocol.encodePairOK(streamID: 987_654)
guard let decodedOK = SatelliteProtocol.decodePairOK(pairOK) else {
    print("FAIL: decodePairOK returned nil")
    exit(1)
}
assert(decodedOK == 987_654, "pairOK streamID mismatch")

// Adaptive jitter buffer + loss estimator behavior.
var adaptive = AdaptiveJitterBuffer(packetsPerSecond: 46.9) // 48k / 1024
assert(adaptive.depthPackets == 2, "base depth should start at 2 packets")

// A burst of 3 losses raises the depth.
var depth1 = adaptive.update(lostPackets: 3, receivedPackets: 40, nowSeconds: 1.0)
assert(depth1 == 3, "one loss cycle should raise depth by 1, got \(depth1)")
var depth2 = adaptive.update(lostPackets: 2, receivedPackets: 44, nowSeconds: 1.0)
assert(depth2 == 4, "second loss cycle should raise depth again, got \(depth2)")

// Clean audio decays depth back down (1 packet per 10 s).
for _ in 0..<15 {
    _ = adaptive.update(lostPackets: 0, receivedPackets: 47, nowSeconds: 1.0)
}
assert(adaptive.depthPackets >= 2 && adaptive.depthPackets <= 4,
       "depth should decay toward base after clean audio, got \(adaptive.depthPackets)")

var estimator = LossEstimator(window: 20)
for seq in UInt64(0)..<UInt64(10) { estimator.record(sequence: seq, receivedSequence: seq) }
assert(abs(estimator.lossRate) < 0.0001, "no loss expected on a clean run")
estimator.record(sequence: 13, receivedSequence: 9) // gap of 4
assert(abs(estimator.lossRate - 4.0 / 21.0) < 0.01, "gap of 4 should register, got \(estimator.lossRate)")
assert(estimator.currentBurstLength() == 4, "burst should equal the gap, got \(estimator.currentBurstLength())")

// NACK round trip.
let nack = SatelliteProtocol.encodeNack(streamID: 7, missingSequence: 12345, count: 8)
guard let decodedNack = SatelliteProtocol.decodeNack(nack) else {
    print("FAIL: decodeNack returned nil")
    exit(1)
}
assert(decodedNack.streamID == 7)
assert(decodedNack.missingSequence == 12345)
assert(decodedNack.count == 8)

// v1 legacy packet (no sampleRate field) still decodes at the 48 kHz default.
func encodeV1Packet(streamID: UInt32, sequence: UInt64, producerFrame: UInt64, payload: UnsafeRawBufferPointer) -> Data {
    var packet = Data()
    var magic = SatelliteProtocol.magic
    var version = UInt16(1)
    var type = SatelliteProtocol.typeData
    var flags = UInt8(0)
    var sid = streamID, seq = sequence, pf = producerFrame
    var len = UInt32(payload.count)
    withUnsafeBytes(of: &magic) { packet.append(contentsOf: $0) }
    withUnsafeBytes(of: &version) { packet.append(contentsOf: $0) }
    withUnsafeBytes(of: &type) { packet.append(contentsOf: $0) }
    withUnsafeBytes(of: &flags) { packet.append(contentsOf: $0) }
    withUnsafeBytes(of: &sid) { packet.append(contentsOf: $0) }
    withUnsafeBytes(of: &seq) { packet.append(contentsOf: $0) }
    withUnsafeBytes(of: &pf) { packet.append(contentsOf: $0) }
    withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
    packet.append(contentsOf: payload)
    return packet
}

let v1Packet = samples.withUnsafeBufferPointer { buffer in
    encodeV1Packet(streamID: streamID, sequence: sequence, producerFrame: producerFrame, payload: UnsafeRawBufferPointer(buffer))
}
guard let v1Header = SatelliteProtocol.decodeDataPacket(v1Packet) else {
    print("FAIL: v1 packet did not decode")
    exit(1)
}
assert(abs(v1Header.sampleRate - SatelliteProtocol.samplesPerSecond) < 0.001, "v1 should default to 48 kHz")
assert(v1Header.streamID == streamID && v1Header.sequence == sequence, "v1 fields mismatch")
let v1Samples: [Float] = v1Packet.subdata(in: v1Header.payloadRange).withUnsafeBytes {
    Array($0.bindMemory(to: Float.self))
}
for i in 0..<samples.count where v1Samples[i] != samples[i] {
    print("FAIL: v1 sample mismatch at \(i)")
    exit(1)
}

print("PASS: v2 data packet + v1 fallback + pair/NACK round-trips + NetQ (adaptive jitter/loss) — samples bit-exact")
