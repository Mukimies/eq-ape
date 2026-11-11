import Foundation

/// Read-only audio-capture permission preflight.
///
/// There is no public API to query the audio-capture (process tap) permission on macOS 14/15/26.
/// This uses the private TCC.framework function `TCCAccessPreflight`, which only reads the TCC
/// database for the responsible process and never shows a prompt. Used by the headless mode as a
/// safety net (refuse to start IO if a prompt would appear) and by the menu for an informational hint.
public enum Permission {
    public enum State: String { case granted, denied, notDetermined = "not determined", unknown }

    public static func audioCapture() -> State { preflight("kTCCServiceAudioCapture") }

    static func preflight(_ service: String) -> State {
        typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
        guard let h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let sym = dlsym(h, "TCCAccessPreflight") else { return .unknown }
        let r = unsafeBitCast(sym, to: PreflightFn.self)(service as CFString, nil)
        switch r {
        case 0: return .granted
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unknown
        }
    }
}
