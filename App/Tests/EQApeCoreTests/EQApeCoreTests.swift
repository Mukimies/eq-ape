import EQCore
import Foundation
import TapKit
import XCTest
@testable import EQApeCore

final class EQApeCoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("EQApeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ name: String, _ text: String) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try text.write(to: u, atomically: false, encoding: .utf8)
        return u
    }

    // MARK: settings

    func testSettingsRoundTrip() throws {
        let store = SettingsStore(fileURL: dir.appendingPathComponent("sub/settings.json"))
        XCTAssertEqual(try store.load(), Settings(), "missing file -> defaults")
        var s = Settings()
        s.enabled = false
        s.profiles["UID-A"] = DeviceProfile(deviceName: "Scarlett", enabled: true, configPath: "/x/config.txt", headroomEnabled: true, headroomDB: 1.5)
        s.profiles["UID-B"] = DeviceProfile(deviceName: "Speakers", enabled: false, configPath: nil, headroomEnabled: false)
        try store.save(s)
        XCTAssertEqual(try store.load(), s)
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(json.contains("\"configPath\" : \"/x/config.txt\""))
    }

    func testSettingsTolerantDecode() throws {
        let u = try write("settings.json", #"{"profiles": {"U1": {"configPath": "/a.txt"}}}"#)
        let s = try SettingsStore(fileURL: u).load()
        XCTAssertTrue(s.enabled)
        let p = try XCTUnwrap(s.profiles["U1"])
        XCTAssertTrue(p.enabled)
        XCTAssertTrue(p.headroomEnabled)
        XCTAssertEqual(p.headroomDB, 0.5)
        XCTAssertEqual(p.effectiveHeadroomDB, 0.5)
    }

    func testCorruptSettingsThrowsAndIsNotOverwritten() throws {
        let u = try write("settings.json", "{ not json")
        XCTAssertThrowsError(try SettingsStore(fileURL: u).load())
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "{ not json")
    }

    // MARK: profile selection

    func testDecision() {
        var s = Settings()
        XCTAssertEqual(Decision.decide(globalEnabled: true, deviceUID: nil, settings: s), .untouched(.noDevice))
        XCTAssertEqual(Decision.decide(globalEnabled: true, deviceUID: "X", settings: s), .untouched(.noProfile))
        s.profiles["X"] = DeviceProfile(deviceName: "X", enabled: true, configPath: nil)
        XCTAssertEqual(Decision.decide(globalEnabled: true, deviceUID: "X", settings: s), .untouched(.noConfig))
        s.profiles["X"]?.configPath = "  "
        XCTAssertEqual(Decision.decide(globalEnabled: true, deviceUID: "X", settings: s), .untouched(.noConfig))
        s.profiles["X"]?.configPath = "/c.txt"
        XCTAssertEqual(Decision.decide(globalEnabled: true, deviceUID: "X", settings: s), .process(configPath: "/c.txt", headroomDB: 0.5))
        s.profiles["X"]?.headroomEnabled = false
        XCTAssertEqual(Decision.decide(globalEnabled: true, deviceUID: "X", settings: s), .process(configPath: "/c.txt", headroomDB: nil))
        XCTAssertEqual(Decision.decide(globalEnabled: true, deviceUID: "Y", settings: s), .untouched(.noProfile), "profile of another device never applies")
        s.profiles["X"]?.enabled = false
        XCTAssertEqual(Decision.decide(globalEnabled: true, deviceUID: "X", settings: s), .untouched(.disabled))
        s.profiles["X"]?.enabled = true
        s.enabled = false
        XCTAssertEqual(Decision.decide(globalEnabled: true, deviceUID: "X", settings: s), .untouched(.off))
        s.enabled = true
        XCTAssertEqual(Decision.decide(globalEnabled: false, deviceUID: "X", settings: s), .untouched(.off))
        XCTAssertFalse(EngineState.noProfile.touchesAudio)
        XCTAssertTrue(EngineState.active.touchesAudio)
    }

    // MARK: config loading + fallback rules

    func testMissingConfigIsUnusable() {
        let l = ConfigLoader.load(path: dir.appendingPathComponent("nope.txt").path)
        XCTAssertNil(l.config)
        XCTAssertNotNil(l.problem)
        XCTAssertEqual(l.files.count, 1, "missing file is still watched so its creation is noticed")
    }

    func testConfigWithoutStagesIsUnusable() throws {
        let u = try write("c.txt", "# only a comment\nFilter 1: OFF PK Fc 100 Hz Gain 3 dB Q 1\nsomething odd\n")
        let l = ConfigLoader.load(path: u.path)
        XCTAssertNil(l.config)
        XCTAssertEqual(l.problem, "config has no filters")
        XCTAssertFalse(l.warnings.isEmpty, "warnings are kept even when unusable")
    }

    func testConfigWithIncludes() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub dir"), withIntermediateDirectories: true)
        _ = try write("sub dir/inner (x).txt", "Filter 1: ON PK Fc 1000 Hz Gain -3 dB Q 1\nInclude: ..\\missing.txt\n")
        let main = try write("config.txt", "Preamp: -2 dB\nInclude: sub dir\\inner (x).txt\nREW header line\n")
        let l = ConfigLoader.load(path: main.path)
        let c = try XCTUnwrap(l.config)
        XCTAssertEqual(c.left.count, 2)
        XCTAssertEqual(Set(l.files.map { $0.lastPathComponent }), ["config.txt", "inner (x).txt", "missing.txt"])
        XCTAssertTrue(l.warnings.contains { $0.contains("REW header line") })
        XCTAssertTrue(l.warnings.contains { $0.contains("not found") })
    }

    func testRealConfigIfPresent() throws {
        let path = ProcessInfo.processInfo.environment["EQAPE_REAL_CONFIG"] ?? ""
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let l = ConfigLoader.load(path: path)
        XCTAssertNotNil(l.config)
        XCTAssertEqual(l.files.count, 5)
    }

    // MARK: file watching

    func waitFor(_ exp: XCTestExpectation, _ t: TimeInterval) -> TimeInterval {
        let t0 = Date()
        wait(for: [exp], timeout: t)
        return Date().timeIntervalSince(t0)
    }

    func testFileWatchDetectsEditOfMainAndIncludedFile() throws {
        let inc = try write("inc.txt", "Filter 1: ON PK Fc 1000 Hz Gain -3 dB Q 1\n")
        let main = try write("config.txt", "Preamp: -2 dB\nInclude: inc.txt\n")
        let w = FileWatcher(interval: 0.1)
        var hits = 0
        var exp = expectation(description: "main edit")
        w.onChange = { hits += 1; exp.fulfill() }
        w.watch(ConfigLoader.load(path: main.path).files)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(hits, 0, "no callback for the baseline")
        try "Preamp: -5 dB\nInclude: inc.txt\n".write(to: main, atomically: false, encoding: .utf8)
        XCTAssertLessThan(waitFor(exp, 2), 1.0)

        exp = expectation(description: "include edit")
        try "Filter 1: ON PK Fc 1000 Hz Gain -6 dB Q 1\n".write(to: inc, atomically: false, encoding: .utf8)
        XCTAssertLessThan(waitFor(exp, 2), 1.0)

        exp = expectation(description: "atomic replace (rename over)")
        try "Preamp: -7 dB\nInclude: inc.txt\n".write(to: main, atomically: true, encoding: .utf8)
        XCTAssertLessThan(waitFor(exp, 2), 1.0)
        w.stop()
        XCTAssertEqual(hits, 3)
    }

    func testFileWatchNoticesFileAppearing() throws {
        let main = dir.appendingPathComponent("later.txt")
        let w = FileWatcher(interval: 0.1)
        let exp = expectation(description: "appears")
        w.onChange = { exp.fulfill() }
        w.watch([main])
        try "Preamp: -1 dB\n".write(to: main, atomically: true, encoding: .utf8)
        wait(for: [exp], timeout: 2)
        w.stop()
        XCTAssertNotNil(ConfigLoader.load(path: main.path).config)
    }

    // MARK: processor slot

    func testProcessorSlotSwap() {
        let slot = ProcessorSlot()
        let a = ProcessorBox(channels: 2, sampleRate: 48000, appliedGainDB: -1, object: nil) { _, _ in }
        let b = ProcessorBox(channels: 2, sampleRate: 48000, appliedGainDB: -2, object: nil) { _, _ in }
        XCTAssertNil(slot.swap(a))
        XCTAssertTrue(slot.current === a)
        let old = slot.swap(b)
        XCTAssertTrue(old === a, "old processor returned to be freed off the audio thread")
        weak var weakB = b
        XCTAssertTrue(slot.swap(nil) === b)
        XCTAssertNil(slot.current)
        _ = weakB
    }

    func testEQProcessorBoxAppliesHeadroom() {
        let cfg = EQConfig(left: [.biquad(BiquadSpec(kind: .peaking, freq: 1000, gainDB: 6, q: 1))],
                           right: [.biquad(BiquadSpec(kind: .peaking, freq: 1000, gainDB: 6, q: 1))])
        let eq = EQProcessor(config: cfg, sampleRate: 48000, channels: 2, headroomDB: 0.5, maxFrames: 512)
        let box = ProcessorBox(eq: eq, channels: 2, sampleRate: 48000)
        XCTAssertEqual(box.appliedGainDB, -6.5, accuracy: 0.05)
    }

    // MARK: controller without audio (no device -> untouched, never creates a tap)

    func testControllerUnknownDeviceStaysUntouched() throws {
        var s = Settings()
        s.profiles["no-such-uid"] = DeviceProfile(deviceName: "x", configPath: "/nonexistent.txt")
        let c = TapController(mode: .fixed("no-such-device-\(UUID().uuidString)"), store: nil, ephemeral: s)
        c.start()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(c.status.state, .noDevice)
        c.shutdown()
    }

    // MARK: settings.json watching (controller never started: no engine)

    func testSettingsFileChangesAreReloadedAndReadOnlyIsHonoured() throws {
        let u = dir.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: u)
        try store.save(Settings(profiles: ["U1": DeviceProfile(deviceName: "A", configPath: "/a.txt")]))
        let c = TapController(mode: .fixed("no-such-device"), store: store)
        var seen: [Settings] = []
        let exp = expectation(description: "reloaded")
        exp.assertForOverFulfill = false   // own changes notify too
        c.onSettingsChange = { s in seen.append(s); exp.fulfill() }
        c.watchSettingsFile(interval: 0.1)
        Thread.sleep(forTimeInterval: 0.3)
        try #"{"enabled": false, "profiles": {"U1": {"deviceName": "A", "configPath": "/b.txt", "headroomDB": 2}}}"#
            .write(to: u, atomically: true, encoding: .utf8)
        wait(for: [exp], timeout: 3)
        XCTAssertEqual(c.currentSettings.profiles["U1"]?.configPath, "/b.txt")
        XCTAssertFalse(c.currentSettings.enabled)
        XCTAssertEqual(seen.last?.profiles["U1"]?.headroomDB, 2)
        // read-only: changes stay in memory, the file is not written
        c.settingsReadOnly = true
        let before = try Data(contentsOf: u)
        c.setProfile(uid: "U2", DeviceProfile(deviceName: "B"))
        XCTAssertNotNil(c.currentSettings.profiles["U2"])
        XCTAssertEqual(try Data(contentsOf: u), before)
        c.settingsReadOnly = false
        c.setProfile(uid: "U2", nil)
        _ = c.currentSettings   // drains the control queue
        XCTAssertNil(try store.load().profiles["U2"])
        XCTAssertNotEqual(try Data(contentsOf: u), before, "written when not read-only")
        c.shutdown()
        XCTAssertEqual(c.status.abBypass, false)
    }
}
