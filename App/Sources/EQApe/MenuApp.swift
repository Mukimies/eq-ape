import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI
import EQApeCore
import TapKit
import UniformTypeIdentifiers

/// The app's settings model (SwiftUI also has a `Settings` scene type).
typealias AppSettings = EQApeCore.Settings

/// Observable bridge between the controller (control queue) and SwiftUI (main thread).
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel(options: LaunchOptions.current)

    let options: LaunchOptions
    let controller: TapController
    /// True with `--no-engine`: no engine, no taps, no device I/O for the whole run.
    let engineDisabled: Bool
    /// Offscreen snapshot model with fake status (never registers, never touches the engine).
    let isPreview: Bool
    @Published var status = TapController.Status()
    @Published var settings = AppSettings()
    @Published var enabled = true
    @Published var inputDB: Double = -.infinity
    @Published var outputDB: Double = -.infinity
    /// Peak hold (about 1.5 s, then falls back to the current level).
    @Published var inputHoldDB: Double = -.infinity
    @Published var outputHoldDB: Double = -.infinity
    private var inputHoldAge = 0, outputHoldAge = 0
    @Published var clipped: UInt64 = 0
    @Published var clipRecently = false
    @Published var launchAtLogin = false
    /// Output devices seen right now (name by UID), read-only HAL queries.
    @Published var currentDevices: [String: String] = [:]
    private var meterTimer: Timer?
    private var lastClipped: UInt64 = 0
    private var clipHold = 0

    /// `preview` = a fixed, fake status for offscreen snapshots (never touches the controller's engine).
    init(options: LaunchOptions, preview: (TapController.Status, AppSettings)? = nil) {
        self.options = options
        engineDisabled = options.noEngine && preview == nil
        isPreview = preview != nil
        let store = SettingsStore(fileURL: options.settingsPath.map { URL(fileURLWithPath: $0) } ?? SettingsStore.defaultFileURL)
        controller = TapController(mode: .followDefault, store: preview == nil ? store : nil,
                                   ephemeral: preview?.1)
        // A development run without an explicit settings file never writes the real settings.json.
        controller.settingsReadOnly = options.noEngine && options.settingsPath == nil && preview == nil
        if let (st, s) = preview {
            status = st; settings = s; enabled = s.enabled
            return
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        settings = controller.currentSettings
        enabled = settings.enabled
        status = controller.status
        controller.onStatusChange = { [weak self] st in
            MainActor.assumeIsolated {
                self?.status = st
                self?.writeRegistry()
            }
        }
        controller.onEvent = { s in print("EQ Ape: \(s)"); fflush(stdout) }
        // Safety checks before any tap is created: the instance guard always (two taps on one device would process
        // the audio twice), the permission gate with --require-granted (no prompt may appear in unattended runs).
        let requireGranted = options.requireGranted
        controller.useDeviceLock = true
        controller.startGate = { dev, uid in
            let inputs = HAL.channels(dev, scope: kAudioObjectPropertyScopeInput) > 0
            let p = EngineGate.PermissionInputs(capture: PermissionCheck.capture(), microphone: PermissionCheck.microphone(),
                                                deviceHasInputs: inputs)
            if let r = EngineGate.permissionBlock(p, requireGranted: requireGranted) { return r }
            return EngineGate.instanceBlock(peers: InstanceRegistry.peers(), deviceUID: uid)
        }
        if requireGranted {
            print("EQ Ape: --require-granted: audio capture \(PermissionCheck.capture().rawValue), microphone \(PermissionCheck.microphone().rawValue)"
                  + " (no-prompt preflights for the responsible process); the engine starts only if no prompt can appear")
            fflush(stdout)
        }
        writeRegistry()
        controller.onSettingsChange = { [weak self] s in
            MainActor.assumeIsolated {
                self?.settings = s
                self?.enabled = s.enabled
            }
        }
        controller.watchSettingsFile()
        refreshDevices()
        if !engineDisabled {
            controller.start()
        } else {
            var st = controller.status
            st.state = .error("engine disabled (--no-engine)")
            if let d = HAL.defaultOutput() { st.deviceName = HAL.name(d); st.deviceUID = HAL.uid(d) }
            status = st
        }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private let started = Date()

    /// This process's entry in the instance registry (see `InstanceRegistry`): other EQ Ape processes read it to
    /// know whether this one may be processing a device.
    func writeRegistry() {
        guard !isPreview else { return }
        let st = status
        let engine = engineDisabled ? "off" : st.state.touchesAudio ? "active" : "following"
        InstanceRegistry.write(InstanceRegistry.Entry(pid: getpid(), executable: Bundle.main.executablePath ?? CommandLine.arguments[0],
                                                      engine: engine, deviceUID: st.state.touchesAudio ? st.deviceUID : nil,
                                                      deviceName: st.state.touchesAudio ? st.deviceName : nil,
                                                      uiTest: options.uiTest, started: started))
    }

    func refreshDevices() {
        var m: [String: String] = [:]
        for d in HAL.outputDevices() { if let uid = HAL.uid(d) { m[uid] = HAL.name(d) } }
        currentDevices = m
    }

    private func tick() {
        guard !engineDisabled else { return }
        let m = controller.takeMeter()
        inputDB = TapController.Meter.dB(m.inputPeak)
        outputDB = TapController.Meter.dB(m.outputPeak)
        func hold(_ v: Double, _ h: inout Double, _ age: inout Int) {
            if v >= h || age >= 6 { h = v; age = 0 } else { age += 1 }
        }
        hold(inputDB, &inputHoldDB, &inputHoldAge)
        hold(outputDB, &outputHoldDB, &outputHoldAge)
        if m.clippedSamples > lastClipped { clipHold = 8 }   // hold the clip light ~2 s
        lastClipped = m.clippedSamples
        clipped = m.clippedSamples
        if clipHold > 0 { clipHold -= 1 }
        clipRecently = clipHold > 0
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        controller.setEnabled(on)
    }

    func setBypass(_ on: Bool) {
        controller.setABBypass(on)
        status.abBypass = on   // optimistic; the controller confirms
    }

    /// The device's current profile, or nil.
    var currentProfile: DeviceProfile? { status.deviceUID.flatMap { settings.profiles[$0] } }

    func chooseConfig(forUID uid: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose an Equalizer APO config file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text, UTType(filenameExtension: "txt") ?? .plainText]
        panel.allowsOtherFileTypes = true
        let current = uid.flatMap { settings.profiles[$0]?.configPath } ?? status.configPath
        if let p = current { panel.directoryURL = URL(fileURLWithPath: p).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let uid, uid != status.deviceUID {
            var p = settings.profiles[uid] ?? DeviceProfile(deviceName: currentDevices[uid] ?? uid)
            p.configPath = url.path
            controller.setProfile(uid: uid, p)
        } else {
            controller.chooseConfig(path: url.path)
        }
    }

    /// UI-test runs (--ui-test-control) record what would be opened instead of opening Finder or System Settings.
    @Published var uiTestOpened: [String] = []

    @discardableResult
    private func open(_ url: URL) -> Bool {
        if options.uiTest { uiTestOpened.append(url.absoluteString); return true }
        return NSWorkspace.shared.open(url)
    }

    func openSettingsFolder() {
        let dir = SettingsStore.defaultDirectory
        if !options.uiTest { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        open(dir)
    }

    var backupDirectory: URL {
        options.backupDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? EditorBackups.defaultDirectory
    }

    func openBackupsFolder() {
        try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        open(backupDirectory)
    }

    func openPrivacySettings() {
        // System Settings > Privacy & Security, audio capture list ("Screen & System Audio Recording" on newer macOS)
        let urls = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]
        for s in urls { if let u = URL(string: s), open(u) { return } }
    }

    func setLaunchAtLogin(_ on: Bool) {
        // Never touch the login item from a UI-test run (the item is shared with the owner's installed app).
        if options.uiTest { uiTestOpened.append("launch-at-login refused (ui-test run)"); return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Could not change the login item"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Flush editor saves and stop the engine (quit, SIGTERM).
    func shutdown() {
        WindowManager.shared.flushEditor()
        controller.shutdown()
        if !isPreview { InstanceRegistry.remove() }
    }
}

struct EQApeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.status.state == EngineState.active ? "slider.vertical.3" : "slider.horizontal.below.rectangle")
                .accessibilityLabel("EQ Ape")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon even without LSUIElement
        MainActor.assumeIsolated {
            let model = AppModel.shared
            for sig in [SIGTERM, SIGINT, SIGHUP] {
                signal(sig, SIG_IGN)
                let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                src.setEventHandler {
                    print("EQ Ape: signal \(sig), shutting down")
                    MainActor.assumeIsolated { model.shutdown() }
                    exit(0)
                }
                src.resume()
                signalSources.append(src)
            }
            if let dir = model.options.uiTestControl { UITestControl.shared.start(dir: dir) }
            if let path = model.options.editorPath {
                WindowManager.shared.openEditor(path: path)
                if model.options.smokeTest { SmokeTest.start() }
            } else if model.settings.profiles.isEmpty && !FirstRun.completed && !model.engineDisabled {
                WindowManager.shared.openFirstRun()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let st = model.status
        Toggle("EQ Ape On", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
            .disabled(model.engineDisabled)
        Divider()
        Text("\(st.deviceName ?? "No output device"): \(model.engineDisabled ? "engine disabled (--no-engine)" : st.state.label)")
        Toggle("Bypass (A/B)", isOn: Binding(get: { st.abBypass }, set: { model.setBypass($0) }))
            .disabled(st.state != EngineState.active)
        if case .error = st.state, !model.engineDisabled {
            Button("Reload") { model.controller.reload() }   // clears "audio start blocked" after a permission prompt
        }
        Divider()
        Button("Open Editor…") { WindowManager.shared.openEditor(path: nil) }
            .keyboardShortcut("e")
        Button("Settings…") { WindowManager.shared.openSettings() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit EQ Ape") {
            model.shutdown()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

enum FirstRun {
    static let key = "firstRunCompleted"
    /// UI-test runs keep the flag in memory (never in the shared user defaults).
    nonisolated(unsafe) static var uiTestValue = false
    static var completed: Bool {
        get { LaunchOptions.current.uiTest ? uiTestValue : UserDefaults.standard.bool(forKey: key) }
        set { if LaunchOptions.current.uiTest { uiTestValue = newValue } else { UserDefaults.standard.set(newValue, forKey: key) } }
    }
}
