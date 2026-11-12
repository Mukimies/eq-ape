import Foundation
import XCTest
@testable import EQApeCore

final class EngineGateTests: XCTestCase {
    typealias P = EngineGate.PermissionInputs

    func testWithoutRequireGrantedNothingIsBlocked() {
        for c in [EngineGate.Capture.granted, .denied, .notDetermined, .unknown] {
            XCTAssertNil(EngineGate.permissionBlock(P(capture: c, microphone: .notDetermined, deviceHasInputs: true), requireGranted: false))
        }
    }

    func testRequireGrantedNeedsAudioCaptureGranted() {
        XCTAssertNil(EngineGate.permissionBlock(P(capture: .granted, microphone: .authorized, deviceHasInputs: true), requireGranted: true))
        for c in [EngineGate.Capture.denied, .notDetermined, .unknown] {
            let r = EngineGate.permissionBlock(P(capture: c, microphone: .authorized, deviceHasInputs: false), requireGranted: true)
            XCTAssertNotNil(r, "\(c)")
            XCTAssertTrue(r!.contains(c.rawValue))
        }
    }

    func testBlockedStartRetriesOnlyOnceAndOnlyWhenGranted() {
        XCTAssertEqual(EngineGate.blockedStartAction(permission: .notDetermined, autoRetried: false), .wait)
        XCTAssertEqual(EngineGate.blockedStartAction(permission: .unknown, autoRetried: false), .wait)
        XCTAssertEqual(EngineGate.blockedStartAction(permission: .granted, autoRetried: false), .retry)
        if case .giveUp = EngineGate.blockedStartAction(permission: .granted, autoRetried: true) {} else { XCTFail("second automatic retry") }
        if case .giveUp = EngineGate.blockedStartAction(permission: .denied, autoRetried: false) {} else { XCTFail("denied must not retry") }
    }

    func testMicrophoneStatusDoesNotGate() {
        // The engine disables device input streams; no Microphone prompt was observed with "not determined".
        for m in [EngineGate.Microphone.authorized, .denied, .restricted, .notDetermined, .unknown] {
            for inputs in [true, false] {
                XCTAssertNil(EngineGate.permissionBlock(P(capture: .granted, microphone: m, deviceHasInputs: inputs), requireGranted: true), "\(m)")
            }
        }
    }

    func entry(_ pid: Int32, _ engine: String, _ uid: String? = nil) -> InstanceRegistry.Entry {
        InstanceRegistry.Entry(pid: pid, executable: "/x/build-dev/EQ Ape.app/Contents/MacOS/EQApe", engine: engine, deviceUID: uid,
                               deviceName: uid.map { "Dev \($0)" }, uiTest: false, started: Date(timeIntervalSince1970: 0))
    }

    func testInstanceGuard() {
        XCTAssertNil(EngineGate.instanceBlock(peers: [], deviceUID: "A"))
        // an older build without a registry entry: assume it processes something
        XCTAssertNotNil(EngineGate.instanceBlock(peers: [.init(pid: 10, path: "/old/EQApe", entry: nil)], deviceUID: "A"))
        // an entry for a different pid (stale file, reused pid) counts as no entry
        XCTAssertNotNil(EngineGate.instanceBlock(peers: [.init(pid: 10, path: "/p", entry: entry(11, "off"))], deviceUID: "A"))
        // --no-engine peers never block
        XCTAssertNil(EngineGate.instanceBlock(peers: [.init(pid: 10, path: "/p", entry: entry(10, "off"))], deviceUID: "A"))
        // an active peer on another device does not block; on the same device it does
        XCTAssertNil(EngineGate.instanceBlock(peers: [.init(pid: 10, path: "/p", entry: entry(10, "active", "B"))], deviceUID: "A"))
        XCTAssertNotNil(EngineGate.instanceBlock(peers: [.init(pid: 10, path: "/p", entry: entry(10, "active", "A"))], deviceUID: "A"))
        // a peer that follows the default output may start on any device at any moment
        XCTAssertNotNil(EngineGate.instanceBlock(peers: [.init(pid: 10, path: "/p", entry: entry(10, "following"))], deviceUID: "A"))
    }

    func testRegistryRoundTripAndDeviceLock() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EQApeGate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = entry(getpid(), "active", "UID:1")
        InstanceRegistry.write(e, directory: dir)
        XCTAssertEqual(InstanceRegistry.read(pid: getpid(), directory: dir), e)
        InstanceRegistry.remove(pid: getpid(), directory: dir)
        XCTAssertNil(InstanceRegistry.read(pid: getpid(), directory: dir))
        // flock locks are per open file description: a second lock on the same device fails until the first is gone
        var first = InstanceRegistry.lockDevice("UID:1", directory: dir)
        XCTAssertNotNil(first)
        XCTAssertNil(InstanceRegistry.lockDevice("UID:1", directory: dir))
        XCTAssertNotNil(InstanceRegistry.lockDevice("UID:2", directory: dir))
        first = nil
        XCTAssertNotNil(InstanceRegistry.lockDevice("UID:1", directory: dir))
    }

    func testProcessScanFindsThisTestRunner() {
        let me = (ProcessInfo.processInfo.arguments[0] as NSString).lastPathComponent
        XCTAssertTrue(InstanceRegistry.processes(named: me).contains { $0.0 == getpid() })
    }

    func testHeldStateIsUntouched() {
        XCTAssertFalse(EngineState.held("x").touchesAudio)
        XCTAssertEqual(EngineState.held("permission").label, "engine off: permission")
    }
}
