import AppKit
import ServiceManagement
import SwiftUI
import EQApeCore
import TapKit
import UniformTypeIdentifiers

/// Observable bridge between the controller (control queue) and SwiftUI (main thread).
@MainActor
final class AppModel: ObservableObject {
    let controller: TapController
    @Published var status = TapController.Status()
    @Published var enabled = true
    @Published var inputDB: Double = -.infinity
    @Published var outputDB: Double = -.infinity
    @Published var clipped: UInt64 = 0
    @Published var clipRecently = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var meterTimer: Timer?
    private var lastClipped: UInt64 = 0
    private var clipHold = 0

    init() {
        controller = TapController(mode: .followDefault, store: SettingsStore())
        enabled = controller.currentSettings.enabled
        status = controller.status
        controller.onStatusChange = { [weak self] st in
            MainActor.assumeIsolated { self?.status = st }
        }
        controller.start()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [controller] _ in
            controller.shutdown()
        }
    }

    private func tick() {
        let m = controller.takeMeter()
        inputDB = TapController.Meter.dB(m.inputPeak)
        outputDB = TapController.Meter.dB(m.outputPeak)
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

    func chooseConfig() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose an Equalizer APO config file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text, UTType(filenameExtension: "txt") ?? .plainText]
        panel.allowsOtherFileTypes = true
        if let p = status.configPath { panel.directoryURL = URL(fileURLWithPath: p).deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url {
            controller.chooseConfig(path: url.path)
        }
    }

    func openConfigInEditor() {
        guard let p = status.configPath else { return }
        let url = URL(fileURLWithPath: p)
        // Plain-text editor (TextEdit by default) rather than whatever owns .txt for viewing.
        NSWorkspace.shared.open(url)
    }

    func openSettingsFolder() {
        let dir = SettingsStore.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func setLaunchAtLogin(_ on: Bool) {
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

    func showWarnings() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "\(status.warnings.count) config warning(s)"
        a.informativeText = "Lines that were not converted (REW header lines are expected here):"
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        text.string = status.warnings.joined(separator: "\n")
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        a.accessoryView = scroll
        a.runModal()
    }
}

struct EQApeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.status.state == EngineState.active ? "slider.vertical.3" : "slider.horizontal.below.rectangle")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon even without LSUIElement
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    private func fmt(_ db: Double) -> String { db.isFinite ? String(format: "%.1f", db) : "-inf" }

    var body: some View {
        let st = model.status
        Toggle("EQ Ape On", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
        Divider()
        Text("Output: \(st.deviceName ?? "none")")
        Text("State: \(st.state.label)")
        if let p = st.configPath { Text("Config: \(URL(fileURLWithPath: p).lastPathComponent)") }
        if st.state == EngineState.active {
            Text("Level in \(fmt(model.inputDB)) / out \(fmt(model.outputDB)) dBFS")
            Text(model.clipRecently ? "CLIPPING (\(model.clipped) samples total)" : "No clipping (\(model.clipped) total)")
            if let g = st.appliedGainDB { Text(String(format: "Anti-clipping gain %.2f dB", g)) }
        }
        if let e = st.settingsError { Text(e) }
        Divider()
        Button("Choose Config File…") { model.chooseConfig() }
            .disabled(st.deviceUID == nil)
        Button("Open Config in Editor") { model.openConfigInEditor() }
            .disabled(st.configPath == nil)
        Button("Reload") { model.controller.reload() }
        if let p = st.profile {
            Toggle("Anti-Clipping Gain", isOn: Binding(get: { p.headroomEnabled },
                                                       set: { model.controller.setHeadroomForCurrentDevice(enabled: $0) }))
            Button("Remove Profile for This Device") { model.controller.removeProfileForCurrentDevice() }
        }
        if !st.warnings.isEmpty {
            Button("Show \(st.warnings.count) Config Warning(s)…") { model.showWarnings() }
        }
        Divider()
        Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Button("Open Settings Folder") { model.openSettingsFolder() }
        Divider()
        Button("Quit EQ Ape") {
            model.controller.shutdown()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
