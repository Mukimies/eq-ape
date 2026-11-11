import CoreAudio
import Foundation
import RTAtomics

setvbuf(stdout, nil, _IONBF, 0)

func usage() -> Never {
    print("""
    eqtap: Core Audio process-tap EQ proof of concept

      eqtap list
      eqtap get-default
      eqtap set-default "<name or UID>" [--system]
      eqtap taps                       list tap objects + aggregate devices visible to this process
      eqtap perm                       TCC preflight for audio capture (never prompts)
      eqtap disclaim <command...>      run eqtap as its own TCC responsible process (not Terminal)
      eqtap run --device "<name or UID>" [--seconds N] [--gain dB] [--peak f,gainDB,Q]...
                [--bypass] [--no-mute] [--mute-mode muted|when-tapped] [--tap-buffer N]
                [--buffer FRAMES] [--public] [--tap-drift] [--hold] [--start-timeout S]

      --no-mute   tap does not mute the original; eqtap outputs silence (observe-only) unless --replay
    """)
    exit(2)
}

func dB(_ x: Float) -> String { x <= 0 ? "  -inf" : String(format: "%6.1f", 20 * log10(x)) }

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
args.removeFirst()

func takeValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func takeFlag(_ flag: String) -> Bool {
    guard let i = args.firstIndex(of: flag) else { return false }
    args.remove(at: i)
    return true
}

switch cmd {
case "list":
    let def = (try? HAL.defaultOutput()) ?? 0
    let sys = (try? HAL.defaultSystemOutput()) ?? 0
    for d in try HAL.outputDevices() {
        let mark = (d == def ? "*default" : "") + (d == sys ? " *system" : "")
        print(String(format: "%4u  %-28@ out %2d ch  in %2d ch  %6.0f Hz  %-10@ %@",
                     d, HAL.name(d) as NSString, HAL.channels(d, scope: kAudioObjectPropertyScopeOutput),
                     HAL.channels(d, scope: kAudioObjectPropertyScopeInput), HAL.sampleRate(d),
                     HAL.transport(d) as NSString, mark as NSString))
        print("      UID: \(HAL.uid(d))")
    }

case "get-default":
    let d = try HAL.defaultOutput(), s = try HAL.defaultSystemOutput()
    print("default output: \(HAL.name(d))")
    print("default system output: \(HAL.name(s))")

case "set-default":
    let system = takeFlag("--system")
    guard let key = args.first, let d = try HAL.findDevice(key) else { print("device not found"); exit(1) }
    try HAL.set(HAL.system, addr(system ? kAudioHardwarePropertyDefaultSystemOutputDevice : kAudioHardwarePropertyDefaultOutputDevice), d)
    print("\(system ? "default system output" : "default output") -> \(HAL.name(d))")

case "taps":
    let taps = (try? HAL.getArray(HAL.system, addr(kAudioHardwarePropertyTapList), AudioObjectID(0))) ?? []
    print("taps visible: \(taps.count)")
    for t in taps {
        let uid = (try? HAL.getString(t, addr(kAudioTapPropertyUID))) ?? "?"
        print("  tap \(t) uid \(uid)")
    }
    let aggs = try HAL.allDevices().filter { HAL.transport($0) == "aggregate" }
    print("aggregate devices visible: \(aggs.count)")
    for a in aggs { print("  \(a) \(HAL.name(a)) \(HAL.uid(a))") }

case "disclaim":
    // Re-spawn `eqtap <args>` as its own TCC "responsible process" (private libsystem SPI
    // responsibility_spawnattrs_setdisclaim), so TCC attributes audio capture to eqtap itself
    // (bundle id + NSAudioCaptureUsageDescription from the embedded __info_plist) instead of Terminal.
    typealias DisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
        print("responsibility_spawnattrs_setdisclaim not found"); exit(1)
    }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    _ = unsafeBitCast(sym, to: DisclaimFn.self)(&attr, 1)
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let argv = ([exe] + args).map { strdup($0) } + [nil]
    var child: pid_t = 0
    let rc = posix_spawn(&child, exe, nil, &attr, argv, environ)
    guard rc == 0 else { print("posix_spawn failed \(rc)"); exit(1) }
    for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler { kill(child, sig) }
        src.resume()
        _ = Unmanaged.passRetained(src)
    }
    var st: Int32 = 0
    while waitpid(child, &st, 0) < 0 && errno == EINTR {}
    exit((st & 0x7f) == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f))

