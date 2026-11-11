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

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let typeRE = re("^\\s*ON\\s+([A-Za-z]+)")
    private static let freqRE = re("\\s+Fc\\s*([-+0-9.eE\\u00A0]+)\\s*H\\s*z")
    private static let gainRE = re("\\s+Gain\\s*([-+0-9.eE]+)\\s*dB")
    private static let qRE = re("\\s+Q\\s*([-+0-9.eE]+)")
    private static let bwRE = re("\\s+BW\\s+Oct\\s*([-+0-9.eE]+)")
    private static let slopeRE = re("^\\s*([-+0-9.eE]+)\\s*dB")
    private static let numberTokenRE = re("[-+0-9.eE]+")
    private static let leadingNumberRE = re("^\\s*([-+]?(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:[eE][-+]?[0-9]+)?)")

    private static let knownCommands: Set<String> = ["preamp", "include", "graphiceq", "channel", "filter"]

    /// First capture group of the first match, plus the text after the match.
    private static func search(_ re: NSRegularExpression, _ s: String) -> (group: String, suffix: String)? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        let g = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
        return (g, ns.substring(from: m.range.location + m.range.length))
    }

    /// C `strtod` on the token (like `wcstod`): parses the longest numeric prefix, 0 if none.
    private static func strtodPrefix(_ s: String) -> Double { strtod(s, nil) }

    private final class State {
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
            // Equalizer APO restores the channel selection when an included file ends.
            let savedChannels = channels
            defer { channels = savedChannels }
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            for (i, raw) in lines.enumerated() {
                let s = raw.trimmingCharacters(in: .whitespaces)
                if s.isEmpty || s.hasPrefix("#") { continue }
                let where_ = "\(file):\(i + 1)"
                let key: String, rest: String
                if let colon = s.firstIndex(of: ":") {
                    key = s[s.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                    rest = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                } else {
                    key = s; rest = ""
                }

                if key == "Channel" {
                    var chans: [Int] = []
                    for n in rest.uppercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
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
                } else if key == "Preamp" {
                    // sscanf(" %lf dB"): the number alone is enough, "dB" is not checked ("Preamp: -6 db" works).
                    let value = rest.replacingOccurrences(of: ",", with: ".")
                    guard let m = APOParser.search(APOParser.leadingNumberRE, value) else {
                        warnings.append("\(where_): could not parse: \(s)"); continue
                    }
                    add(.gain(dB: APOParser.strtodPrefix(m.group)))
                } else if key == "Include" {
                    include(rest, where_: where_, baseDir: baseDir, depth: depth)
                } else if key == "GraphicEQ" {
                    // Equalizer APO: decimal commas only if there is no '.' anywhere; the numbers are all
                    // maximal runs of [-+0-9.eE]; consecutive runs are paired as (freq, gain); everything else
                    // (";", spaces, tabs, stray text) is a separator.
                    let value = rest.contains(".") ? rest : rest.replacingOccurrences(of: ",", with: ".")
                    let ns = value as NSString
                    let toks = APOParser.numberTokenRE.matches(in: value, range: NSRange(location: 0, length: ns.length))
                        .map { APOParser.strtodPrefix(ns.substring(with: $0.range)) }
                    var pts: [GraphicEQPoint] = []
                    var k = 0
                    while k + 1 < toks.count { pts.append(GraphicEQPoint(freq: toks[k], gainDB: toks[k + 1])); k += 2 }
                    if pts.count < 2 {
                        warnings.append("\(where_): could not parse GraphicEQ: \(String(s.prefix(60)))"); continue
                    }
                    // stable sort by frequency
                    let sorted = pts.enumerated().sorted { ($0.element.freq, $0.offset) < ($1.element.freq, $1.offset) }
                    add(.graphicEQ(points: sorted.map { $0.element }))
                } else if key.hasPrefix("Filter") {
                    for f in parseFilter(rest, where_: where_, line: s) { add(.biquad(f)) }
                } else if APOParser.knownCommands.contains(key.lowercased()) {
                    warnings.append("\(where_): '\(key)' ignored: Equalizer APO command names are case sensitive: \(s)")
                } else {
                    warnings.append("\(where_): unsupported line, NOT converted: \(s)")
                }
            }
        }

        func include(_ rest: String, where_: String, baseDir: URL?, depth: Int) {
            var name = rest.replacingOccurrences(of: "\\", with: "/")
            if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") { name = String(name.dropFirst().dropLast()) }
            if depth >= 100 { warnings.append("\(where_): include nesting too deep: \(rest)"); return }   // APO RECURSION_LIMIT
            let url: URL
            if name.hasPrefix("/") { url = URL(fileURLWithPath: name) }
            else if let b = baseDir { url = b.appendingPathComponent(name) }
            else { warnings.append("\(where_): included file cannot be resolved (no base URL): \(rest)"); return }
            guard let data = try? Data(contentsOf: url) else {
                warnings.append("\(where_): included file not found: \(rest)"); return
            }
            parseText(APOParser.decode(data), file: url.lastPathComponent,
                      baseDir: url.deletingLastPathComponent(), depth: depth + 1)
        }

        /// Equalizer APO `getFreq`: strips NBSP, parses a number; a value of >= 5 characters without 'e'/'E' whose
        /// 4th-last character is '.' is read as a thousands separator ("1.000" -> 1000, REW compatibility).
        static func freqValue(_ raw: String) -> Double? {
            let s = raw.replacingOccurrences(of: "\u{00A0}", with: "")
            guard let first = s.unicodeScalars.first, "+-.0123456789".unicodeScalars.contains(first) else { return nil }
            var v = strtod(s, nil)
            if s.count >= 5, !s.contains("e"), !s.contains("E") {
                let chars = Array(s)
                if chars[chars.count - 4] == "." { v *= 1000 }
            }
            return v
        }

        func parseFilter(_ rest: String, where_: String, line: String) -> [BiquadSpec] {
            // Equalizer APO replaces every ',' by '.' first.
            let value = rest.replacingOccurrences(of: ",", with: ".")
            guard let head = APOParser.search(APOParser.typeRE, value) else {
                // "OFF ..." (and anything else without a leading ON) is silently ignored by Equalizer APO.
                if value.hasPrefix("OFF") { return [] }
                warnings.append("\(where_): could not parse filter, NOT converted: \(line)"); return []
            }
            let kindS = head.group
            if kindS == "None" { return [] }
            let params = head.suffix
            enum T { case pk, lp, hp, bp, ls, hs, no, ap }
            let map: [String: (T, Bool)] = [   // (type, centre-frequency variant "C")
                "PK": (.pk, false), "PEQ": (.pk, false), "Modal": (.pk, false),
                "LP": (.lp, false), "HP": (.hp, false), "LPQ": (.lp, false), "HPQ": (.hp, false),
                "BP": (.bp, false), "LS": (.ls, false), "HS": (.hs, false), "LSC": (.ls, true), "HSC": (.hs, true),
                "NO": (.no, false), "AP": (.ap, false)]
            guard let (type, centre) = map[kindS] else {
                warnings.append("\(where_): filter type '\(kindS)' unsupported, NOT converted: \(line)"); return []
            }
            let isShelf = type == .ls || type == .hs
            var ok = true
            var freq = 0.0
            if let m = APOParser.search(APOParser.freqRE, params), let f = State.freqValue(m.group), f > 0 { freq = f }
            else { warnings.append("\(where_): no (valid) Fc, NOT converted: \(line)"); ok = false }

            var gain = 0.0
            if let m = APOParser.search(APOParser.gainRE, params) {
                if !(type == .lp || type == .hp || type == .no || type == .ap) { gain = APOParser.strtodPrefix(m.group) }
            } else if type == .pk || isShelf {
                warnings.append("\(where_): no Gain, NOT converted: \(line)"); ok = false
            }

            // bandwidthOrQOrS bookkeeping exactly as in BiQuadFilterFactory
            var val = 0.0, isBWorS = false
            if let m = APOParser.search(APOParser.qRE, params) { val = APOParser.strtodPrefix(m.group) }
            if let m = APOParser.search(APOParser.bwRE, params), !isShelf {
                val = APOParser.strtodPrefix(m.group); isBWorS = true
            }
            if let m = APOParser.search(APOParser.slopeRE, params), isShelf {
                val = APOParser.strtodPrefix(m.group); isBWorS = true
            }
            var corner = false
            var spec: BiquadSpec
            if val == 0 {
                switch type {
                case .pk, .ap:
                    warnings.append("\(where_): no Q or bandwidth, NOT converted: \(line)"); ok = false
                    spec = BiquadSpec(kind: .peaking, freq: freq)
                case .lp, .hp, .bp:
                    spec = BiquadSpec(kind: type == .lp ? .lowPass : type == .hp ? .highPass : .bandPass,
                                      freq: freq, q: 0.5.squareRoot())
                case .ls, .hs:   // S = 0.9 "found out by experimentation with RoomEQWizard"; not corner-shifted
                    spec = BiquadSpec(kind: type == .ls ? .lowShelf : .highShelf, freq: freq, gainDB: gain,
                                      slopeDBPerOct: 10.8)
                case .no:
                    spec = BiquadSpec(kind: .notch, freq: freq, q: 30)
                }
            } else {
                switch type {
                case .pk: spec = BiquadSpec(kind: .peaking, freq: freq, gainDB: gain,
                                            q: isBWorS ? nil : val, bandwidthOct: isBWorS ? val : nil)
                case .ap: spec = BiquadSpec(kind: .allPass, freq: freq,
                                            q: isBWorS ? nil : val, bandwidthOct: isBWorS ? val : nil)
                case .lp, .hp, .bp, .no:
                    let k: BiquadKind = type == .lp ? .lowPass : type == .hp ? .highPass : type == .bp ? .bandPass : .notch
                    spec = BiquadSpec(kind: k, freq: freq, q: isBWorS ? nil : val, bandwidthOct: isBWorS ? val : nil)
                case .ls, .hs:
                    let k: BiquadKind = type == .ls ? .lowShelf : .highShelf
                    if isBWorS { spec = BiquadSpec(kind: k, freq: freq, gainDB: gain, slopeDBPerOct: val) }
                    else { spec = BiquadSpec(kind: k, freq: freq, gainDB: gain, q: val) }
                    corner = !centre
                }
            }
            guard ok else { return [] }
            if corner {
                // Equalizer APO BiQuadFilter::initialize: LS/HS (not LSC/HSC) with explicit Q or slope give a corner
                // frequency; the centre frequency is fc * 10^(|gain|/80/S) (low shelf) or fc / that (high shelf).
                var sFactor: Double
                if let sl = spec.slopeDBPerOct { sFactor = sl / 12 }
                else {
                    let q = spec.q ?? 1, a = pow(10, gain / 40)
                    sFactor = 1.0 / ((1.0 / (q * q) - 2.0) / (a + 1.0 / a) + 1.0)
                }
                let factor = pow(10.0, abs(gain) / 80.0 / sFactor)
                if factor.isFinite && factor > 0 { spec.freq = type == .ls ? freq * factor : freq / factor }
                else { warnings.append("\(where_): corner-frequency conversion not finite, NOT converted: \(line)"); return [] }
            }
            return [spec]
        }
    }
}
