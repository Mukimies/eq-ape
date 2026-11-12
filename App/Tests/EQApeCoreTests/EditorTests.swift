import EQCore
import Foundation
import XCTest
@testable import EQApeCore

final class EditorTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("EQApeEditor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func put(_ name: String, _ text: String) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        return u
    }

    /// Spin the main run loop until `cond` or timeout.
    func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return cond()
    }

    static let bass1 = "GraphicEQ: 20 6.2; 25 6.2; 31.5 6.2; 40 6.2; 50 0; 63 0; 80 0; 100 0; 125 0; 160 0; 200 0; 250 0; 315 0; 400 0; 500 0; 630 0; 800 0; 1000 0; 1250 0; 1600 0; 2000 0; 2500 0; 3150 0; 4000 0; 5000 0; 6300 0; 8000 0; 10000 0; 12500 0; 16000 0; 20000 0"
    static let bass2 = "GraphicEQ: 20 5; 25 5; 31.5 5; 40 5; 50 5; 63 5; 80 5; 100 0; 125 0; 160 0; 200 0; 250 0; 315 0; 400 0; 500 0; 630 0; 800 0; 1000 0; 1250 0; 1600 0; 2000 0; 2500 0; 3150 0; 4000 0; 5000 0; 6300 0; 8000 0; 10000 0; 12500 0; 16000 0; 20000 0"

    /// Same structure as the real-world config used during development (master file with four Includes).
    func makeRealLikeConfig() throws -> URL {
        try put("room-correction.txt", "Filter Settings file\r\n\r\nRoom EQ V5.31.3\r\nNotes:\r\nFilter: ON PK Fc 60.8 Hz Gain -8.5 dB Q 3.634\r\nFilter  2: ON  PK       Fc   118.0 Hz  Gain -14.80 dB  Q 10.339\r\n# Filter: ON PK Fc 167.5 Hz Gain -8.6 dB Q 1.137\r\nFilter  1: ON  None      \r\nPreamp: -1 dB\r\n")
        try put("bass-boost-1.txt", EditorTests.bass1 + "\n")
        try put("bass-boost-2.txt", EditorTests.bass2 + "\n")
        try put("subsonic-highpass.txt", "# 4th-order Butterworth high-pass at 30 Hz\nFilter 1: ON HPQ Fc 30 Hz Q 0.5412\nFilter 2: ON HPQ Fc 30 Hz Q 1.3066\n")
        return try put("config.txt", "# Master file\nInclude: room-correction.txt\nInclude: bass-boost-1.txt\nInclude: bass-boost-2.txt\nInclude: subsonic-highpass.txt\n")
    }

    // MARK: backups

    func testBackupCreationAndPruning() throws {
        let base = dir.appendingPathComponent("Backups")
        // 22 old sessions plus an unrelated folder that must survive pruning
        for i in 0..<22 {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(String(format: "2026-01-%02d_10-00-00", i + 1)), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("keep me"), withIntermediateDirectories: true)
        let a = try put("a/config.txt", "Preamp: -1 dB\n")
        let b = try put("b/config.txt", "Preamp: -2 dB\n")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let backups = EditorBackups(baseDirectory: base, keep: 20, now: { clock })
        XCTAssertNil(backups.sessionDirectory, "no folder before the first write")
        let copyA = try XCTUnwrap(try backups.backupIfNeeded(a))
        let copyB = try XCTUnwrap(try backups.backupIfNeeded(b))
        try "Preamp: -9 dB\n".write(to: a, atomically: false, encoding: .utf8)
        XCTAssertEqual(try backups.backupIfNeeded(a), copyA, "only the first write of a session is backed up")
        XCTAssertEqual(try String(contentsOf: copyA, encoding: .utf8), "Preamp: -1 dB\n")
        XCTAssertEqual(copyB.lastPathComponent, "config (2).txt", "same file name from another folder")
        let manifest = try String(contentsOf: backups.sessionDirectory!.appendingPathComponent("manifest.txt"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(a.standardizedFileURL.path) && manifest.contains(b.standardizedFileURL.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(names.filter(EditorBackups.isSessionName).count, 20)
        XCTAssertTrue(names.contains("keep me"))
        XCTAssertFalse(names.contains("2026-01-01_10-00-00"), "oldest pruned")
        XCTAssertTrue(names.contains(backups.sessionDirectory!.lastPathComponent), "current session kept")
        // a second session in the same second gets its own folder
        let again = EditorBackups(baseDirectory: base, keep: 20, now: { clock })
        try again.backupIfNeeded(a)
        XCTAssertTrue(again.sessionDirectory!.lastPathComponent.hasSuffix("-2"))
        clock += 1
    }

    // MARK: live-saving session

    func testEditIsWrittenAfterDebounceWithBackup() throws {
        let main = try makeRealLikeConfig()
        let room = dir.appendingPathComponent("room-correction.txt").standardizedFileURL
        let originalRoom = try Data(contentsOf: room)
        let backups = EditorBackups(baseDirectory: dir.appendingPathComponent("Backups"))
        let s = try ConfigEditSession(rootURL: main, backups: backups)
        XCTAssertEqual(s.workspace.documents.count, 5)
        var changes = 0
        s.onChange = { changes += 1 }
        let t0 = Date()
        XCTAssertTrue(s.edit(room, name: "Gain") { doc in
            guard case .command(.filter(var f)) = doc.lines[5].kind else { return }
            f.gainDB = -10
            try doc.setCommand(.filter(f), at: 5)
        })
        XCTAssertEqual(try Data(contentsOf: room), originalRoom, "not written synchronously")
        XCTAssertTrue(waitUntil(2) { s.pending.isEmpty })
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
        let written = try String(contentsOf: room, encoding: .utf8)
        XCTAssertEqual(written, String(decoding: originalRoom, as: UTF8.self)
            .replacingOccurrences(of: "Filter  2: ON  PK       Fc   118.0 Hz  Gain -14.80 dB  Q 10.339", with: "Filter 2: ON PK Fc 118 Hz Gain -10 dB Q 10.339"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.sessionDirectory).appendingPathComponent("room-correction.txt")), originalRoom)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(s.writeCount, 1)
        // the other files were not touched
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8).hasPrefix("# Master file"), true)
        // undo writes the original bytes back; revert too
        s.undo(); s.flush()
        XCTAssertEqual(try Data(contentsOf: room), originalRoom)
        s.redo(); s.flush()
        XCTAssertNotEqual(try Data(contentsOf: room), originalRoom)
        s.revertToVersionAtOpen(); s.flush()
        XCTAssertEqual(try Data(contentsOf: room), originalRoom)
    }

    func testDragCoalescesAndDebouncesWrites() throws {
        let main = try put("c.txt", "Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1\n")
        let s = try ConfigEditSession(rootURL: main, backups: EditorBackups(baseDirectory: dir.appendingPathComponent("B")))
        for i in 1...20 {
            s.edit(main, name: "Drag", coalesceKey: "drag") { try $0.setCommand(.filter(FilterLine(label: " 1", type: "PK", freq: 100 + Double(i), gainDB: 0, q: 1)), at: 0) }
        }
        s.endCoalescing()
        XCTAssertTrue(waitUntil(2) { s.pending.isEmpty })
        XCTAssertEqual(s.writeCount, 1, "edits within the debounce window give one write")
        XCTAssertEqual(s.workspace.undoStack.count, 1)
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), "Filter 1: ON PK Fc 120 Hz Gain 0 dB Q 1\n")
    }

    func testExternalChangeIsReloaded() throws {
        let main = try put("c.txt", "Preamp: -1 dB\n")
        let s = try ConfigEditSession(rootURL: main, backups: EditorBackups(baseDirectory: dir.appendingPathComponent("B")))
        XCTAssertEqual(s.checkExternalChanges(), [], "own state is not an external change")
        try "Preamp: -7 dB\n".write(to: main, atomically: true, encoding: .utf8)
        XCTAssertEqual(s.checkExternalChanges(), [main.standardizedFileURL])
        XCTAssertEqual(s.workspace.root.lines[0].kind, .command(.preamp(dB: -7)))
        // our own write is not reported as external
        s.edit(main) { try $0.setCommand(.preamp(dB: -2), at: 0) }
        s.flush()
        XCTAssertEqual(s.checkExternalChanges(), [])
        // conflict: pending edit + external change -> the callback decides
        s.saveDelay = 10
        s.edit(main) { try $0.setCommand(.preamp(dB: -3), at: 0) }
        try "Preamp: -8 dB\n".write(to: main, atomically: true, encoding: .utf8)
        var asked = 0
        s.onConflict = { _ in asked += 1; return false }
        XCTAssertEqual(s.checkExternalChanges(), [])
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(s.workspace.root.lines[0].kind, .command(.preamp(dB: -3)), "kept the edit")
        s.flush()
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), "Preamp: -3 dB\n")
    }

    /// Live save picked up by the engine's own loader and watcher (no engine, no audio).
    func testLiveSaveIsPickedUpByConfigLoaderAndFileWatcher() throws {
        let main = try makeRealLikeConfig()
        let watcher = FileWatcher(interval: 0.1)
        var fired = 0
        let exp = expectation(description: "watcher fired")
        watcher.onChange = { fired += 1; exp.fulfill() }
        let before = ConfigLoader.load(path: main.path)
        XCTAssertEqual(before.files.count, 5)
        watcher.watch(before.files)
        Thread.sleep(forTimeInterval: 0.3)

        let s = try ConfigEditSession(rootURL: main, backups: EditorBackups(baseDirectory: dir.appendingPathComponent("B")))
        let hp = dir.appendingPathComponent("subsonic-highpass.txt").standardizedFileURL
        let t0 = Date()
        s.edit(hp, name: "Frequency") { doc in
            guard case .command(.filter(var f)) = doc.lines[1].kind else { return }
            f.freq = 25
            try doc.setCommand(.filter(f), at: 1)
        }
        wait(for: [exp], timeout: 3)
        let latency = Date().timeIntervalSince(t0)
        watcher.stop()
        XCTAssertLessThan(latency, 1.5)
        let after = ConfigLoader.load(path: main.path)
        let cfg = try XCTUnwrap(after.config)
        XCTAssertEqual(cfg.left.count, 7)
        XCTAssertEqual(cfg.left[5], .biquad(BiquadSpec(kind: .highPass, freq: 25, q: 0.5412)))
        XCTAssertEqual(cfg.left[6], .biquad(BiquadSpec(kind: .highPass, freq: 30, q: 1.3066)))
        XCTAssertEqual(cfg, s.workspace.evaluate().result.config, "engine's view equals the editor's view")
        XCTAssertEqual(fired, 1)
    }

    // MARK: plot

    func testPlotOfRealLikeConfigMatchesEQCore() throws {
        let main = try makeRealLikeConfig()
        let ws = try ConfigWorkspace(rootURL: main)
        let cfg = ws.evaluate().result.config
        var o = ResponsePlot.Options()
        o.includePreamp = true; o.includeAntiClip = false
        let plot = ResponsePlot(config: cfg, options: o)
        XCTAssertFalse(plot.channelsDiffer)
        func at(_ f: Double) -> Double { plot.value(plot.left, at: f) }
        XCTAssertEqual(at(20), -4.16, accuracy: 0.05)      // with the 4th-order 30 Hz high-pass
        XCTAssertEqual(at(40), 8.88, accuracy: 0.05)
        XCTAssertEqual(at(118), -16.15, accuracy: 0.1)
        for f in [250.0, 500, 1000, 5000, 15000] { XCTAssertEqual(at(f), -1.0, accuracy: 0.15, "\(f) Hz: only the -1 dB preamp") }
        // the early reference semantics ignore the high-pass (+10.09 dB at 20 Hz); anti-clipping no longer uses them
        XCTAssertEqual(Response.magnitudeDB(stages: cfg.left, freq: 20, sampleRate: 48000), 10.09, accuracy: 0.05)
        // full-chain peak (high-pass and the measured GraphicEQ FIR included): +8.91 dB near 39.5 Hz
        XCTAssertEqual(plot.peakLeft.dB, 8.91, accuracy: 0.02)
        XCTAssertEqual(plot.peakLeft.freq, 39.5, accuracy: 0.5)
        XCTAssertEqual(plot.antiClipDB, -0.5 - plot.peakLeft.dB, accuracy: 1e-9)
        XCTAssertEqual(plot.antiClipDB, -9.41, accuracy: 0.02)    // was -10.69 with the reference peak
        // the editor shows exactly the gain the processor applies
        let proc = EQProcessor(config: cfg, sampleRate: 48000, channels: 2, headroomDB: 0.5, maxFrames: 512)
        XCTAssertEqual(plot.antiClipDB, proc.appliedHeadroomGainDB, accuracy: 1e-12)
        XCTAssertEqual(ResponsePlot.antiClipGain(cfg, headroomDB: 0.5, sampleRate: 48000), proc.appliedHeadroomGainDB, accuracy: 1e-12)
        var o2 = o; o2.includePreamp = false
        XCTAssertEqual(ResponsePlot(config: cfg, options: o2).value(ResponsePlot(config: cfg, options: o2).left, at: 1000), 0, accuracy: 0.15)
        var o3 = o; o3.includeAntiClip = true
        let p3 = ResponsePlot(config: cfg, options: o3)
        XCTAssertEqual(p3.value(p3.left, at: 1000), -1.0 - 9.41, accuracy: 0.2)
        // left/right differ
        let lr = APOParser.parse(text: "Channel: L\nPreamp: -3 dB\nChannel: R\nFilter: ON PK Fc 1000 Hz Gain 6 dB Q 1\n", baseURL: nil).config
        let p = ResponsePlot(config: lr, options: o)
        XCTAssertTrue(p.channelsDiffer)
        XCTAssertEqual(p.value(p.left, at: 1000), -3, accuracy: 0.01)
        XCTAssertEqual(p.value(p.right, at: 1000), 6, accuracy: 0.05)
    }
}
