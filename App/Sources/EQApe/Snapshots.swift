import AppKit
import EQApeCore
import EQCore
import SwiftUI
import TapKit

/// `--render-snapshots <dir>`: renders the editor, the band editor, the warnings list, Settings and the first-run
/// window offscreen (NSHostingView in a borderless window that is never shown) and writes PNG files. No engine, no
/// taps, nothing on screen. Configs: the real-config copy given in `EQAPE_SNAPSHOT_REAL` (a scratch copy with neutral
/// file names), plus generated examples written to a temporary folder. Backups go to that temporary folder too.
@MainActor
enum SnapshotRenderer {
    static func run(outputDirectory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("EQApe-snapshots-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = NSHomeDirectory()

        // generated example configs (neutral names)
        let stereo = tmp.appendingPathComponent("stereo-example.txt")
        try? """
        # Different correction for the left and right speaker
        Preamp: -4 dB
        Channel: L
        Filter 1: ON PK Fc 120 Hz Gain -6 dB Q 4
        Filter 2: ON HSC Fc 8000 Hz Gain 2 dB
        Channel: R
        Filter 3: ON PK Fc 95 Hz Gain -4.5 dB Q 3
        Filter 4: ON LSC Fc 80 Hz Gain 3 dB
        Channel: ALL
        Filter 5: ON PK Fc 3000 Hz Gain -2 dB Q 1.5

        """.write(to: stereo, atomically: true, encoding: .utf8)
        let rew = tmp.appendingPathComponent("rew-export.txt")
        try? ("Filter Settings file\r\n\r\nRoom EQ V5.31.3\r\nDated: 01.01.2026 12:00:00\r\n\r\nNotes:\r\n\r\nEqualiser: Generic\r\nExample speaker\r\n"
              + "Filter  1: ON  PK       Fc   58.0 Hz  Gain -7.50 dB  Q 4.100\r\n"
              + "Filter  2: ON  PK       Fc   112.0 Hz  Gain -9.20 dB  Q 6.000\r\n"
              + "# Filter: ON PK Fc 163 Hz Gain -5.1 dB Q 2.2\r\n# Filter: ON PK Fc 240 Hz Gain 3.4 dB Q 4.5\r\n"
              + "# Filter: ON PK Fc 410 Hz Gain -6 dB Q 7\r\n# Filter: ON PK Fc 1150 Hz Gain -4.2 dB Q 3.3\r\n"
              + "Filter  3: OFF PK       Fc   2600 Hz  Gain -3.00 dB  Q 2.000\r\n"
              + "Filter  4: ON  None      \r\nFilter  5: ON  None      \r\nPreamp: -2 dB\r\n").write(to: rew, atomically: true, encoding: .utf8)

        var opts = LaunchOptions.current
        opts.backupDir = tmp.appendingPathComponent("Backups").path
        let realPath = ProcessInfo.processInfo.environment["EQAPE_SNAPSHOT_REAL"]

        func preview(configPath: String?) -> AppModel {
            var st = TapController.Status()
            st.state = .active
            st.deviceName = "Scarlett Solo USB"
            st.deviceUID = "uid-interface"
            st.configPath = configPath
            st.sampleRate = 48000
            st.channels = 2
            var s = AppSettings()
            s.profiles["uid-interface"] = DeviceProfile(deviceName: "Scarlett Solo USB", configPath: configPath)
            let m = AppModel(options: opts, preview: (st, s))
            m.inputDB = -17.2; m.inputHoldDB = -14.9
            m.outputDB = -27.8; m.outputHoldDB = -26.1
            if let p = configPath, let c = ConfigLoader.load(path: p).config {
                var o = ResponsePlot.Options(); o.sampleRate = 48000
                m.status.appliedGainDB = ResponsePlot.antiClipGain(c, headroomDB: 0.5, sampleRate: 48000)
            }
            return m
        }

        func editor(_ path: String, app: AppModel, display: String, select: ((EditorModel) -> LineRef?)? = nil) -> EditorModel? {
            guard let s = try? ConfigEditSession(rootURL: URL(fileURLWithPath: path),
                                                 backups: EditorBackups(baseDirectory: tmp.appendingPathComponent("Backups"))) else {
                print("snapshot: cannot open \(path)"); return nil
            }
            let m = EditorModel(session: s, app: app)
            m.displayPathOverride = display
            m.selection = select?(m)
            return m
        }

        func firstFilter(_ m: EditorModel, freq: Double) -> LineRef? {
            for sec in m.sections { for r in sec.rows { if case .command(.filter(let f)) = r.kind, f.freq == freq { return r.ref } } }
            return nil
        }

        let size = NSSize(width: 1180, height: 800)
        if let real = realPath {
            let app = preview(configPath: real)
            if let m = editor(real, app: app, display: "~/EQ/config.txt", select: { firstFilter($0, freq: 118) }) {
                render(EditorView(model: m, app: app), size: size, dark: false, to: out.appendingPathComponent("editor-real-light.png"))
                render(EditorView(model: m, app: app), size: size, dark: true, to: out.appendingPathComponent("editor-real-dark.png"))
                printCurve(m)
                // the anti-clipping gain included in the curve, no selection
                m.showAntiClip = true; m.selection = nil
                render(EditorView(model: m, app: app), size: size, dark: false, to: out.appendingPathComponent("editor-real-anticlip.png"))
                m.showAntiClip = false
                render(WarningsList(model: m, dismiss: {}).background(Color(nsColor: .windowBackgroundColor)),
                       size: NSSize(width: 560, height: 360), dark: false, to: out.appendingPathComponent("warnings.png"))
                // the GraphicEQ band editor on the first GraphicEQ line
                if let geq = m.sections.flatMap({ $0.rows }).first(where: { if case .command(.graphicEQ) = $0.kind { return true }; return false }) {
                    render(GraphicEQEditor(model: m, ref: geq.ref).background(Color(nsColor: .windowBackgroundColor)),
                           size: NSSize(width: 1080, height: 470), dark: false, to: out.appendingPathComponent("graphiceq-editor-light.png"))
                    render(GraphicEQEditor(model: m, ref: geq.ref).background(Color(nsColor: .windowBackgroundColor)),
                           size: NSSize(width: 1080, height: 470), dark: true, to: out.appendingPathComponent("graphiceq-editor-dark.png"))
                }
            }
            // the real --no-engine state of the status strip (device list read-only, no engine)
            var ne = LaunchOptions.current; ne.noEngine = true; ne.backupDir = opts.backupDir
            let noEngine = AppModel(options: ne)
            if let m = editor(real, app: noEngine, display: "~/EQ/config.txt") {
                render(EditorView(model: m, app: noEngine), size: size, dark: false, to: out.appendingPathComponent("editor-no-engine.png"))
            }
            noEngine.controller.shutdown()
        } else {
            print("snapshot: EQAPE_SNAPSHOT_REAL not set; skipping the real-config views")
        }
        let appS = preview(configPath: nil)
        if let m = editor(stereo.path, app: appS, display: "~/EQ/stereo-example.txt", select: { firstFilter($0, freq: 95) }) {
            render(EditorView(model: m, app: appS), size: size, dark: false, to: out.appendingPathComponent("editor-stereo-light.png"))
            render(EditorView(model: m, app: appS), size: size, dark: true, to: out.appendingPathComponent("editor-stereo-dark.png"))
        }
        if let m = editor(rew.path, app: appS, display: "~/EQ/rew-export.txt", select: { firstFilter($0, freq: 112) }) {
            render(EditorView(model: m, app: appS), size: size, dark: false, to: out.appendingPathComponent("editor-commented-light.png"))
        }

        // Settings and first run with neutral sample profiles
        var st = TapController.Status()
        st.state = .active; st.deviceName = "Scarlett Solo USB"; st.deviceUID = "uid-interface"
        var s = AppSettings()
        s.profiles["uid-interface"] = DeviceProfile(deviceName: "Scarlett Solo USB", configPath: home + "/EQ/config.txt")
        s.profiles["uid-speakers"] = DeviceProfile(deviceName: "MacBook Pro Speakers", enabled: false,
                                                   configPath: home + "/EQ/laptop.txt", headroomEnabled: false)
        let appSet = AppModel(options: opts, preview: (st, s))
        appSet.currentDevices = ["uid-interface": "Scarlett Solo USB", "uid-speakers": "MacBook Pro Speakers"]
        render(SettingsView(app: appSet).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 680, height: 640),
               dark: false, to: out.appendingPathComponent("settings-light.png"))
        render(SettingsView(app: appSet).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 680, height: 640),
               dark: true, to: out.appendingPathComponent("settings-dark.png"))
        render(FirstRunView(app: appSet, close: {}).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 520, height: 290),
               dark: false, to: out.appendingPathComponent("first-run-light.png"))
        exit(0)
    }

    static func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.backgroundColor = .windowBackgroundColor
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        host.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("snapshot: no bitmap for \(url.lastPathComponent)"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            print("snapshot: wrote \(url.lastPathComponent) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        }
        win.contentView = nil
    }

    /// Plotted values at a few frequencies (for checking the rendered curve against EQCore).
    static func printCurve(_ m: EditorModel) {
        var o = m.plotOptions; o.includeAntiClip = false; o.includePreamp = true
        let p = ResponsePlot(config: m.evaluation.result.config, options: o)
        var noHP = m.evaluation.result.config
        noHP.left.removeAll { if case .biquad(let b) = $0 { return b.kind == .highPass }; return false }
        let q = ResponsePlot(config: noHP, options: o)
        let fs: [Double] = [20, 30, 40, 63, 100, 118, 200, 500, 1000, 10000, 20000]
        print("snapshot: plotted curve (preamp included, anti-clip excluded) " +
              fs.map { String(format: "%@ %+.2f dB", GraphFormat.freq($0), p.value(p.left, at: $0)) }.joined(separator: ", "))
        print(String(format: "snapshot: without the high-pass at 20 Hz %+.2f dB; peak %+.2f dB at %.1f Hz; anti-clip %.2f dB",
                     q.value(q.left, at: 20), p.peakLeft.dB, p.peakLeft.freq, p.antiClipDB))
    }
}
