import AVFoundation
import EQApeCore
import Foundation
import Security
import TapKit

/// No-prompt permission preflights and the binary's code-signing identity (`--print-permission`, `--require-granted`,
/// the ui-test `state`). Nothing here can raise a prompt: `TCCAccessPreflight` only reads the TCC database and
/// `AVCaptureDevice.authorizationStatus(for:)` is documented not to ask.
enum PermissionCheck {
    static func capture() -> EngineGate.Capture {
        switch Permission.audioCapture() {
        case .granted: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .unknown: return .unknown
        }
    }

    static func microphone() -> EngineGate.Microphone {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    /// The process TCC attributes our requests to (Terminal when started from Terminal, the app itself when
    /// launched by Launch Services). Private libsystem function, looked up at run time; nil if unavailable.
    static func responsibleProcess() -> (pid: Int32, path: String)? {
        typealias Fn = @convention(c) (Int32) -> Int32
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        let pid = unsafeBitCast(sym, to: Fn.self)(getpid())
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return (pid, n > 0 ? String(cString: buf) : "?")
    }

    struct Identity {
        var identifier = "?"
        var designatedRequirement = "?"
        var cdhash = "?"
        var signer = "?"
        var adhoc = false
    }

    static func identity() -> Identity {
        var id = Identity()
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return id }
        var stat: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat else { return id }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(stat, flags, &info) == errSecSuccess, let d = info as? [String: Any] else { return id }
        id.identifier = d[kSecCodeInfoIdentifier as String] as? String ?? "?"
        if let u = d[kSecCodeInfoUnique as String] as? Data { id.cdhash = u.map { String(format: "%02x", $0) }.joined() }
        var req: SecRequirement?
        if SecCodeCopyDesignatedRequirement(stat, [], &req) == errSecSuccess, let req {
            var s: CFString?
            if SecRequirementCopyString(req, [], &s) == errSecSuccess, let s { id.designatedRequirement = s as String }
        }
        if let certs = d[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            id.signer = (SecCertificateCopySubjectSummary(leaf) as String?) ?? "?"
        } else {
            id.signer = "ad hoc"
        }
        if let f = d[kSecCodeInfoFlags as String] as? UInt32 { id.adhoc = f & 0x2 != 0 }
        return id
    }

    /// Everything above as a JSON-friendly dictionary.
    static func report() -> [String: Any] {
        let i = identity()
        var r: [String: Any] = [
            "audioCapture": capture().rawValue,
            "microphone": microphone().rawValue,
            "microphoneTCC": Permission.microphone().rawValue,
            "identifier": i.identifier,
            "designatedRequirement": i.designatedRequirement,
            "cdhash": i.cdhash,
            "signer": i.signer,
            "adhoc": i.adhoc,
            "pid": Int(getpid()),
            "executable": Bundle.main.executablePath ?? CommandLine.arguments[0],
        ]
        if let rp = responsibleProcess() {
            r["responsiblePID"] = Int(rp.pid)
            r["responsibleProcess"] = rp.path
            r["responsibleIsSelf"] = rp.pid == getpid()
        }
        return r
    }

    static func printReport() {
        let d = (try? JSONSerialization.data(withJSONObject: report(), options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        print("EQ Ape permission: " + (String(data: d, encoding: .utf8) ?? "{}"))
        fflush(stdout)
    }
}
