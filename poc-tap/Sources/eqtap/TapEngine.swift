import CoreAudio
import Foundation
import RTAtomics

// Counter / float slots in RTStats
enum C: Int32 { case frames = 0, callbacks, overloads, discontinuities, zeroInputCallbacks, missingInput, oversize, nonzeroCallbacks, count }
enum F: Int32 { case inPeak = 0, outPeak, latencyFrames, ioFrames, bufPeak0 }
let maxReportedBuffers = 8

struct EngineOptions {
    var deviceUID: String
    var mute: CATapMuteBehavior = .mutedWhenTapped
    var replay = true              // write processed audio to the device
    var bypass = false             // replay unprocessed
    var tapBufferIndex: Int? = nil // which aggregate input buffer is the tap (default: last)
    var privateObjects = true      // private tap + private aggregate (die with this process)
    var tapDrift = false           // drift compensation on the sub-tap (should not be needed: same clock)
    var bufferFrames: UInt32? = nil
    var verbose = false
    var subdevNoInput = false      // experiment: "channels-in": 0 on the sub-device
}

/// Tap -> private aggregate (real device as clock/output + tap as input) -> one IOProc doing
/// capture, processing and playback in the same IO cycle on the device's own clock.
final class TapEngine {
    let opts: EngineOptions
    let device: AudioObjectID
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var started = false
    let stats: OpaquePointer = rt_create(C.count.rawValue, F.bufPeak0.rawValue + Int32(maxReportedBuffers))
    private(set) var tapFormat = AudioStreamBasicDescription()
    private(set) var sampleRate: Double = 48000
    private var process: ProcessFn = { _, _, _ in }
    private let makeProcess: (_ sampleRate: Double, _ channels: Int) -> ProcessFn
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    // IO-thread-only scratch (preallocated)
    private let maxFrames = 8192
    private var tapChannels = 2
    private var scratch: UnsafeMutablePointer<UnsafeMutablePointer<Float>>!
    private let nextInputSampleTime = UnsafeMutablePointer<Double>.allocate(capacity: 1)

    /// `makeProcess` is called once the tap format is known, before IO starts.
    init(device: AudioObjectID, options: EngineOptions,
         makeProcess: @escaping (_ sampleRate: Double, _ channels: Int) -> ProcessFn) {
        self.device = device
        self.opts = options
        self.makeProcess = makeProcess
        nextInputSampleTime.pointee = -1
    }

    deinit {
        stop()
        if let s = scratch {
            for c in 0..<tapChannels { s[c].deallocate() }
            s.deallocate()
        }
        nextInputSampleTime.deallocate()
        rt_destroy(stats)
    }

    func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    /// Creates tap, aggregate and IOProc (no IO yet; this part needs no TCC permission).
    func prepare() throws {
        // 1. Our own HAL process object, so the tap excludes our playback (no feedback).
        let me = try HAL.processObject(forPID: getpid())
        log("self process object: \(me) (pid \(getpid()))")

        // 2. Tap description: all processes except us, only audio destined for this device's stream 0.
        //    CATapDescription.h: initExcludingProcesses:andDeviceUID:withStream:
        let desc = CATapDescription(excludingProcesses: me == kAudioObjectUnknown ? [] : [me],
                                    deviceUID: opts.deviceUID, stream: 0)
        desc.name = "eqtap"
        desc.uuid = UUID()
        desc.muteBehavior = opts.mute
        desc.isPrivate = opts.privateObjects
        // 3. AudioHardwareTapping.h: AudioHardwareCreateProcessTap
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap
        let tapUID = try HAL.getString(tapID, addr(kAudioTapPropertyUID))
        tapFormat = try HAL.get(tapID, addr(kAudioTapPropertyFormat), AudioStreamBasicDescription())
        log("tap \(tapID) uid \(tapUID) mute=\(opts.mute.rawValue) private=\(opts.privateObjects)")
        log("tap format: \(describe(tapFormat))")
        tapChannels = max(1, Int(tapFormat.mChannelsPerFrame))
        sampleRate = tapFormat.mSampleRate > 0 ? tapFormat.mSampleRate : HAL.sampleRate(device)

        process = makeProcess(sampleRate, tapChannels)
        scratch = .allocate(capacity: tapChannels)
        for c in 0..<tapChannels {
            scratch[c] = .allocate(capacity: maxFrames)
            scratch[c].initialize(repeating: 0, count: maxFrames)
        }

        // 4. Private aggregate: the real device is main sub-device (clock + output), tap is input.
        let aggUID = "org.eqape.eqtap.agg.\(UUID().uuidString)"
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "eqtap aggregate",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: opts.deviceUID,
            kAudioAggregateDeviceIsPrivateKey: opts.privateObjects ? 1 : 0,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [opts.subdevNoInput
                ? [kAudioSubDeviceUIDKey: opts.deviceUID, kAudioSubDeviceInputChannelsKey: 0] as [String: Any]
                : [kAudioSubDeviceUIDKey: opts.deviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID,
                                              kAudioSubTapDriftCompensationKey: opts.tapDrift ? 1 : 0]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &agg),
                  "AudioHardwareCreateAggregateDevice")
        aggID = agg
        log("aggregate \(aggID) uid \(aggUID)")

