import Foundation

/// What the engine is doing for the current output device.
public enum EngineState: Equatable, Sendable {
    case off                    // global switch off: nothing tapped anywhere
    case noDevice               // no (matching) output device
    case noProfile              // device has no profile: untouched
    case disabled               // profile disabled: untouched
    case noConfig               // profile without a config file: untouched
    case bypassed(String)       // config missing / unreadable / no filters: untouched
    case starting
    case active
    case error(String)

    public var label: String {
        switch self {
        case .off: return "off"
        case .noDevice: return "no output device"
        case .noProfile: return "no profile"
        case .disabled: return "profile disabled"
        case .noConfig: return "no config file chosen"
        case .bypassed(let why): return "bypassed (\(why))"
        case .starting: return "starting"
        case .active: return "active"
        case .error(let e): return "error: \(e)"
        }
    }

    /// True while a tap exists for the device (audio is being captured and replayed).
    public var touchesAudio: Bool { self == .active || self == .starting }
}

/// Pure profile-selection rules (unit tested).
public enum Decision: Equatable, Sendable {
    case untouched(EngineState)
    case process(configPath: String, headroomDB: Double?)

    public static func decide(globalEnabled: Bool, deviceUID: String?, settings: Settings) -> Decision {
        guard globalEnabled, settings.enabled else { return .untouched(.off) }
        guard let uid = deviceUID else { return .untouched(.noDevice) }
        guard let p = settings.profiles[uid] else { return .untouched(.noProfile) }
        guard p.enabled else { return .untouched(.disabled) }
        guard let path = p.configPath, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return .untouched(.noConfig) }
        return .process(configPath: path, headroomDB: p.effectiveHeadroomDB)
    }
}
