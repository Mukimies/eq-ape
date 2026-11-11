import CoreAudio
import EQCore
import Foundation
import TapAtomics

public extension ProcessorBox {
    /// Wrap an EQCore processor (built off the audio thread) for the slot.
    convenience init(eq: EQProcessor, channels: Int, sampleRate: Double) {
        self.init(channels: channels, sampleRate: sampleRate, appliedGainDB: eq.appliedHeadroomGainDB, object: eq) { bufs, n in
            eq.process(bufs, frames: n)
        }
    }
}

/// Adapted from poc-tap's TapEngine.
///
/// Process tap of one output device (all processes except ours, muted only while it is being read)
/// -> private aggregate (real device = clock + output, tap = only input; the device's own input
/// streams are excluded with `channels-in = 0`) -> one IOProc that captures, runs the slot's processor
/// and plays back in the same IO cycle on the device's own clock.
///
/// Not thread safe: create, prepare, start and stop it from one (non-real-time) queue.
public final class TapEngine {
    public struct Options {
        public var deviceUID: String
        public var privateObjects = true
        public var excludeDeviceInputs = true          // "channels-in": 0 on the sub-device (ignored by the HAL, see prepare)
        public var muteBehavior: CATapMuteBehavior = .mutedWhenTapped
        public var name = "EQ Ape"
        public init(deviceUID: String) { self.deviceUID = deviceUID }
    }

    public enum StartResult: Equatable { case started, failed(OSStatus), timedOut }

    public let opts: Options
    public let device: AudioObjectID
    public let stats: EngineStats
    public let slot: ProcessorSlot
    public private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var aggID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var tapFormat = AudioStreamBasicDescription()
    public private(set) var sampleRate: Double = 48000
    public private(set) var tapChannels = 2
    public private(set) var aggregateInputStreams = 0
    public private(set) var aggregateOutputStreams = 0
    public private(set) var isRunning = false
    public var log: (String) -> Void = { _ in }

    private var procID: AudioDeviceIOProcID?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    public static let maxFrames = 8192
    private var scratch: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    private var scratchCount = 0
    private let nextInputSampleTime = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    /// Called (on `eventQueue`) when the aggregate reports something that needs a rebuild.
    public var onTrouble: ((String) -> Void)?
    public var eventQueue: DispatchQueue = .main

    public init(device: AudioObjectID, options: Options, stats: EngineStats, slot: ProcessorSlot) {
        self.device = device
        self.opts = options
        self.stats = stats
        self.slot = slot
        nextInputSampleTime.pointee = -1
    }

    deinit {
        stop()
        if let s = scratch {
            for c in 0..<scratchCount { s[c].deallocate() }
            s.deallocate()
        }
        nextInputSampleTime.deallocate()
    }

