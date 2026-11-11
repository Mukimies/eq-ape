import Foundation

/// Per-output-device profile, keyed by the device UID in `Settings.profiles`.
public struct DeviceProfile: Codable, Equatable, Sendable {
    /// Last seen device name (display only; the key is the UID).
    public var deviceName: String
    public var enabled: Bool
    /// Absolute path of the Equalizer APO config file.
    public var configPath: String?
    /// Automatic anti-clipping gain on/off.
    public var headroomEnabled: Bool
    /// Target headroom below 0 dBFS for the EQ's peak gain.
    public var headroomDB: Double

    public static let defaultHeadroomDB = 0.5

    public init(deviceName: String, enabled: Bool = true, configPath: String? = nil,
                headroomEnabled: Bool = true, headroomDB: Double = DeviceProfile.defaultHeadroomDB) {
        self.deviceName = deviceName
        self.enabled = enabled
        self.configPath = configPath
        self.headroomEnabled = headroomEnabled
        self.headroomDB = headroomDB
    }

    /// The value passed to EQProcessor (`nil` = anti-clipping off).
    public var effectiveHeadroomDB: Double? { headroomEnabled ? headroomDB : nil }

    enum CodingKeys: String, CodingKey { case deviceName, enabled, configPath, headroomEnabled, headroomDB }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        configPath = try c.decodeIfPresent(String.self, forKey: .configPath)
        headroomEnabled = try c.decodeIfPresent(Bool.self, forKey: .headroomEnabled) ?? true
        headroomDB = try c.decodeIfPresent(Double.self, forKey: .headroomDB) ?? DeviceProfile.defaultHeadroomDB
    }
}

/// Contents of `~/Library/Application Support/EQ Ape/settings.json`.
public struct Settings: Codable, Equatable, Sendable {
    public var version: Int
    /// Global on/off. Off = engine torn down, audio untouched.
    public var enabled: Bool
    public var profiles: [String: DeviceProfile]

    public init(version: Int = 1, enabled: Bool = true, profiles: [String: DeviceProfile] = [:]) {
        self.version = version
        self.enabled = enabled
        self.profiles = profiles
    }

    enum CodingKeys: String, CodingKey { case version, enabled, profiles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        profiles = try c.decodeIfPresent([String: DeviceProfile].self, forKey: .profiles) ?? [:]
    }
}

/// Loads and saves the settings JSON atomically.
public final class SettingsStore: @unchecked Sendable {
    public let fileURL: URL

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EQ Ape", isDirectory: true)
    }

    public static var defaultFileURL: URL { defaultDirectory.appendingPathComponent("settings.json") }

    public init(fileURL: URL = SettingsStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public enum LoadError: Error, CustomStringConvertible {
        case unreadable(String)
        public var description: String { switch self { case .unreadable(let s): return s } }
    }

    /// Missing file -> default settings. Corrupt file -> throws (callers keep the file and show an error
    /// rather than overwriting the user's profiles).
    public func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Settings() }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            throw LoadError.unreadable("settings file \(fileURL.path) could not be read: \(error.localizedDescription)")
        }
    }

    public func save(_ s: Settings) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(s).write(to: fileURL, options: .atomic)
    }
}