        if let bf = opts.bufferFrames {
            do { try HAL.set(aggID, addr(kAudioDevicePropertyBufferFrameSize), bf) } catch { log("warn: \(error)") }
        }
        describeAggregate()

        // 5. Listeners: overload on the aggregate, liveness of the real device.
        addListener(aggID, addr(kAudioDeviceProcessorOverload)) { [stats] _ in rt_add(stats, C.overloads.rawValue, 1) }
        addListener(device, addr(kAudioDevicePropertyDeviceIsAlive)) { [weak self] _ in
            guard let self else { return }
            let alive = HAL.uint32(self.device, kAudioDevicePropertyDeviceIsAlive) ?? 0
            self.log("!! device IsAlive changed -> \(alive)")
        }
        addListener(aggID, addr(kAudioAggregateDevicePropertyActiveSubDeviceList)) { [weak self] _ in
            guard let self else { return }
            let subs = (try? HAL.getArray(self.aggID, addr(kAudioAggregateDevicePropertyActiveSubDeviceList), AudioObjectID(0))) ?? []
            self.log("!! aggregate active sub-devices changed -> \(subs)")
        }
        addListener(aggID, addr(kAudioDevicePropertyNominalSampleRate)) { [weak self] _ in
            guard let self else { return }
            self.log("!! aggregate sample rate changed -> \(HAL.sampleRate(self.aggID))")
        }

        // 6. One IO block: tap input -> process -> device output, same cycle.
        let inBufs = HAL.streams(aggID, scope: kAudioObjectPropertyScopeInput).count
        let nonInterleavedTap = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let tapBufCount = nonInterleavedTap ? tapChannels : 1
        // Each aggregate input *stream* maps to one AudioBuffer when interleaved.
        let defaultIndex = max(0, inputBufferCountGuess() - tapBufCount)
        let tapIndex = opts.tapBufferIndex ?? defaultIndex
        log("aggregate input streams: \(inBufs); tap buffer index \(tapIndex) (\(tapBufCount) buffer(s))")

