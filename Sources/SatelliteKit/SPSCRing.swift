import Foundation

/// A single-producer / single-consumer ring buffer of interleaved stereo
/// Float32 samples. The producer runs on the capture IO thread, the consumer
/// on an AVAudioEngine render thread. Critical sections are tiny (a couple of
/// memcpy calls), so an NSLock keeps this simple and safe for v1.
public final class SPSCRing {
    public let capacityFrames: Int
    private var storage: UnsafeMutablePointer<Float>
    private var writeIndex: Int64 = 0
    private var readIndex: Int64 = 0
    private let lock = NSLock()

    public init(capacityFrames: Int = 16384) { // ~340 ms @ 48 kHz
        self.capacityFrames = capacityFrames
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames * 2)
        self.storage.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit {
        storage.deallocate()
    }

    public var bufferedFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(writeIndex - readIndex)
    }

    /// Called on the capture IO thread. Returns the number of frames accepted.
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        let buffered = Int(writeIndex - readIndex)
        let free = capacityFrames - buffered
        let count = min(frameCount, free)
        guard count > 0 else { return 0 }

        let writeOffset = Int(writeIndex % Int64(capacityFrames))
        let firstChunk = min(count, capacityFrames - writeOffset)

        storage.advanced(by: writeOffset * 2)
            .update(from: source, count: firstChunk * 2)
        if count > firstChunk {
            storage.update(from: source.advanced(by: firstChunk * 2), count: (count - firstChunk) * 2)
        }

        writeIndex += Int64(count)
        return count
    }

    /// Called on a render thread. Returns the number of frames actually read.
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        let buffered = Int(writeIndex - readIndex)
        let count = min(frameCount, buffered)
        guard count > 0 else { return 0 }

        let readOffset = Int(readIndex % Int64(capacityFrames))
        let firstChunk = min(count, capacityFrames - readOffset)

        destination.update(from: storage.advanced(by: readOffset * 2), count: firstChunk * 2)
        if count > firstChunk {
            destination.advanced(by: firstChunk * 2)
                .update(from: storage, count: (count - firstChunk) * 2)
        }

        readIndex += Int64(count)
        return count
    }

    /// Re-anchors the read pointer at `targetLatencyFrames` behind the writer.
    public func resync(targetLatencyFrames: Int) {
        lock.lock()
        readIndex = max(0, writeIndex - Int64(targetLatencyFrames))
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        writeIndex = 0
        readIndex = 0
        lock.unlock()
    }
}

/// Bridge fan-out: one pump (the bridge, receiving packets from a paired
/// sender) produces into N independent consumers. The bridge drains incoming
/// packets into per-sink rings and advances positions in one lock; each sink
/// reads its own ring at its own pace. Not SPSC across the fan-out — it is a
/// fan-out of SPSC pairs with a tiny atomic-ish critical section per advance,
/// which is exactly what a software mixer wants from a network producer.
public final class BridgeFanOutRing {
    public let capacityFrames: Int
    private var storage: UnsafeMutablePointer<Float>
    private var writeIndex: Int64 = 0
    private var readIndex: Int64 = 0
    private let lock = NSLock()

    public init(capacityFrames: Int = 32768) {
        self.capacityFrames = capacityFrames
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames * 2)
        self.storage.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit {
        storage.deallocate()
    }

    public var bufferedFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(writeIndex - readIndex)
    }

    /// Bridge pump only: appends one packet of interleaved stereo.
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        let buffered = Int(writeIndex - readIndex)
        let free = capacityFrames - buffered
        let count = min(frameCount, free)
        guard count > 0 else { return 0 }

        let writeOffset = Int(writeIndex % Int64(capacityFrames))
        let firstChunk = min(count, capacityFrames - writeOffset)

        storage.advanced(by: writeOffset * 2)
            .update(from: source, count: firstChunk * 2)
        if count > firstChunk {
            storage.update(from: source.advanced(by: firstChunk * 2), count: (count - firstChunk) * 2)
        }

        writeIndex += Int64(count)
        return count
    }

    /// One sink only: advances this consumer's read pointer.
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        let buffered = Int(writeIndex - readIndex)
        let count = min(frameCount, buffered)
        guard count > 0 else { return 0 }

        let readOffset = Int(readIndex % Int64(capacityFrames))
        let firstChunk = min(count, capacityFrames - readOffset)

        destination.update(from: storage.advanced(by: readOffset * 2), count: firstChunk * 2)
        if count > firstChunk {
            destination.advanced(by: firstChunk * 2)
                .update(from: storage, count: (count - firstChunk) * 2)
        }

        readIndex += Int64(count)
        return count
    }

    public func reset() {
        lock.lock()
        writeIndex = 0
        readIndex = 0
        lock.unlock()
    }
}
