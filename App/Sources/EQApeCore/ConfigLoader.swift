import EQCore
import Foundation

/// Result of loading an Equalizer APO config for a device.
public struct LoadedConfig: Sendable {
    /// nil = nothing usable (missing file, unreadable, or no filter stages): the device is left untouched.
    public var config: EQConfig?
    public var warnings: [String]
    /// Main file plus every file it Includes (recursively), existing or not: the watch list.
    public var files: [URL]
    /// Why `config` is nil (shown in the menu as the bypass reason).
    public var problem: String?

    public var isUsable: Bool { config != nil }
}

public enum ConfigLoader {
    /// Parses with EQCore.APOParser and applies the fallback rules:
    /// missing / unreadable file -> unusable; parse yields no stages -> unusable (never silence).
    public static func load(path: String) -> LoadedConfig {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let files = IncludeScanner.files(startingAt: url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LoadedConfig(config: nil, warnings: [], files: files, problem: "config file not found: \(url.lastPathComponent)")
        }
        let result: ParseResult
        do {
            result = try APOParser.parse(fileURL: url)
        } catch {
            return LoadedConfig(config: nil, warnings: [], files: files, problem: "config file unreadable: \(error.localizedDescription)")
        }
        if result.config.left.isEmpty && result.config.right.isEmpty {
            return LoadedConfig(config: nil, warnings: result.warnings, files: files, problem: "config has no filters")
        }
        return LoadedConfig(config: result.config, warnings: result.warnings, files: files, problem: nil)
    }
}

/// Finds the files a config Includes, for watching. Mirrors EQCore's Include resolution
/// (relative to the including file, backslashes -> slashes, optional quotes, depth limit 16).
/// EQCore does not expose its include list, so this is a small independent scan.
public enum IncludeScanner {
    public static func files(startingAt url: URL) -> [URL] {
        var seen: [URL] = []
        func visit(_ u: URL, depth: Int) {
            let std = u.standardizedFileURL
            if seen.contains(std) { return }
            seen.append(std)
            guard depth < 16, let data = try? Data(contentsOf: std) else { return }
            for raw in decode(data).components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard let colon = line.firstIndex(of: ":"),
                      line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "include" else { continue }
                var name = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\\", with: "/")
                if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") { name = String(name.dropFirst().dropLast()) }
                if name.isEmpty { continue }
                let target = name.hasPrefix("/") ? URL(fileURLWithPath: name)
                    : std.deletingLastPathComponent().appendingPathComponent(name)
                visit(target, depth: depth + 1)
            }
        }
        visit(url, depth: 0)
        return seen
    }

    static func decode(_ data: Data) -> String {
        let b = [UInt8](data)
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return String(data: Data(b[2...]), encoding: .utf16LittleEndian) ?? "" }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return String(data: Data(b[2...]), encoding: .utf16BigEndian) ?? "" }
        return String(decoding: b, as: UTF8.self)
    }
}
