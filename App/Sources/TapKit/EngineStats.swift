import Foundation
import TapAtomics

/// Counters written by the IO thread (relaxed C11 atomics), read by anyone. Owned by the
/// controller and shared by successive engines, so readers never race an engine's teardown.
public final class EngineStats: @unchecked Sendable {
    public enum Counter: Int32 { case frames = 0, callbacks, overloads, discontinuities, missingInput, clippedSamples, nonzeroCallbacks, count }
    public enum Peak: Int32 { case input = 0, output, latencyFrames, count }

    let raw: OpaquePointer = rt_create(Counter.count.rawValue, Peak.count.rawValue)

    public init() {}
    deinit { rt_destroy(raw) }

    public func load(_ c: Counter) -> UInt64 { rt_load(raw, c.rawValue) }
    public func add(_ c: Counter, _ d: UInt64 = 1) { rt_add(raw, c.rawValue, d) }
    /// Read and reset a peak (linear).
    public func takePeak(_ p: Peak) -> Float { rt_ftake(raw, p.rawValue) }
    public func loadFloat(_ p: Peak) -> Float { rt_fload(raw, p.rawValue) }
}

/// Lock-free hand-over of the current EQ processor to the IO thread.
///
/// - `swap(_:)` is called on a non-real-time thread. It publishes the new box atomically, waits until
///   the IO thread is provably no longer using the old one, and returns the old one so that the caller
///   releases (frees) it off the audio thread.
/// - The IO thread only does `acquire` / `release` (two atomic stores and one load): no allocation,
///   no locks, no retain/release of the box.
public final class ProcessorSlot: @unchecked Sendable {
    let raw: OpaquePointer = rt_slot_create()

    public init() {}

    deinit {
        if let p = rt_slot_exchange(raw, nil) { Unmanaged<ProcessorBox>.fromOpaque(p).release() }
        rt_slot_destroy(raw)
    }

    /// Returns the previous box (or nil). Waits at most `timeout` for the IO thread to leave the old
    /// box; if that ever times out, the old box is deliberately leaked (never freed while possibly in use).
    @discardableResult
    public func swap(_ new: ProcessorBox?, timeout: TimeInterval = 2) -> ProcessorBox? {
        let newPtr = new.map { Unmanaged.passRetained($0).toOpaque() }
        guard let oldPtr = rt_slot_exchange(raw, newPtr) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while rt_slot_busy(raw) != 0 {
            if Date() > deadline { return nil }   // leak rather than risk use-after-free
            usleep(200)
        }
        return Unmanaged<ProcessorBox>.fromOpaque(oldPtr).takeRetainedValue()
    }

    public var current: ProcessorBox? {
        rt_slot_peek(raw).map { Unmanaged<ProcessorBox>.fromOpaque($0).takeUnretainedValue() }
    }
}

/// A processor plus the format it was built for.
public final class ProcessorBox: @unchecked Sendable {
    public let process: (_ bufs: UnsafePointer<UnsafeMutablePointer<Float>>, _ frames: Int) -> Void
    public let channels: Int
    public let sampleRate: Double
    public let appliedGainDB: Double
    public let object: AnyObject?

    public init(channels: Int, sampleRate: Double, appliedGainDB: Double, object: AnyObject?,
                process: @escaping (_ bufs: UnsafePointer<UnsafeMutablePointer<Float>>, _ frames: Int) -> Void) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.appliedGainDB = appliedGainDB
        self.object = object
        self.process = process
    }
}
