import CoreAudio
import Foundation
import EQApeCore
import TapKit

/// Terminal mode. Started from Terminal, the process inherits Terminal's audio-capture permission
/// (TCC responsible process), so no new permission prompt can appear. As a second safety net it
/// refuses to start IO unless the read-only TCC preflight says "granted" (override: --allow-prompt).
enum Headless {
    static func usage() -> Never {
        print("""
        EQ Ape (EQApe) headless / CLI mode

          EQApe --headless --device "<name|UID>" --config <file> [--seconds N] [--headroom dB | --no-headroom] [--bypass]
          EQApe --headless --follow-default [--settings <settings.json>] [--seconds N]
                common: [--start-timeout S] [--allow-prompt] [--quiet]
          EQApe --list                     output devices
          EQApe --get-default
          EQApe --set-default "<name|UID>"
          EQApe --probe --device "<name>"  create tap + aggregate WITHOUT starting IO (no permission needed), print layout
          EQApe --set-rate "<name>" <Hz>   change a device's nominal sample rate (tests)
          EQApe --taps                     taps / aggregates visible to this process

        Status line (one per second): input peak, output peak (dBFS, peak over the last second), clipped samples,
        IO callbacks, overloads, discontinuities, applied anti-clipping gain, device, state.
        """)
        exit(2)
    }

    static func main(_ argv: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        var args = argv
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
        }
        func flag(_ f: String) -> Bool {
            guard let i = args.firstIndex(of: f) else { return false }
            args.remove(at: i); return true
        }

        if flag("--help") || flag("-h") { usage() }
        if flag("--list") {
            let def = HAL.defaultOutput() ?? 0
            for d in HAL.outputDevices() {
                print(String(format: "%4u  %-28@ out %2d  in %2d  %6.0f Hz %@", d, HAL.name(d) as NSString,
                             HAL.channels(d, scope: kAudioObjectPropertyScopeOutput), HAL.channels(d, scope: kAudioObjectPropertyScopeInput),
                             HAL.sampleRate(d), (d == def ? "*default" : "") as NSString))
                print("      UID: \(HAL.uid(d) ?? "?")")
            }
            exit(0)
        }
        if flag("--get-default") { print("default output: \(HAL.defaultOutput().map(HAL.name) ?? "none")"); exit(0) }
        if let key = value("--set-default") {
            guard let d = HAL.findDevice(key) else { print("device not found: \(key)"); exit(1) }
            do { try HAL.setDefaultOutput(d); print("default output -> \(HAL.name(d))"); exit(0) }
            catch { print("\(error)"); exit(1) }
        }
        if let key = value("--set-rate") {
            guard let d = HAL.findDevice(key), let hz = args.first.flatMap(Double.init) else { print("usage: --set-rate <device> <Hz>"); exit(2) }
            do { try HAL.set(d, addr(kAudioDevicePropertyNominalSampleRate), Float64(hz)) } catch { print("\(error)"); exit(1) }
            usleep(300_000)
            print("\(HAL.name(d)) nominal rate -> \(HAL.sampleRate(d))"); exit(0)
        }
        if flag("--taps") {
            let taps = HAL.tapList()
            print("taps visible: \(taps.count)")
            let aggs = HAL.allDevices().filter { HAL.transportType($0) == kAudioDeviceTransportTypeAggregate }
            print("aggregate devices visible: \(aggs.count)")
            for a in aggs { print("  \(a) \(HAL.name(a)) \(HAL.uid(a) ?? "?")") }
            exit(0)
        }
        if flag("--probe") {
            guard let key = value("--device"), let d = HAL.findDevice(key), let uid = HAL.uid(d) else { print("--device not found"); exit(1) }
            print("device \(HAL.name(d)): own input channels \(HAL.channels(d, scope: kAudioObjectPropertyScopeInput))")
            print("real device input streams before: IsActive \(HAL.streams(d, scope: kAudioObjectPropertyScopeInput).map { HAL.uint32($0, kAudioStreamPropertyIsActive) ?? 99 })")
            for exclude in [false, true] {
                var o = TapEngine.Options(deviceUID: uid); o.excludeDeviceInputs = exclude
                let e = TapEngine(device: d, options: o, stats: EngineStats(), slot: ProcessorSlot())
                e.log = { print("  \($0)") }
                do {
                    try e.prepare()
                    print("excludeDeviceInputs=\(exclude): aggregate input streams \(e.aggregateInputStreams), input channels \(HAL.channels(e.aggID, scope: kAudioObjectPropertyScopeInput)), output channels \(HAL.channels(e.aggID, scope: kAudioObjectPropertyScopeOutput))")
                } catch { print("excludeDeviceInputs=\(exclude): prepare failed: \(error)") }
                e.stop()
            }
            if let d2 = HAL.findDevice(key) {
                print("real device input streams after: IsActive \(HAL.streams(d2, scope: kAudioObjectPropertyScopeInput).map { HAL.uint32($0, kAudioStreamPropertyIsActive) ?? 99 })")
            }
            exit(0)
        }
        guard flag("--headless") else { usage() }

