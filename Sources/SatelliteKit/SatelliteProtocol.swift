import Foundation

/// Wire protocol for Relay Satellite. Raw interleaved stereo Float32 PCM —
/// deliberately no codec: Wi-Fi bandwidth (~600 Mb/s) dwarfs even 96 kHz
/// stereo float, so the whole path stays bit-exact.
public enum SatelliteProtocol {
    public static let defaultPort: UInt16 = 51510
    public static let magic: UInt32 = 0x524C5231 // "RLR1"
    public static let version: UInt16 = 2

    /// Bonjour service type. Receivers advertise this; senders browse for it.
    public static let bonjourServiceType = "_relay-sat._udp"

    public static let samplesPerPacket = 1024          // frames per data packet
    public static let maxPacketsPerChunk = 16          // sender chunk pacing unit
    public static let pcmBytesPerFrame = 2 * 4         // stereo float32
    public static let samplesPerSecond = 48000.0       // fallback for v1 peers

    // Packet types.
    public static let typeData: UInt8 = 1
    public static let typeNack: UInt8 = 2
    public static let typeStats: UInt8 = 3
    public static let typePing: UInt8 = 4

    // MARK: Data packet (sender → receiver)
    // v2: [magic u32][version u16][type u8][flags u8][streamID u32][seq u64]
    //      [producerFrame u64][sampleRate u64][payloadLen u32][payload…]
    // v1 (version field == 1): sampleRate omitted; peers assumed 48 kHz.

    public static func encodeDataPacket(
        streamID: UInt32,
        sequence: UInt64,
        producerFrame: UInt64,
        payload: UnsafeRawBufferPointer,
        sampleRate: Double = samplesPerSecond
    ) -> Data {
        var packet = Data(capacity: headerSize + payload.count)
        var magic = Self.magic, version = Self.version, type = Self.typeData
        var flags: UInt8 = 0
        var streamID = streamID, sequence = sequence, producerFrame = producerFrame
        var sampleRateField = UInt64(sampleRate)
        var payloadLen = UInt32(payload.count)
        withUnsafeBytes(of: &magic) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &version) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &type) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &flags) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &streamID) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &sequence) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &producerFrame) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &sampleRateField) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &payloadLen) { packet.append(contentsOf: $0) }
        packet.append(contentsOf: payload)
        return packet
    }

    public static let headerSize = 4 + 2 + 1 + 1 + 4 + 8 + 8 + 8 + 4 // 40 (v2)
    public static let v1HeaderSize = 32                              // legacy peers

    public struct DataHeader {
        public let streamID: UInt32
        public let sequence: UInt64
        public let producerFrame: UInt64
        public let sampleRate: Double
        public let payloadRange: Range<Data.Index>
    }

    public static func decodeDataPacket(_ data: Data) -> DataHeader? {
        guard data.count > v1HeaderSize else { return nil }
        func readLE<T: FixedWidthInteger>(_ type: T.Type, _ offset: Int) -> T {
            data.subdata(in: offset..<offset + MemoryLayout<T>.size).withUnsafeBytes {
                $0.loadUnaligned(as: T.self)
            }
        }
        guard readLE(UInt32.self, 0) == magic,
              readLE(UInt8.self, 6) == typeData else { return nil }
        let wireVersion = readLE(UInt16.self, 4)

        if wireVersion == 1 {
            // Legacy peer: no sample rate field, assume 48 kHz.
            let payloadLen = Int(readLE(UInt32.self, 28))
            guard data.count == v1HeaderSize + payloadLen else { return nil }
            return DataHeader(
                streamID: readLE(UInt32.self, 8),
                sequence: readLE(UInt64.self, 12),
                producerFrame: readLE(UInt64.self, 20),
                sampleRate: samplesPerSecond,
                payloadRange: v1HeaderSize..<data.count
            )
        }
        guard wireVersion == version else { return nil }

        let payloadLen = Int(readLE(UInt32.self, 36))
        guard data.count == headerSize + payloadLen else { return nil }
        return DataHeader(
            streamID: readLE(UInt32.self, 8),
            sequence: readLE(UInt64.self, 12),
            producerFrame: readLE(UInt64.self, 20),
            sampleRate: Double(readLE(UInt64.self, 28)),
            payloadRange: headerSize..<data.count
        )
    }

    // MARK: NACK (receiver → sender)
    // [magic][version][type][flags][streamID u32][missingSeq u64][count u16]

    public static func encodeNack(streamID: UInt32, missingSequence: UInt64, count: UInt16) -> Data {
        var packet = Data()
        var magic = Self.magic, version = Self.version, type = Self.typeNack
        var flags: UInt8 = 0
        var streamID = streamID, missing = missingSequence, count = count
        withUnsafeBytes(of: &magic) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &version) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &type) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &flags) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &streamID) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &missing) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { packet.append(contentsOf: $0) }
        return packet
    }

    public static func decodeNack(_ data: Data) -> (streamID: UInt32, missingSequence: UInt64, count: UInt16)? {
        guard data.count == 4 + 2 + 1 + 1 + 4 + 8 + 2 else { return nil }
        func readLE<T: FixedWidthInteger>(_ type: T.Type, _ offset: Int) -> T {
            data.subdata(in: offset..<offset + MemoryLayout<T>.size).withUnsafeBytes {
                $0.loadUnaligned(as: T.self)
            }
        }
        guard readLE(UInt32.self, 0) == magic, readLE(UInt16.self, 4) == version,
              readLE(UInt8.self, 6) == typeNack else { return nil }
        return (readLE(UInt32.self, 8), readLE(UInt64.self, 12), readLE(UInt16.self, 20))
    }
}
