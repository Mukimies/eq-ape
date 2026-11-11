import AppKit
import CoreAudio
import EQCore
import Foundation
import TapKit

/// The app's brain, without UI. All engine work happens on one serial control queue (never on the
/// audio thread, never on the main thread): device following, profile selection, config loading and
/// watching, glitch-free processor swaps, rebuilds on device / format / wake events.
public final class TapController: @unchecked Sendable {

    public enum DeviceMode: Equatable, Sendable {
        case followDefault
        case fixed(String)      // device name or UID (headless --device)
    }

    public struct Status: Equatable, Sendable {
        public var state: EngineState = .off
        public var deviceName: String?
        public var deviceUID: String?
        public var profile: DeviceProfile?
        public var configPath: String?
        public var warnings: [String] = []
        public var appliedGainDB: Double?
        public var sampleRate: Double?
        public var channels: Int?
        public var rebuilds = 0
        public var reloads = 0
        public var aggregateInputStreams: Int?
        public var settingsError: String?
        public init() {}
    }

    public struct Meter: Sendable {
        public var inputPeak: Float      // linear, since the previous takeMeter()
        public var outputPeak: Float
        public var clippedSamples: UInt64
        public var callbacks: UInt64
        public var overloads: UInt64
        public var discontinuities: UInt64
        public var latencyFrames: Float

        public static func dB(_ x: Float) -> Double { x <= 0 ? -.infinity : 20 * log10(Double(x)) }
    }

    // MARK: configuration

    public let mode: DeviceMode
    public let store: SettingsStore?
    public var startTimeout: Double = 5
    public var bypassProcessing = false              // headless --bypass: tap + replay at unity
    public var debounce: TimeInterval = 0.25
    /// Log lines (called on the control queue).
    public var onEvent: ((String) -> Void)?
    /// Status changes (called on the main queue).
    public var onStatusChange: ((Status) -> Void)?

    // MARK: state (control queue only)

    public let queue = DispatchQueue(label: "EQApe.control", qos: .userInitiated)
    public let stats = EngineStats()
    private let slot = ProcessorSlot()
    private var settings: Settings
    private var engine: TapEngine?
    private var engineKey: String?
    private var engineDevice: AudioObjectID = 0
    private var stuckEngines: [TapEngine] = []      // engines whose AudioDeviceStart never returned
    private var startBlocked = false
    private var loaded: LoadedConfig?
    private var loadedPath: String?
    private var processorSpec: (config: EQConfig?, headroom: Double?, sr: Double, ch: Int)?
    private let watcher = FileWatcher()
    private var pendingWork: DispatchWorkItem?
    private var pendingForce = false
    private var pendingReload = false
    private var retryDelay: TimeInterval = 1
    private var retryWork: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?
    private var lastCallbacks: UInt64 = 0
    private var stalledTicks = 0
    private var sleeping = false
    private var started = false
    private var systemListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var listenedDevice: AudioObjectID = 0
    private var workspaceObservers: [NSObjectProtocol] = []

    private let statusLock = NSLock()
    private var _status = Status()
    public var status: Status { statusLock.lock(); defer { statusLock.unlock() }; return _status }