        let seconds = value("--seconds").flatMap(Double.init)
        let startTimeout = value("--start-timeout").flatMap(Double.init) ?? 5
        let allowPrompt = flag("--allow-prompt")
        let quiet = flag("--quiet")
        let bypass = flag("--bypass")
        let follow = flag("--follow-default")
        let deviceKey = value("--device")
        let configPath = value("--config")
        let settingsPath = value("--settings")
        let headroomArg = value("--headroom").flatMap(Double.init)
        let noHeadroom = flag("--no-headroom")
        if !args.isEmpty { print("unknown arguments: \(args)"); usage() }

        let perm = Permission.audioCapture()
        print("audio-capture permission (preflight, responsible process): \(perm.rawValue)")
        if perm != .granted && !allowPrompt {
            print("refusing to start: starting IO would raise a permission prompt (which blocks coreaudiod until answered). Use --allow-prompt only when someone is at the computer.")
            exit(4)
        }

        let controller: TapController
        if follow {
            let store = SettingsStore(fileURL: settingsPath.map { URL(fileURLWithPath: $0) } ?? SettingsStore.defaultFileURL)
            print("follow-default, settings \(store.fileURL.path)")
            controller = TapController(mode: .followDefault, store: store)
        } else {
            guard let key = deviceKey, let cfg = configPath else { print("need --device and --config (or --follow-default)"); usage() }
            guard let d = HAL.findDevice(key), let uid = HAL.uid(d) else { print("device not found: \(key)"); exit(1) }
            var p = DeviceProfile(deviceName: HAL.name(d), configPath: (cfg as NSString).expandingTildeInPath)
            if noHeadroom { p.headroomEnabled = false }
            if let h = headroomArg { p.headroomDB = h }
            controller = TapController(mode: .fixed(uid), store: nil, ephemeral: Settings(profiles: [uid: p]))
        }
        controller.startTimeout = startTimeout
        controller.bypassProcessing = bypass
        let t0 = Date()
        func stamp() -> String { String(format: "%6.1fs", Date().timeIntervalSince(t0)) }
        controller.onEvent = { s in if !quiet || s.hasPrefix("error") || s.contains("blocked") { print("[\(stamp())] event: \(s)") } }

        var shuttingDown = false
        func shutdown(_ why: String, code: Int32 = 0) -> Never {
            if !shuttingDown {
                shuttingDown = true
                print("[\(stamp())] shutdown: \(why)")
                let done = DispatchSemaphore(value: 0)
                Thread.detachNewThread { controller.shutdown(); done.signal() }
                if done.wait(timeout: .now() + 3) == .timedOut {
                    print("teardown did not finish within 3 s; exiting anyway")
                    _exit(code)
                }
            }
            exit(code)
        }
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { shutdown("signal \(sig)") }
            src.resume()
            sources.append(src)
        }

        controller.start()

        func dB(_ x: Float) -> String { x <= 0 ? "  -inf" : String(format: "%6.1f", 20 * log10(x)) }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            let m = controller.takeMeter()
            let st = controller.status
            let gain = st.appliedGainDB.map { String(format: "%6.2f", $0) } ?? "   n/a"
            print(String(format: "[%@] in %@ out %@ dBFS | clip %llu | cb %llu | ovl %llu | disc %llu | gain %@ dB | %@ | %@",
                         stamp(), dB(m.inputPeak), dB(m.outputPeak), m.clippedSamples, m.callbacks, m.overloads,
                         m.discontinuities, gain, (st.deviceName ?? "-") as NSString, st.state.label as NSString))
            if case .error(let e) = st.state, e.contains("blocked") { shutdown("start blocked", code: 3) }
            if let s = seconds, Date().timeIntervalSince(t0) >= s - 0.01 {
                print(String(format: "summary: callbacks %llu, overloads %llu, discontinuities %llu, clipped %llu, rebuilds %d, reloads %d, warnings %d",
                             m.callbacks, m.overloads, m.discontinuities, m.clippedSamples, st.rebuilds, st.reloads, st.warnings.count))
                shutdown("--seconds \(s) elapsed")
            }
        }
        timer.resume()
        withExtendedLifetime((sources, timer)) { RunLoop.main.run() }
    }
}