    /// Creates tap, aggregate and IOProc. No IO yet: this part needs no TCC permission.
    public func prepare() throws {
        // 1. Our own HAL process object, so the tap excludes our playback (no feedback).
        let me = (try? HAL.processObject(forPID: getpid())) ?? AudioObjectID(kAudioObjectUnknown)

        // 2. CATapDescription.h initExcludingProcesses:andDeviceUID:withStream:
        let desc = CATapDescription(excludingProcesses: me == kAudioObjectUnknown ? [] : [me],
                                    deviceUID: opts.deviceUID, stream: 0)
        desc.name = opts.name
        desc.uuid = UUID()
        desc.muteBehavior = opts.muteBehavior
        desc.isPrivate = opts.privateObjects
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap
        let tapUID = try HAL.getString(tapID, addr(kAudioTapPropertyUID))
        tapFormat = try HAL.get(tapID, addr(kAudioTapPropertyFormat), AudioStreamBasicDescription())
        tapChannels = max(1, Int(tapFormat.mChannelsPerFrame))
        sampleRate = tapFormat.mSampleRate > 0 ? tapFormat.mSampleRate : HAL.sampleRate(device)
        log("tap \(tapID) (self process object \(me)): \(describe(tapFormat))")

        allocateScratch(tapChannels)

        // 3. Private aggregate (AudioHardware.h keys). We ask for the device's own inputs to be left out
        //    with kAudioSubDeviceInputChannelsKey = 0, but measured (EQApe --probe) the HAL ignores that key
        //    for a live device: the aggregate still has the device's input streams. They are switched off
        //    for our IOProc with kAudioDevicePropertyIOProcStreamUsage (NULL buffers, no input IO).
        //    Do NOT set kAudioStreamPropertyIsActive = 0 on them: that propagates to the REAL device's
        //    input stream and persists after the process exits (observed 2026-11-11, see APP-NOTES).
        var sub: [String: Any] = [kAudioSubDeviceUIDKey: opts.deviceUID]
        if opts.excludeDeviceInputs { sub[kAudioSubDeviceInputChannelsKey] = 0 }
        let aggUID = "org.eqape.agg.\(UUID().uuidString)"
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(opts.name) aggregate",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: opts.deviceUID,
            kAudioAggregateDeviceIsPrivateKey: opts.privateObjects ? 1 : 0,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [sub],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: 0]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &agg), "AudioHardwareCreateAggregateDevice")
        aggID = agg

        aggregateInputStreams = HAL.streams(aggID, scope: kAudioObjectPropertyScopeInput).count
        aggregateOutputStreams = HAL.streams(aggID, scope: kAudioObjectPropertyScopeOutput).count
        let inBufs = inputBufferCount()
        let nonInterleavedTap = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let tapBufCount = nonInterleavedTap ? tapChannels : 1
        let tapIndex = max(0, inBufs - tapBufCount)          // the tap stream comes last
        log("aggregate \(aggID): input streams \(aggregateInputStreams) (buffers \(inBufs)), output streams \(aggregateOutputStreams), tap buffer index \(tapIndex), rate \(HAL.sampleRate(aggID)), buffer \(HAL.uint32(aggID, kAudioDevicePropertyBufferFrameSize) ?? 0)")

        // 4. Listeners (delivered on eventQueue, never on the IO thread).
        addListener(aggID, addr(kAudioDeviceProcessorOverload)) { [stats] in stats.add(.overloads) }
        addListener(aggID, addr(kAudioAggregateDevicePropertyActiveSubDeviceList)) { [weak self] in
            guard let self else { return }
            let subs = (try? HAL.getArray(self.aggID, addr(kAudioAggregateDevicePropertyActiveSubDeviceList), AudioObjectID(0))) ?? []
            if subs.isEmpty { self.onTrouble?("aggregate lost its sub-device") }
        }
        addListener(aggID, addr(kAudioDevicePropertyNominalSampleRate)) { [weak self] in
            self?.onTrouble?("aggregate sample rate changed")
        }

        // 5. IO block + only the tap's input stream switched on.
        let block = makeIOBlock(tapIndex: tapIndex, tapBufCount: tapBufCount, nonInterleaved: nonInterleavedTap)
        var pid: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, nil, block), "AudioDeviceCreateIOProcIDWithBlock")
        procID = pid
        if aggregateInputStreams > 1 { setInputStreamUsage(onlyIndex: tapIndex, count: tapBufCount, total: aggregateInputStreams) }
    }

    private func allocateScratch(_ n: Int) {
        let s = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: n)
        for c in 0..<n {
            s[c] = .allocate(capacity: Self.maxFrames)
            s[c].initialize(repeating: 0, count: Self.maxFrames)
        }
        scratch = s
        scratchCount = n
    }

    /// AudioHardware.h kAudioDevicePropertyIOProcStreamUsage: only the tap stream is used.
    private func setInputStreamUsage(onlyIndex: Int, count: Int, total: Int) {
        guard total > 0, let p = procID else { return }
        let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + max(0, total - 1) * 4
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let u = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        u.pointee.mIOProc = unsafeBitCast(p, to: UnsafeMutableRawPointer.self)
        u.pointee.mNumberStreams = UInt32(total)
        let flags = raw.advanced(by: MemoryLayout.offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn)!)
            .assumingMemoryBound(to: UInt32.self)
        for i in 0..<total { flags[i] = (i >= onlyIndex && i < onlyIndex + count) ? 1 : 0 }
        var a = addr(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        let s = AudioObjectSetPropertyData(aggID, &a, 0, nil, UInt32(size), raw)
        log("IOProc input stream usage \((0..<total).map { flags[$0] }) -> \(osStatusString(s))")
    }

    /// AudioDeviceStart on a worker thread with a timeout. While the audio-capture permission is
    /// undetermined, coreaudiod asks tccd synchronously and AudioDeviceStart does not return until the
    /// prompt is answered (TAP-FINDINGS). Callers must not retry in a loop after `.timedOut`.
    public func start(timeout: Double) -> StartResult {
        guard let p = procID else { return .failed(OSStatus(kAudioHardwareNotRunningError)) }
        let sem = DispatchSemaphore(value: 0)
        let agg = aggID
        let status = UnsafeMutablePointer<OSStatus>.allocate(capacity: 1)  // leaked on timeout on purpose
        status.pointee = 0
        Thread.detachNewThread {
            status.pointee = AudioDeviceStart(agg, p)
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return .timedOut }
        let s = status.pointee
        status.deallocate()
        if s != noErr { return .failed(s) }
        isRunning = true
        return .started
    }

    private func inputBufferCount() -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggID, &a, 0, nil, &size) == noErr, size > 0 else { return 1 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(aggID, &a, 0, nil, &size, raw) == noErr else { return 1 }
        return Int(raw.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
    }

    private func addListener(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ body: @escaping () -> Void) {
        var a = a
        let blk: AudioObjectPropertyListenerBlock = { _, _ in body() }
        if AudioObjectAddPropertyListenerBlock(obj, &a, eventQueue, blk) == noErr {
            listeners.append((obj, a, blk))
        }
    }

    private func makeIOBlock(tapIndex: Int, tapBufCount: Int, nonInterleaved: Bool) -> AudioDeviceIOBlock {
        let st = stats.raw
        let slot = self.slot.raw
        let scratch = self.scratch!
        let chs = self.tapChannels
        let maxFrames = Self.maxFrames
        let nextIn = self.nextInputSampleTime
        let cFrames = EngineStats.Counter.frames.rawValue, cCallbacks = EngineStats.Counter.callbacks.rawValue
        let cDisc = EngineStats.Counter.discontinuities.rawValue, cMissing = EngineStats.Counter.missingInput.rawValue
        let cClip = EngineStats.Counter.clippedSamples.rawValue, cNonzero = EngineStats.Counter.nonzeroCallbacks.rawValue
        let pIn = EngineStats.Peak.input.rawValue, pOut = EngineStats.Peak.output.rawValue
        let pLat = EngineStats.Peak.latencyFrames.rawValue

        return { _, inInputData, inInputTime, outOutputData, inOutputTime in
            let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)

            // frames this cycle: from the output side (device clock), else from input
            var frames = 0
            if outABL.count > 0, outABL[0].mNumberChannels > 0 {
                frames = Int(outABL[0].mDataByteSize) / 4 / Int(outABL[0].mNumberChannels)
            }
            // deinterleave tap -> scratch
            if tapIndex + tapBufCount <= inABL.count, let d0 = inABL[tapIndex].mData {
                if nonInterleaved {
                    let n = Int(inABL[tapIndex].mDataByteSize) / 4
                    if frames == 0 { frames = n }
                    if frames > maxFrames { frames = maxFrames }
                    let m = min(frames, n)
                    for c in 0..<chs {
                        let src = (c < tapBufCount ? inABL[tapIndex + c].mData : nil)?.assumingMemoryBound(to: Float.self)
                        if let src { scratch[c].update(from: src, count: m) } else { scratch[c].update(repeating: 0, count: m) }
                        if m < frames { (scratch[c] + m).update(repeating: 0, count: frames - m) }
                    }
                } else {
                    let ich = max(1, Int(inABL[tapIndex].mNumberChannels))
                    let n = Int(inABL[tapIndex].mDataByteSize) / 4 / ich
                    if frames == 0 { frames = n }
                    if frames > maxFrames { frames = maxFrames }
                    let src = d0.assumingMemoryBound(to: Float.self)
                    let m = min(frames, n)
                    for c in 0..<chs {
                        let dst = scratch[c]
                        if c < ich { for i in 0..<m { dst[i] = src[i * ich + c] } } else { dst.update(repeating: 0, count: m) }
                        if m < frames { (dst + m).update(repeating: 0, count: frames - m) }
                    }
                }
            } else {
                rt_add(st, cMissing, 1)
                if frames > maxFrames { frames = maxFrames }
                for c in 0..<chs { scratch[c].update(repeating: 0, count: frames) }
            }

            var inPk: Float = 0
            for c in 0..<chs { let s = scratch[c]; for i in 0..<frames { let v = abs(s[i]); if v > inPk { inPk = v } } }
            rt_fmax(st, pIn, inPk)
            if inPk > 0 { rt_add(st, cNonzero, 1) }

            // >>> processing: whatever processor the slot currently holds (nil = unity bypass) <<<
            if let raw = rt_slot_acquire(slot) {
                Unmanaged<ProcessorBox>.fromOpaque(raw)._withUnsafeGuaranteedRef { box in
                    if box.channels == chs { box.process(UnsafePointer(scratch), frames) }
                }
            }
            rt_slot_release(slot)

            // output: interleave into the device's output buffers (extra channels silent)
            var outPk: Float = 0
            var clipped: UInt64 = 0
            var oc = 0
            for b in 0..<outABL.count {
                let buf = outABL[b]
                guard let d = buf.mData else { continue }
                let och = max(1, Int(buf.mNumberChannels))
                let n = min(frames, Int(buf.mDataByteSize) / 4 / och)
                let dst = d.assumingMemoryBound(to: Float.self)
                for k in 0..<och {
                    let c = oc + k
                    if c < chs {
                        let s = scratch[c]
                        for i in 0..<n {
                            let v = s[i]; dst[i * och + k] = v
                            let a = abs(v); if a > outPk { outPk = a }; if a >= 1 { clipped &+= 1 }
                        }
                    } else {
                        for i in 0..<n { dst[i * och + k] = 0 }
                    }
                }
                oc += och
            }
            rt_fmax(st, pOut, outPk)
            if clipped > 0 { rt_add(st, cClip, clipped) }

            let inT = inInputTime.pointee, outT = inOutputTime.pointee
            if inT.mFlags.contains(.sampleTimeValid) && outT.mFlags.contains(.sampleTimeValid) {
                rt_fstore(st, pLat, Float(outT.mSampleTime - inT.mSampleTime))
            }
            if inT.mFlags.contains(.sampleTimeValid) {
                let expected = nextIn.pointee
                if expected >= 0 && abs(inT.mSampleTime - expected) > 0.5 { rt_add(st, cDisc, 1) }
                nextIn.pointee = inT.mSampleTime + Double(frames)
            }
            rt_add(st, cFrames, UInt64(frames))
            rt_add(st, cCallbacks, 1)
        }
    }

    /// Idempotent teardown: stop IO, destroy IOProc, aggregate, tap (in that order).
    public func stop() {
        for (obj, a, blk) in listeners {
            var a = a
            AudioObjectRemovePropertyListenerBlock(obj, &a, eventQueue, blk)
        }
        listeners.removeAll()
        if aggID != kAudioObjectUnknown, let p = procID {
            if isRunning { let s = AudioDeviceStop(aggID, p); if s != noErr { log("AudioDeviceStop: \(osStatusString(s))") } }
            let s = AudioDeviceDestroyIOProcID(aggID, p); if s != noErr { log("DestroyIOProcID: \(osStatusString(s))") }
        }
        isRunning = false
        procID = nil
        if aggID != kAudioObjectUnknown {
            let s = AudioHardwareDestroyAggregateDevice(aggID)
            if s != noErr { log("destroy aggregate: \(osStatusString(s))") }
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            let s = AudioHardwareDestroyProcessTap(tapID)
            if s != noErr { log("destroy tap: \(osStatusString(s))") }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