case "cleanup":
    // Destroy leftover eqtap objects that are visible system-wide (only public ones can be).
    for t in (try? HAL.getArray(HAL.system, addr(kAudioHardwarePropertyTapList), AudioObjectID(0))) ?? [] {
        let name = (try? HAL.getString(t, addr(kAudioObjectPropertyName))) ?? ""
        let uid = (try? HAL.getString(t, addr(kAudioTapPropertyUID))) ?? "?"
        print("tap \(t) name '\(name)' uid \(uid): destroy -> \(osStatusString(AudioHardwareDestroyProcessTap(t)))")
    }
    for a in try HAL.allDevices() where HAL.uid(a).hasPrefix("org.eqape.eqtap.") {
        print("aggregate \(a) \(HAL.uid(a)): destroy -> \(osStatusString(AudioHardwareDestroyAggregateDevice(a)))")
    }

case "perm":
    // Private TCC.framework SPI, read-only preflight (does not prompt, does not modify TCC).
    typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    guard let h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
          let sym = dlsym(h, "TCCAccessPreflight") else { print("TCC SPI unavailable"); exit(1) }
    let fn = unsafeBitCast(sym, to: PreflightFn.self)
    for svc in ["kTCCServiceAudioCapture", "kTCCServiceMicrophone", "kTCCServiceScreenCapture"] {
        let r = fn(svc as CFString, nil)
        let meaning = r == 0 ? "granted" : r == 1 ? "denied" : r == 2 ? "not determined" : "?"
        print("\(svc): \(r) (\(meaning))")
    }