        let block = makeIOBlock(tapIndex: tapIndex, tapBufCount: tapBufCount, nonInterleaved: nonInterleavedTap)
        var pid: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, nil, block), "AudioDeviceCreateIOProcIDWithBlock")
        procID = pid
        setInputStreamUsage(onlyIndex: tapIndex, count: tapBufCount, total: inBufs)
    }

    /// AudioHardware.h kAudioDevicePropertyIOProcStreamUsage: tell the HAL our IOProc only uses the
    /// tap's input stream(s), not the real device's own inputs (they arrive as NULL buffers).
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

    enum StartResult { case started, failed(OSStatus), timedOut }

    /// AudioDeviceStart on a worker thread. Observed on macOS 26: while the audio-capture TCC
    /// permission is undetermined, coreaudiod asks tccd synchronously and AudioDeviceStart does not
    /// return until the user answers the prompt. The timeout lets us report that instead of hanging.
    func startIO(timeout: Double) -> StartResult {
        let sem = DispatchSemaphore(value: 0)
        let agg = aggID, p = procID
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
        started = true
        log("started")
        return .started
    }

    private func inputBufferCountGuess() -> Int {
        // Sum of buffers in the aggregate's input stream configuration.
        var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggID, &a, 0, nil, &size) == noErr, size > 0 else { return 1 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(aggID, &a, 0, nil, &size, raw) == noErr else { return 1 }
        return Int(raw.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
    }

    private func describeAggregate() {
        let subs = (try? HAL.getArray(aggID, addr(kAudioAggregateDevicePropertyActiveSubDeviceList), AudioObjectID(0))) ?? []
        let subTaps = (try? HAL.getArray(aggID, addr(kAudioAggregateDevicePropertySubTapList), AudioObjectID(0))) ?? []
        log("aggregate active sub-devices \(subs) sub-taps \(subTaps); rate \(HAL.sampleRate(aggID))")
        for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
            let sname = scope == kAudioObjectPropertyScopeInput ? "in " : "out"
            for (i, s) in HAL.streams(aggID, scope: scope).enumerated() {
                let f = HAL.streamFormat(s).map(describe) ?? "?"
                let lat = HAL.uint32(s, kAudioStreamPropertyLatency) ?? 0
                log("  agg \(sname) stream[\(i)] id \(s): \(f), stream latency \(lat)")
            }
        }
        let buf = HAL.uint32(aggID, kAudioDevicePropertyBufferFrameSize) ?? 0
        rt_fstore(stats, F.ioFrames.rawValue, Float(buf))
        func lat(_ o: AudioObjectID, _ sc: AudioObjectPropertyScope) -> String {
            "latency \(HAL.uint32(o, kAudioDevicePropertyLatency, sc) ?? 0) safety \(HAL.uint32(o, kAudioDevicePropertySafetyOffset, sc) ?? 0)"
        }
        log("  agg buffer \(buf) frames; agg in: \(lat(aggID, kAudioObjectPropertyScopeInput)); agg out: \(lat(aggID, kAudioObjectPropertyScopeOutput))")
        log("  device out: \(lat(device, kAudioObjectPropertyScopeOutput)); device buffer \(HAL.uint32(device, kAudioDevicePropertyBufferFrameSize) ?? 0)")
        for st in subTaps {
            let x = (try? HAL.get(st, addr(kAudioSubTapPropertyExtraLatency), Float64(0))) ?? -1
            let d = HAL.uint32(st, kAudioSubTapPropertyDriftCompensation) ?? 99
            log("  sub-tap \(st): extra latency \(x) s, drift compensation \(d)")
        }
    }

    private func addListener(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ body: @escaping (Int) -> Void) {
        var a = a
        let blk: AudioObjectPropertyListenerBlock = { n, _ in body(Int(n)) }
        if AudioObjectAddPropertyListenerBlock(obj, &a, DispatchQueue.main, blk) == noErr {
            listeners.append((obj, a, blk))
        }
    }

    private func makeIOBlock(tapIndex: Int, tapBufCount: Int, nonInterleaved: Bool) -> AudioDeviceIOBlock {
        let stats = self.stats
        let scratch = self.scratch!
        let chs = self.tapChannels
        let maxFrames = self.maxFrames
        let nextIn = self.nextInputSampleTime
        let replay = opts.replay
        let bypass = opts.bypass
        let unmanagedSelf = Unmanaged.passUnretained(self)

        return { _, inInputData, inInputTime, outOutputData, inOutputTime in
            let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)

            // per-input-buffer peaks (diagnostic: identifies which buffer carries the tap)
            for b in 0..<min(inABL.count, maxReportedBuffers) {
                let buf = inABL[b]
                guard let d = buf.mData else { continue }
                let n = Int(buf.mDataByteSize) / 4
                let p = d.assumingMemoryBound(to: Float.self)
                var pk: Float = 0
                for i in 0..<n { let v = abs(p[i]); if v > pk { pk = v } }
                rt_fmax(stats, F.bufPeak0.rawValue + Int32(b), pk)
            }

            // frames this cycle: from the output side (device clock), else from input
            var frames = 0
            if outABL.count > 0, outABL[0].mNumberChannels > 0 {
                frames = Int(outABL[0].mDataByteSize) / 4 / Int(outABL[0].mNumberChannels)
            }
            // deinterleave tap -> scratch
            var haveInput = false
            if tapIndex + tapBufCount <= inABL.count, let d0 = inABL[tapIndex].mData {
                haveInput = true
                if nonInterleaved {
                    let n = Int(inABL[tapIndex].mDataByteSize) / 4
                    if frames == 0 { frames = n }
                    if frames > maxFrames { rt_add(stats, C.oversize.rawValue, 1); frames = maxFrames }
                    for c in 0..<chs {
                        let src = (c < tapBufCount ? inABL[tapIndex + c].mData : nil)?.assumingMemoryBound(to: Float.self)
                        let m = min(frames, n)
                        if let src { scratch[c].update(from: src, count: m) } else { scratch[c].update(repeating: 0, count: m) }
                        if m < frames { (scratch[c] + m).update(repeating: 0, count: frames - m) }
                    }
                } else {
                    let ich = max(1, Int(inABL[tapIndex].mNumberChannels))
                    let n = Int(inABL[tapIndex].mDataByteSize) / 4 / ich
                    if frames == 0 { frames = n }
                    if frames > maxFrames { rt_add(stats, C.oversize.rawValue, 1); frames = maxFrames }
                    let src = d0.assumingMemoryBound(to: Float.self)
                    let m = min(frames, n)
                    for c in 0..<chs {
                        let dst = scratch[c]
                        if c < ich { for i in 0..<m { dst[i] = src[i * ich + c] } } else { dst.update(repeating: 0, count: m) }
                        if m < frames { (dst + m).update(repeating: 0, count: frames - m) }
                    }
                }
            } else {
                rt_add(stats, C.missingInput.rawValue, 1)
                if frames > maxFrames { frames = maxFrames }
                for c in 0..<chs { scratch[c].update(repeating: 0, count: frames) }
            }

            // input peak + silence detection
            var inPk: Float = 0
            for c in 0..<chs { let s = scratch[c]; for i in 0..<frames { let v = abs(s[i]); if v > inPk { inPk = v } } }
            rt_fmax(stats, F.inPeak.rawValue, inPk)
            if haveInput { rt_add(stats, inPk == 0 ? C.zeroInputCallbacks.rawValue : C.nonzeroCallbacks.rawValue, 1) }

            // >>> the processing step <<<
            if !bypass {
                unmanagedSelf._withUnsafeGuaranteedRef { $0.process(UnsafePointer(scratch), chs, frames) }
            }

            // output: interleave into the device's output buffers (channel c <- scratch[c], extra channels silent)
            var outPk: Float = 0
            var oc = 0
            for b in 0..<outABL.count {
                let buf = outABL[b]
                guard let d = buf.mData else { continue }
                let och = max(1, Int(buf.mNumberChannels))
                let n = min(frames, Int(buf.mDataByteSize) / 4 / och)
                let dst = d.assumingMemoryBound(to: Float.self)
                for k in 0..<och {
                    let c = oc + k
                    if replay && c < chs {
                        let s = scratch[c]
                        for i in 0..<n { let v = s[i]; dst[i * och + k] = v; let a = abs(v); if a > outPk { outPk = a } }
                    } else {
                        for i in 0..<n { dst[i * och + k] = 0 }
                    }
                }
                oc += och
            }
            rt_fmax(stats, F.outPeak.rawValue, outPk)

            // timing
            let inT = inInputTime.pointee, outT = inOutputTime.pointee
            if inT.mFlags.contains(.sampleTimeValid) && outT.mFlags.contains(.sampleTimeValid) {
                rt_fstore(stats, F.latencyFrames.rawValue, Float(outT.mSampleTime - inT.mSampleTime))
            }
            if inT.mFlags.contains(.sampleTimeValid) {
                let expected = nextIn.pointee
                if expected >= 0 && abs(inT.mSampleTime - expected) > 0.5 { rt_add(stats, C.discontinuities.rawValue, 1) }
                nextIn.pointee = inT.mSampleTime + Double(frames)
            }
            rt_add(stats, C.frames.rawValue, UInt64(frames))
            rt_add(stats, C.callbacks.rawValue, 1)
        }
    }

    /// Idempotent teardown: stop IO, destroy IOProc, aggregate, tap (in that order).
    func stop() {
        for (obj, a, blk) in listeners {
            var a = a
            AudioObjectRemovePropertyListenerBlock(obj, &a, DispatchQueue.main, blk)
        }
        listeners.removeAll()
        if aggID != kAudioObjectUnknown, let p = procID {
            if started { let s = AudioDeviceStop(aggID, p); if s != noErr { log("AudioDeviceStop: \(osStatusString(s))") } }
            let s = AudioDeviceDestroyIOProcID(aggID, p); if s != noErr { log("DestroyIOProcID: \(osStatusString(s))") }
        }
        started = false
        procID = nil
        if aggID != kAudioObjectUnknown {
            let s = AudioHardwareDestroyAggregateDevice(aggID)
            log("destroyed aggregate \(aggID): \(osStatusString(s))")
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            let s = AudioHardwareDestroyProcessTap(tapID)
            log("destroyed tap \(tapID): \(osStatusString(s))")
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
