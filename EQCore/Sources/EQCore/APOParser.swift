import Foundation

/// Equalizer APO text config parser. Semantics follow `apo2camilla.py`.
/// Every non-blank, non-comment line that is not converted yields a warning.
public enum APOParser {

    public static func parse(fileURL: URL) throws -> ParseResult {
        let data = try Data(contentsOf: fileURL)
        let state = State()
        state.parseText(decode(data), file: fileURL.lastPathComponent,
                        baseDir: fileURL.deletingLastPathComponent(), depth: 0)
        return state.result()
    }

    /// `baseURL` is the directory used to resolve `Include:` paths. If it points at an existing
    /// regular file, that file's directory is used instead.
    public static func parse(text: String, baseURL: URL?) -> ParseResult {
        let state = State()
        var dir = baseURL
        if let b = baseURL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: b.path, isDirectory: &isDir), !isDir.boolValue {
                dir = b.deletingLastPathComponent()
            }
        }
        state.parseText(text, file: "<text>", baseDir: dir, depth: 0)
        return state.result()
    }

    /// Decode UTF-8 (with or without BOM) or UTF-16 (BOM required).
    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return String(data: Data(bytes[2...]), encoding: .utf16LittleEndian) ?? ""
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return String(data: Data(bytes[2...]), encoding: .utf16BigEndian) ?? ""
        }
        var s = String(decoding: bytes, as: UTF8.self)
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s
    }

    // MARK: - internals
    // Semantics follow Equalizer APO's documented behaviour (see docs/APO-PARITY.md): command names, "ON",
    // filter type names and the Fc/Gain/Q/Hz/dB labels are case sensitive; commas are decimal marks.
    // Each line is interpreted by `LineInterpreter` (shared with `ConfigDocument`); this type only adds the
    // channel selection, Include recursion and the "file:line: " warning prefixes.

    final class State {
        var channels: [Int] = [0, 1]
        var left: [Stage] = []
        var right: [Stage] = []
        var warnings: [String] = []

        func result() -> ParseResult {
            ParseResult(config: EQConfig(left: left, right: right), warnings: warnings)
        }

        func add(_ st: Stage) {
            if channels.contains(0) { left.append(st) }
            if channels.contains(1) { right.append(st) }
        }

        func parseText(_ text: String, file: String, baseDir: URL?, depth: Int) {
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            parseLines(lines.map { (String($0), LineInterpreter.interpret(String($0))) }, file: file, baseDir: baseDir, depth: depth) {
                rest, where_, baseDir, depth in self.include(rest, where_: where_, baseDir: baseDir, depth: depth)
            }
        }

        /// Apply interpreted lines. `include` handles an Include line (resolution differs between the
        /// file parser and `ConfigWorkspace`).
        func parseLines(_ lines: [(raw: String, kind: LineKind)], file: String, baseDir: URL?, depth: Int,
                        onLine: ((Int) -> Void)? = nil,
                        include: (_ rest: String, _ where_: String, _ baseDir: URL?, _ depth: Int) -> Void) {
            // Equalizer APO restores the channel selection when an included file ends.
            let savedChannels = channels
            defer { channels = savedChannels }
            for (i, line) in lines.enumerated() {
                let where_ = "\(file):\(i + 1)"
                onLine?(i)
                switch line.kind {
                case .blank, .comment:
                    continue
                case .unknown(let message):
                    if let m = message { warnings.append("\(where_): \(m)") }
                case .command(let c):
                    let s = line.raw.trimmingCharacters(in: .whitespaces)
                    apply(c, line: s, where_: where_, baseDir: baseDir, depth: depth, include: include)
                }
            }
        }

        func apply(_ c: ConfigCommand, line s: String, where_: String, baseDir: URL?, depth: Int,
                   include: (_ rest: String, _ where_: String, _ baseDir: URL?, _ depth: Int) -> Void) {
            switch c {
            case .channel(let names):
                var chans: [Int] = []
                for n in names.map({ $0.uppercased() }) {
                    if n == "ALL" { chans = [0, 1]; break }
                    if n == "L" { chans.append(0) }
                    else if n == "R" { chans.append(1) }
                    else if let d = n.first, d.isASCII, d.isNumber {
                        // like wcstol: leading digits
                        let v = Int(n.prefix(while: { $0.isASCII && $0.isNumber })) ?? 0
                        if v == 1 { chans.append(0) } else if v == 2 { chans.append(1) }
                        else { warnings.append("\(where_): channel '\(n)' ignored (stereo only)") }
                    }
                    else { warnings.append("\(where_): channel '\(n)' ignored (stereo only)") }
                }
                channels = Array(Set(chans)).sorted()
            case .preamp(let db):
                add(.gain(dB: db))
            case .include(let rest):
                include(rest, where_, baseDir, depth)
            case .graphicEQ(let pts):
                // stable sort by frequency
                let sorted = pts.enumerated().sorted { ($0.element.freq, $0.offset) < ($1.element.freq, $1.offset) }
                add(.graphicEQ(points: sorted.map { $0.element }))
            case .filter(let f):
                let r = f.evaluate(line: s)
                for p in r.problems { warnings.append("\(where_): \(p)") }
                if let spec = r.spec { add(.biquad(spec)) }
            }
        }

        /// Include path as Equalizer APO resolves it (plus macOS leniency: backslashes, optional quotes).
        static func includeName(_ rest: String) -> String {
            var name = rest.replacingOccurrences(of: "\\", with: "/")
            if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") { name = String(name.dropFirst().dropLast()) }
            return name
        }

        static func resolveInclude(_ name: String, baseDir: URL?) -> URL? {
            if name.hasPrefix("/") { return URL(fileURLWithPath: name) }
            return baseDir?.appendingPathComponent(name)
        }

        func include(_ rest: String, where_: String, baseDir: URL?, depth: Int) {
            let name = State.includeName(rest)
            if depth >= 100 { warnings.append("\(where_): include nesting too deep: \(rest)"); return }   // APO RECURSION_LIMIT
            guard let url = State.resolveInclude(name, baseDir: baseDir) else {
                warnings.append("\(where_): included file cannot be resolved (no base URL): \(rest)"); return
            }
            guard let data = try? Data(contentsOf: url) else {
                warnings.append("\(where_): included file not found: \(rest)"); return
            }
            parseText(APOParser.decode(data), file: url.lastPathComponent,
                      baseDir: url.deletingLastPathComponent(), depth: depth + 1)
        }
    }
}