    /// `store` = persistent settings (GUI, or headless --settings); `ephemeral` = in-memory settings
    /// that are never written (headless --device/--config).
    public init(mode: DeviceMode, store: SettingsStore?, ephemeral: Settings? = nil) {
        self.mode = mode
        self.store = store
        var s = ephemeral ?? Settings()
        var settingsError: String?
        if ephemeral == nil, let store {
            do { s = try store.load() } catch { settingsError = "\(error)" }
        }
        settings = s
        _status.settingsError = settingsError
        watcher.onChange = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.event("config file changed: reloading")
                self.scheduleReconcile(force: false, reload: true, delay: 0)
            }
        }
    }

    deinit { watcher.stop() }

    // MARK: public API (any thread)

    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            installSystemListeners()
            installWorkspaceObservers()
            startWatchdog()
            reconcile(force: false, reload: true)
        }
    }

    /// Synchronous teardown (for quit / signals). Bounded by the caller.
    public func shutdown() {
        queue.sync { [self] in
            started = false
            watchdog?.cancel(); watchdog = nil
            pendingWork?.cancel(); retryWork?.cancel()
            removeListeners(&systemListeners)
            removeListeners(&deviceListeners)
            for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
            workspaceObservers.removeAll()
            watcher.stop()
            teardown(reason: "shutdown")
        }
    }

    public var currentSettings: Settings { queue.sync { settings } }

    public func setEnabled(_ on: Bool) {
        updateSettings { $0.enabled = on }
    }

    /// Mutate settings, persist (if there is a store) and re-evaluate.
    public func updateSettings(_ change: @escaping (inout Settings) -> Void) {
        queue.async { [self] in
            change(&settings)
            if let store {
                do { try store.save(settings); setStatus { $0.settingsError = nil } }
                catch { setStatus { $0.settingsError = "could not save settings: \(error.localizedDescription)" } }
            }
            startBlocked = false
            scheduleReconcile(force: false, reload: true, delay: 0)
        }
    }

    /// Set / replace the config file of the current device (creates the profile if needed).
    public func chooseConfig(path: String) {
        queue.async { [self] in
            guard let dev = targetDevice(), let uid = HAL.uid(dev) else { return }
            let name = HAL.name(dev)
            updateSettings { s in
                var p = s.profiles[uid] ?? DeviceProfile(deviceName: name)
                p.deviceName = name
                p.configPath = path
                p.enabled = true
                s.profiles[uid] = p
            }
        }
    }

    public func removeProfileForCurrentDevice() {
        queue.async { [self] in
            guard let dev = targetDevice(), let uid = HAL.uid(dev) else { return }
            updateSettings { $0.profiles[uid] = nil }
        }
    }

    public func setHeadroomForCurrentDevice(enabled: Bool) {
        queue.async { [self] in
            guard let dev = targetDevice(), let uid = HAL.uid(dev) else { return }
            updateSettings { s in s.profiles[uid]?.headroomEnabled = enabled }
        }
    }

    /// Manual reload: re-read the config, and clear a "start blocked" condition (user is present).
    public func reload() {
        queue.async { [self] in
            startBlocked = false
            event("manual reload")
            scheduleReconcile(force: true, reload: true, delay: 0)
        }
    }

    /// Read-and-reset peaks plus cumulative counters.
    public func takeMeter() -> Meter {
        Meter(inputPeak: stats.takePeak(.input), outputPeak: stats.takePeak(.output),
              clippedSamples: stats.load(.clippedSamples), callbacks: stats.load(.callbacks),
              overloads: stats.load(.overloads), discontinuities: stats.load(.discontinuities),
              latencyFrames: stats.loadFloat(.latencyFrames))
    }

    // MARK: reconcile

    private func scheduleReconcile(force: Bool, reload: Bool, delay: TimeInterval? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingForce = pendingForce || force
        pendingReload = pendingReload || reload
        pendingWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let f = self.pendingForce, r = self.pendingReload
            self.pendingForce = false; self.pendingReload = false
            self.reconcile(force: f, reload: r)
        }
        pendingWork = w
        queue.asyncAfter(deadline: .now() + (delay ?? debounce), execute: w)
    }

    private func targetDevice() -> AudioObjectID? {
        switch mode {
        case .followDefault: return HAL.defaultOutput()
        case .fixed(let key): return HAL.findDevice(key)
        }
    }

    private func reconcile(force: Bool, reload: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard started else { return }
        retryWork?.cancel(); retryWork = nil
        if sleeping { teardown(reason: "system sleeping"); return }

        let dev = targetDevice()
        listenToDevice(dev)
        let uid = dev.flatMap(HAL.uid)
        let name = dev.map(HAL.name)
        let decision = Decision.decide(globalEnabled: true, deviceUID: uid, settings: settings)
        setStatus { st in
            st.deviceName = name; st.deviceUID = uid
            st.profile = uid.flatMap { self.settings.profiles[$0] }
        }

        guard case let .process(path, headroom) = decision, let dev, let uid else {
            if case let .untouched(state) = decision {
                teardown(reason: state.label)
                if loadedPath != nil { watcher.stop(); loaded = nil; loadedPath = nil }
                setStatus { $0.state = state; $0.configPath = nil; $0.warnings = []; $0.appliedGainDB = nil }
            }
            return
        }

        // Config (re)load. Unusable config -> device untouched, but keep watching so a fix is picked up.
        if loaded == nil || loadedPath != path || reload {
            let l = ConfigLoader.load(path: path)
            let changed = loaded.map { $0.config != l.config } ?? true
            loaded = l; loadedPath = path
            watcher.watch(l.files)
            if changed { setStatus { $0.reloads += 1 } }
            event("config loaded: \(l.isUsable ? "ok" : (l.problem ?? "?")), \(l.warnings.count) warning(s), watching \(l.files.count) file(s)")
        }
        let l = loaded!
        setStatus { $0.configPath = path; $0.warnings = l.warnings }
        guard let config = l.config else {
            teardown(reason: "config unusable")
            setStatus { $0.state = .bypassed(l.problem ?? "config unusable"); $0.appliedGainDB = nil }
            return
        }

        let key = uid + "|" + HAL.formatSignature(dev)
        let needEngine = engine == nil || engineKey != key || force || !(engine?.isRunning ?? false)
        if needEngine {
            teardown(reason: force ? "forced rebuild" : "device/format change")
            if startBlocked {
                setStatus { $0.state = .error("audio start blocked: answer the audio-capture permission prompt, then choose Reload") }
                return
            }
            buildEngine(device: dev, uid: uid, key: key, config: config, headroom: headroom)
        } else if let e = engine {
            swapProcessorIfNeeded(config: config, headroom: headroom, sr: e.sampleRate, ch: e.tapChannels)
            setStatus { $0.state = .active }
        }
    }

    private func buildEngine(device dev: AudioObjectID, uid: String, key: String, config: EQConfig, headroom: Double?) {
        setStatus { $0.state = .starting }
        var opts = TapEngine.Options(deviceUID: uid)
        opts.name = "EQ Ape"
        let e = TapEngine(device: dev, options: opts, stats: stats, slot: slot)
        e.eventQueue = queue
        e.log = { [weak self] in self?.event("engine: \($0)") }
        e.onTrouble = { [weak self] why in
            guard let self else { return }
            self.event("engine trouble: \(why)")
            self.scheduleReconcile(force: true, reload: false)
        }
        do {
            try e.prepare()
        } catch {
            e.stop()
            fail("could not create tap: \(error)")
            return
        }
        swapProcessorIfNeeded(config: config, headroom: headroom, sr: e.sampleRate, ch: e.tapChannels, forceBuild: true)
        let t0 = Date()
        switch e.start(timeout: startTimeout) {
        case .started:
            engine = e; engineKey = key; engineDevice = dev
            retryDelay = 1
            lastCallbacks = stats.load(.callbacks); stalledTicks = 0
            setStatus { st in
                st.state = .active; st.rebuilds += 1
                st.sampleRate = e.sampleRate; st.channels = e.tapChannels
                st.aggregateInputStreams = e.aggregateInputStreams
            }
            event(String(format: "engine started on \"%@\" (%.0f Hz, %d ch, agg inputs %d) in %.0f ms",
                         HAL.name(dev), e.sampleRate, e.tapChannels, e.aggregateInputStreams, Date().timeIntervalSince(t0) * 1000))
        case .failed(let s):
            e.stop()
            fail("AudioDeviceStart failed: \(osStatusString(s))")
        case .timedOut:
            // Never retry automatically: a pending permission prompt blocks coreaudiod for everyone.
            stuckEngines.append(e)
            startBlocked = true
            setStatus { $0.state = .error("audio start blocked (permission prompt pending?): answer it, then choose Reload") }
            event("AudioDeviceStart did not return within \(startTimeout) s; not retrying")
        }
    }

    private func fail(_ msg: String) {
        event("error: \(msg); retry in \(Int(retryDelay)) s")
        setStatus { $0.state = .error(msg) }
        let w = DispatchWorkItem { [weak self] in self?.reconcile(force: true, reload: false) }
        retryWork = w
        queue.asyncAfter(deadline: .now() + retryDelay, execute: w)
        retryDelay = min(30, retryDelay * 2)
    }

    /// Build a new EQProcessor here (control queue), swap it in atomically, free the old one here.
    private func swapProcessorIfNeeded(config: EQConfig, headroom: Double?, sr: Double, ch: Int, forceBuild: Bool = false) {
        let want: EQConfig? = bypassProcessing ? nil : config
        if !forceBuild, let p = processorSpec, p.config == want, p.headroom == headroom, p.sr == sr, p.ch == ch { return }
        let t0 = Date()
        var box: ProcessorBox?
        if let want {
            let eq = EQProcessor(config: want, sampleRate: sr, channels: ch, headroomDB: headroom, maxFrames: 4096)
            box = ProcessorBox(eq: eq, channels: ch, sampleRate: sr)
        }
        let old = slot.swap(box)
        processorSpec = (want, headroom, sr, ch)
        let gain = box?.appliedGainDB ?? 0
        setStatus { $0.appliedGainDB = box == nil ? nil : gain }
        event(String(format: "processor %@ (%.0f Hz, %d ch, anti-clip gain %.2f dB) built+swapped in %.0f ms",
                     box == nil ? "bypass" : "EQ", sr, ch, gain, Date().timeIntervalSince(t0) * 1000))
        _ = old   // released here, on the control queue
    }

    private func teardown(reason: String) {
        if let e = engine {
            e.stop()
            event("engine stopped (\(reason))")
        }
        engine = nil; engineKey = nil; engineDevice = 0
        if slot.current != nil { _ = slot.swap(nil) }
        processorSpec = nil
    }

    // MARK: listeners

    private func installSystemListeners() {
        let sys = HAL.system
        addListener(sys, addr(kAudioHardwarePropertyDefaultOutputDevice), into: &systemListeners) { [weak self] in
            guard let self, self.mode == .followDefault else { return }
            self.event("default output changed -> \(HAL.defaultOutput().map(HAL.name) ?? "none")")
            self.scheduleReconcile(force: false, reload: false)
        }
        addListener(sys, addr(kAudioHardwarePropertyDevices), into: &systemListeners) { [weak self] in
            self?.scheduleReconcile(force: false, reload: false)
        }
    }

    private func listenToDevice(_ dev: AudioObjectID?) {
        let d = dev ?? 0
        guard d != listenedDevice else { return }
        removeListeners(&deviceListeners)
        listenedDevice = d
        guard d != 0 else { return }
        let out = kAudioObjectPropertyScopeOutput
        let forceRebuild: [(AudioObjectPropertyAddress, String)] = [
            (addr(kAudioDevicePropertyDeviceIsAlive), "device alive state changed"),
            (addr(kAudioDevicePropertyNominalSampleRate), "sample rate changed"),
            (addr(kAudioDevicePropertyStreamConfiguration, out), "stream configuration changed"),
            (addr(kAudioDevicePropertyStreams, out), "streams changed"),
        ]
        for (a, why) in forceRebuild {
            addListener(d, a, into: &deviceListeners) { [weak self] in
                guard let self else { return }
                self.event("device event: \(why)")
                self.scheduleReconcile(force: false, reload: false)   // the format signature decides
            }
        }
        addListener(d, addr(kAudioDevicePropertyDeviceIsAlive), into: &deviceListeners) { [weak self] in
            guard let self, !HAL.isAlive(d) else { return }
            self.scheduleReconcile(force: true, reload: false)
        }
        for s in HAL.streams(d, scope: out) {
            addListener(s, addr(kAudioStreamPropertyVirtualFormat), into: &deviceListeners) { [weak self] in
                self?.event("device event: stream format changed")
                self?.scheduleReconcile(force: false, reload: false)
            }
        }
    }

    private func addListener(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress,
                             into list: inout [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)],
                             _ body: @escaping () -> Void) {
        var a = a
        let blk: AudioObjectPropertyListenerBlock = { _, _ in body() }
        if AudioObjectAddPropertyListenerBlock(obj, &a, queue, blk) == noErr { list.append((obj, a, blk)) }
    }

    private func removeListeners(_ list: inout [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]) {
        for (obj, a, blk) in list {
            var a = a
            AudioObjectRemovePropertyListenerBlock(obj, &a, queue, blk)
        }
        list.removeAll()
    }

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.event("system will sleep: releasing device")
                self.sleeping = true
                self.teardown(reason: "sleep")
            }
        })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.event("system woke: rebuilding")
                self.sleeping = false
                self.scheduleReconcile(force: true, reload: true, delay: 1.0)
            }
        })
    }

    /// Rebuild if IO callbacks stop (device vanished without a notification, aggregate died, ...).
    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, let e = self.engine, e.isRunning else { return }
            let cb = self.stats.load(.callbacks)
            if cb == self.lastCallbacks { self.stalledTicks += 1 } else { self.stalledTicks = 0 }
            self.lastCallbacks = cb
            if self.stalledTicks >= 3 {
                self.stalledTicks = 0
                self.event("watchdog: no IO callbacks for 3 s, rebuilding")
                self.scheduleReconcile(force: true, reload: false, delay: 0)
            }
        }
        t.resume()
        watchdog = t
    }

    // MARK: helpers

    private func setStatus(_ f: (inout Status) -> Void) {
        statusLock.lock()
        let before = _status
        f(&_status)
        let after = _status
        statusLock.unlock()
        if before != after, let cb = onStatusChange {
            DispatchQueue.main.async { cb(after) }
        }
    }

    private func event(_ s: String) { onEvent?(s) }
}
