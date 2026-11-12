import AppKit
import EQApeCore
import SwiftUI
import UniformTypeIdentifiers

/// Editor, settings and first-run windows (AppKit windows hosting SwiftUI, so they work from a menu bar app and can
/// be opened at launch).
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private(set) var editorWindow: NSWindow?
    private(set) var editorModel: EditorModel?
    private(set) var settingsWindow: NSWindow?
    private(set) var firstRunWindow: NSWindow?

    /// Open the editor on `path`, or on the current device's config, or ask for a file.
    func openEditor(path: String?) {
        let app = AppModel.shared
        var target = path ?? app.status.configPath ?? app.currentProfile?.configPath
        if target == nil {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.title = "Open an Equalizer APO config file"
            panel.allowedContentTypes = [.plainText, .text]
            panel.allowsOtherFileTypes = true
            guard panel.runModal() == .OK, let u = panel.url else { return }
            target = u.path
        }
        guard let p = target else { return }
        let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
        if let w = editorWindow, let m = editorModel, m.rootURL == url {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        closeEditor()
        let session: ConfigEditSession
        do {
            session = try ConfigEditSession(rootURL: url, backups: EditorBackups(baseDirectory: app.backupDirectory))
        } catch {
            let a = NSAlert()
            a.messageText = "Could not open \(url.lastPathComponent)"
            a.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            return
        }
        session.startWatching()
        let model = EditorModel(session: session, app: app)
        let w = makeWindow(title: "EQ Ape Editor — \(url.lastPathComponent)", autosave: "EQApeEditor",
                           size: NSSize(width: 1180, height: 780), minSize: NSSize(width: 960, height: 600),
                           view: EditorView(model: model, app: app))
        editorWindow = w
        editorModel = model
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func flushEditor() { editorModel?.session.flush() }

    func closeEditor() {
        editorModel?.session.flush()
        editorModel?.session.stopWatching()
        editorWindow?.delegate = nil
        editorWindow?.close()
        editorWindow = nil
        editorModel = nil
    }

    func openSettings() {
        if let w = settingsWindow { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        AppModel.shared.refreshDevices()
        let w = makeWindow(title: "EQ Ape Settings", autosave: "EQApeSettings", size: NSSize(width: 680, height: 620),
                           minSize: NSSize(width: 620, height: 420), view: SettingsView(app: AppModel.shared))
        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func closeSettings() { settingsWindow?.close() }
    func closeFirstRun() { firstRunWindow?.close() }

    func openFirstRun() {
        if let w = firstRunWindow { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let w = makeWindow(title: "Welcome to EQ Ape", autosave: nil, size: NSSize(width: 520, height: 300), minSize: nil,
                           view: FirstRunView(app: AppModel.shared, close: { [weak self] in
                               self?.firstRunWindow?.close(); self?.firstRunWindow = nil }),
                           resizable: false)
        firstRunWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<V: View>(title: String, autosave: String?, size: NSSize, minSize: NSSize?, view: V,
                                     resizable: Bool = true) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        let host = NSHostingController(rootView: view)
        // No automatic sizing: `.preferredContentSize` let NSHostingController re-measure the SwiftUI view inside the
        // window's constraint pass, which can throw AppKit's "needs update constraints" exception and crash the app
        // (found by the UI-test suite opening the first-run window, 2026-11-12). A fixed-size window is measured once.
        host.sizingOptions = []
        w.contentViewController = host
        w.title = title
        w.isReleasedWhenClosed = false
        w.delegate = self
        if let m = minSize { w.contentMinSize = m }
        if resizable {
            w.setContentSize(size)
        } else {
            let fit = host.view.fittingSize
            w.setContentSize(NSSize(width: max(size.width, fit.width), height: fit.height > 1 ? fit.height : size.height))
        }
        // UI-test runs never write window frames to the shared org.eqape.EQApe user defaults.
        if let name = autosave, !LaunchOptions.current.uiTest {
            if !w.setFrameUsingName(name) { w.center() }
            w.setFrameAutosaveName(name)   // remembers size and position
        } else {
            w.center()
        }
        return w
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === editorWindow {
            editorModel?.session.flush()
            editorModel?.session.stopWatching()
            editorWindow = nil
            editorModel = nil
        } else if w === settingsWindow {
            settingsWindow = nil
        } else if w === firstRunWindow {
            firstRunWindow = nil
        }
    }
}