case "run":
    guard let key = takeValue("--device"), let dev = try HAL.findDevice(key) else { print("--device not found"); exit(1) }
    var opts = EngineOptions(deviceUID: HAL.uid(dev))
    let seconds = takeValue("--seconds").flatMap(Double.init)
    let gainDB = takeValue("--gain").flatMap(Double.init) ?? 0
    var peaks: [PeakSpec] = []
    while let p = takeValue("--peak") {
        let v = p.split(separator: ",").compactMap { Double($0) }
        guard v.count == 3, v[0] > 0, v[2] > 0 else { print("bad --peak \(p)"); exit(2) }
        peaks.append(PeakSpec(freq: v[0], gainDB: v[1], q: v[2]))
    }
    opts.bypass = takeFlag("--bypass")
    let noMute = takeFlag("--no-mute")
    let forceReplay = takeFlag("--replay")
    if noMute { opts.mute = .unmuted; opts.replay = forceReplay }
    if let m = takeValue("--mute-mode") { opts.mute = (m == "muted") ? .muted : .mutedWhenTapped; if noMute { opts.mute = .unmuted } }
    opts.tapBufferIndex = takeValue("--tap-buffer").flatMap(Int.init)
    opts.bufferFrames = takeValue("--buffer").flatMap(UInt32.init)
    opts.privateObjects = !takeFlag("--public")
    opts.tapDrift = takeFlag("--tap-drift")
    let hold = takeFlag("--hold")
    opts.subdevNoInput = takeFlag("--subdev-no-input")
    let startTimeout = takeValue("--start-timeout").flatMap(Double.init) ?? 5
    if !args.isEmpty { print("unknown args: \(args)"); usage() }

    print("device: \(HAL.name(dev)) [\(opts.deviceUID)] \(HAL.sampleRate(dev)) Hz; gain \(gainDB) dB; peaks \(peaks.map { "\($0.freq)Hz \($0.gainDB)dB Q\($0.q)" }); bypass \(opts.bypass); mute \(opts.mute.rawValue); replay \(opts.replay)")

    // Processing closure: the single plug-in point (EQCore later).
    let engine = TapEngine(device: dev, options: opts) { sampleRate, channels in
        let proc = PoCProcessor(sampleRate: sampleRate, channels: channels, gainDB: gainDB, peaks: peaks)
        return { bufs, chs, frames in proc.process(bufs, chs, frames) }
    }

    var shuttingDown = false
    func shutdown(_ why: String, code: Int32 = 0) -> Never {
        if !shuttingDown {
            shuttingDown = true
            print("shutdown: \(why)")
            // Bounded teardown: if coreaudiod is stuck (e.g. a pending TCC prompt), do not hang;
            // process exit makes coreaudiod drop our private tap + aggregate anyway.
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread { engine.stop(); done.signal() }
            if done.wait(timeout: .now() + 3) == .timedOut {
                print("teardown did not finish within 3 s; exiting anyway")
                _exit(code)   // skip atexit handlers, which can block on the stuck HAL call
            }
        }
        exit(code)
    }

    // Signals: handle on the main queue (not in async-signal context).
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { shutdown("signal \(sig)") }
        src.resume()
        sources.append(src)
    }

    do {
        try engine.prepare()
    } catch {
        print("prepare failed: \(error)")
        shutdown("prepare failure", code: 1)
    }
    if hold {
        // Objects exist, IO not started (no TCC involved). Used to test cleanup on owner death.
        print("holding tap \(engine.tapID) + aggregate \(engine.aggID) without IO (pid \(getpid()))")
    } else {
        switch engine.startIO(timeout: startTimeout) {
        case .started: break
        case .failed(let s): print("AudioDeviceStart failed: \(osStatusString(s))"); shutdown("start failure", code: 1)
        case .timedOut:
            print("AudioDeviceStart did not return within \(startTimeout) s: most likely blocked on the audio-capture (TCC) permission prompt. Run `eqtap perm`.")
            shutdown("start blocked", code: 3)
        }
    }

    let t0 = Date()
    var lastFrames: UInt64 = 0
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        let s = engine.stats
        let el = Date().timeIntervalSince(t0)
        let frames = rt_load(s, C.frames.rawValue)
        let inPk = rt_ftake(s, F.inPeak.rawValue), outPk = rt_ftake(s, F.outPeak.rawValue)
        var bufs: [String] = []
        for b in 0..<maxReportedBuffers {
            let v = rt_ftake(s, F.bufPeak0.rawValue + Int32(b))
            if b < 4 { bufs.append(dB(v).trimmingCharacters(in: .whitespaces)) }
        }
        let lat = rt_fload(s, F.latencyFrames.rawValue)
        let line = String(format: "[%5.1fs] in %@ dBFS  out %@ dBFS  frames %llu (+%llu)  cb %llu  zeroCB %llu  overload %llu  discont %llu  missing %llu  inbufs[%@]  in->out %.0f fr (%.1f ms)",
                          el, dB(inPk), dB(outPk), frames, frames - lastFrames, rt_load(s, C.callbacks.rawValue),
                          rt_load(s, C.zeroInputCallbacks.rawValue), rt_load(s, C.overloads.rawValue),
                          rt_load(s, C.discontinuities.rawValue), rt_load(s, C.missingInput.rawValue),
                          bufs.joined(separator: ",") as NSString, lat, Double(lat) / engine.sampleRate * 1000)
        print(line)
        lastFrames = frames
        if let sec = seconds, el >= sec - 0.01 {
            print(String(format: "summary: callbacks %llu, nonzero-input callbacks %llu, zero-input callbacks %llu, overloads %llu, discontinuities %llu",
                         rt_load(s, C.callbacks.rawValue), rt_load(s, C.nonzeroCallbacks.rawValue),
                         rt_load(s, C.zeroInputCallbacks.rawValue), rt_load(s, C.overloads.rawValue),
                         rt_load(s, C.discontinuities.rawValue)))
            shutdown("--seconds \(sec) elapsed")
        }
    }
    timer.resume()
    dispatchMain()

default:
    usage()
}
