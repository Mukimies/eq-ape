import Foundation

// Line-level interpretation of Equalizer APO config text, shared by `APOParser` (stages) and
// `ConfigDocument` (line-preserving editing). Semantics are Equalizer APO's documented behaviour
// (see docs/APO-PARITY.md); nothing here is copied from Equalizer APO.

/// The fields of a `Filter` line as written (after Equalizer APO's own number reading), without
/// applying defaults. `evaluate` turns it into a biquad exactly as `APOParser` does.
public struct FilterLine: Equatable, Sendable {
    /// Text between "Filter" and ":" as written, e.g. "  2" in "Filter  2: ...", "" in "Filter: ...".
    public var label: String
    /// `ON` (true) or `OFF` (false).
    public var enabled: Bool
    /// Type name as written: PK, PEQ, Modal, LP, HP, LPQ, HPQ, BP, LS, HS, LSC, HSC, NO, AP, or None.
    public var type: String
    /// `Fc` in Hz as Equalizer APO reads it (decimal comma, REW thousands separator quirk applied).
    public var freq: Double?
    public var gainDB: Double?
    public var q: Double?
    public var bandwidthOct: Double?
    /// Shelf slope in dB/octave ("LSC 12 dB Fc ..."), the number directly after the type.
    public var slopeDB: Double?

    public init(label: String = "", enabled: Bool = true, type: String, freq: Double? = nil, gainDB: Double? = nil,
                q: Double? = nil, bandwidthOct: Double? = nil, slopeDB: Double? = nil) {
        self.label = label; self.enabled = enabled; self.type = type; self.freq = freq; self.gainDB = gainDB
        self.q = q; self.bandwidthOct = bandwidthOct; self.slopeDB = slopeDB
    }

    /// Filter types EQCore converts (case sensitive, as Equalizer APO).
    public static let supportedTypes: [String] = ["PK", "PEQ", "Modal", "LP", "HP", "LPQ", "HPQ", "BP",
                                                  "LS", "HS", "LSC", "HSC", "NO", "AP"]

    public var isNone: Bool { type == "None" }
    public var isShelf: Bool { ["LS", "HS", "LSC", "HSC"].contains(type) }
    public var isPeaking: Bool { ["PK", "PEQ", "Modal"].contains(type) }
    /// True for types whose gain matters (peaking and shelves; BP reads but ignores it).
    public var usesGain: Bool { isPeaking || isShelf }
    /// True for types whose Q (or BW) matters.
    public var usesQ: Bool { !isNone }

    /// Filter number from the label ("Filter 2:" -> 2), if it is a plain integer.
    public var number: Int? { Int(label.trimmingCharacters(in: .whitespaces)) }

    /// Biquad as Equalizer APO would build it, plus the warnings `APOParser` emits (message texts
    /// without the "file:line: " prefix). `line` is the trimmed source line, used in the messages.
    /// OFF and None filters give `(nil, [])`.
    public func evaluate(line: String) -> (spec: BiquadSpec?, problems: [String]) {
        if !enabled || isNone { return (nil, []) }
        enum T { case pk, lp, hp, bp, ls, hs, no, ap }
        let map: [String: (T, Bool)] = [   // (type, centre-frequency variant "C")
            "PK": (.pk, false), "PEQ": (.pk, false), "Modal": (.pk, false),
            "LP": (.lp, false), "HP": (.hp, false), "LPQ": (.lp, false), "HPQ": (.hp, false),
            "BP": (.bp, false), "LS": (.ls, false), "HS": (.hs, false), "LSC": (.ls, true), "HSC": (.hs, true),
            "NO": (.no, false), "AP": (.ap, false)]
        guard let (type, centre) = map[self.type] else {
            return (nil, ["filter type '\(self.type)' unsupported, NOT converted: \(line)"])
        }
        var problems: [String] = []
        let isShelf = type == .ls || type == .hs
        var ok = true
        var freq = 0.0
        if let f = self.freq, f > 0 { freq = f }
        else { problems.append("no (valid) Fc, NOT converted: \(line)"); ok = false }

        var gain = 0.0
        if let g = gainDB {
            if !(type == .lp || type == .hp || type == .no || type == .ap) { gain = g }
        } else if type == .pk || isShelf {
            problems.append("no Gain, NOT converted: \(line)"); ok = false
        }

        // bandwidthOrQOrS bookkeeping as in Equalizer APO's biquad factory: Q, then BW (non-shelf), then slope (shelf).
        var val = 0.0, isBWorS = false
        if let q { val = q }
        if let bw = bandwidthOct, !isShelf { val = bw; isBWorS = true }
        if let s = slopeDB, isShelf { val = s; isBWorS = true }
        var corner = false
        var spec: BiquadSpec
        if val == 0 {
            switch type {
            case .pk, .ap:
                problems.append("no Q or bandwidth, NOT converted: \(line)"); ok = false
                spec = BiquadSpec(kind: .peaking, freq: freq)
            case .lp, .hp, .bp:
                spec = BiquadSpec(kind: type == .lp ? .lowPass : type == .hp ? .highPass : .bandPass,
                                  freq: freq, q: 0.5.squareRoot())
            case .ls, .hs:   // S = 0.9 ("found by experimentation with RoomEQWizard"); not corner-shifted
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
        guard ok else { return (nil, problems) }
        if corner {
            // LS/HS (not LSC/HSC) with explicit Q or slope give a corner frequency; the centre frequency is
            // fc * 10^(|gain|/80/S) (low shelf) or fc / that (high shelf).
            var sFactor: Double
            if let sl = spec.slopeDBPerOct { sFactor = sl / 12 }
            else {
                let q = spec.q ?? 1, a = pow(10, gain / 40)
                sFactor = 1.0 / ((1.0 / (q * q) - 2.0) / (a + 1.0 / a) + 1.0)
            }
            let factor = pow(10.0, abs(gain) / 80.0 / sFactor)
            if factor.isFinite && factor > 0 { spec.freq = type == .ls ? freq * factor : freq / factor }
            else { return (nil, problems + ["corner-frequency conversion not finite, NOT converted: \(line)"]) }
        }
        return (spec, problems)
    }
}

/// A command line Equalizer APO understands (and EQCore converts).
public enum ConfigCommand: Equatable, Sendable {
    case preamp(dB: Double)
    case filter(FilterLine)
    /// Points in file order (the stage is sorted by frequency).
    case graphicEQ(points: [GraphicEQPoint])
    /// Channel words as written (Equalizer APO upper-cases them).
    case channel(names: [String])
    /// Include path as written (relative to the including file; backslashes and quotes allowed).
    case include(path: String)

    /// Canonical Equalizer APO syntax for this command (the syntax `APOParser` reads back to the same value).
    public var canonicalText: String {
        switch self {
        case .preamp(let db):
            return "Preamp: \(APOFormat.number(db)) dB"
        case .filter(let f):
            var s = "Filter"
            if let n = f.number { s += " \(n)" }
            s += ": " + (f.enabled ? "ON" : "OFF") + " " + f.type
            if f.isNone { return s }
            if let sl = f.slopeDB { s += " \(APOFormat.number(sl)) dB" }
            if let fc = f.freq { s += " Fc \(APOFormat.frequency(fc)) Hz" }
            if let g = f.gainDB { s += " Gain \(APOFormat.number(g)) dB" }
            if let q = f.q { s += " Q \(APOFormat.number(q))" }
            if let bw = f.bandwidthOct { s += " BW Oct \(APOFormat.number(bw))" }
            return s
        case .graphicEQ(let pts):
            return "GraphicEQ: " + pts.map { "\(APOFormat.number($0.freq)) \(APOFormat.number($0.gainDB))" }
                .joined(separator: "; ")
        case .channel(let names):
            return "Channel: " + names.joined(separator: " ")
        case .include(let path):
            return "Include: " + path
        }
    }
}

/// What one line of a config file is.
public enum LineKind: Equatable, Sendable {
    case blank
    /// A `#` line. `command` is the interpretation of the text after the `#` when that text is itself a
    /// command (REW exports contain commented-out filters), else nil.
    case comment(command: ConfigCommand?)
    case command(ConfigCommand)
    /// Not converted. `message` is the warning `APOParser` emits for it (nil = silently ignored,
    /// e.g. "Filter: OFF" with an unknown type).
    case unknown(message: String?)

    public var command: ConfigCommand? { if case .command(let c) = self { return c }; return nil }
}

/// Number formatting for generated lines.
public enum APOFormat {
    /// Shortest decimal text that reads back to the same Double; no exponent, no trailing ".0", no "-0".
    public static func number(_ v: Double) -> String {
        if v == 0 || !v.isFinite { return "0" }
        var s = "\(v)"
        if s.contains("e") || s.contains("E") {
            s = String(format: "%.12f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }

    /// Like `number`, but never produces text that Equalizer APO's `Fc` reader would take as a thousands
    /// separator (5+ characters with '.' fourth from the end, e.g. "60.812"): such values get a trailing 0.
    public static func frequency(_ v: Double) -> String {
        var s = number(v)
        let c = Array(s)
        if c.count >= 5, c[c.count - 4] == ".", !s.contains("e"), !s.contains("E") { s += "0" }
        return s
    }
}

enum LineInterpreter {
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    static let typeRE = re("^\\s*ON\\s+([A-Za-z]+)")
    static let offTypeRE = re("^\\s*OFF\\s+([A-Za-z]+)")
    static let freqRE = re("\\s+Fc\\s*([-+0-9.eE\\u00A0]+)\\s*H\\s*z")
    static let gainRE = re("\\s+Gain\\s*([-+0-9.eE]+)\\s*dB")
    static let qRE = re("\\s+Q\\s*([-+0-9.eE]+)")
    static let bwRE = re("\\s+BW\\s+Oct\\s*([-+0-9.eE]+)")
    static let slopeRE = re("^\\s*([-+0-9.eE]+)\\s*dB")
    static let numberTokenRE = re("[-+0-9.eE]+")
    static let leadingNumberRE = re("^\\s*([-+]?(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:[eE][-+]?[0-9]+)?)")
    static let knownCommands: Set<String> = ["preamp", "include", "graphiceq", "channel", "filter"]

    /// First capture group of the first match, plus the text after the match.
    static func search(_ re: NSRegularExpression, _ s: String) -> (group: String, suffix: String)? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        let g = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
        return (g, ns.substring(from: m.range.location + m.range.length))
    }

    /// C `strtod` on the token (like `wcstod`): parses the longest numeric prefix, 0 if none.
    static func strtodPrefix(_ s: String) -> Double { strtod(s, nil) }

    /// Equalizer APO's frequency reader: strips NBSP, parses a number; a value of >= 5 characters without
    /// 'e'/'E' whose 4th-last character is '.' is read as a thousands separator ("1.000" -> 1000, REW).
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

    /// Interpret one raw line (without its line terminator).
    static func interpret(_ raw: String) -> LineKind {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return .blank }
        if s.hasPrefix("#") {
            let inner = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            if case .command(let c) = interpret(inner) { return .comment(command: c) }
            return .comment(command: nil)
        }
        let key: String, rest: String
        if let colon = s.firstIndex(of: ":") {
            key = s[s.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            rest = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        } else {
            key = s; rest = ""
        }
        if key == "Channel" {
            return .command(.channel(names: rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)))
        } else if key == "Preamp" {
            // sscanf(" %lf dB"): the number alone is enough, "dB" is not checked ("Preamp: -6 db" works).
            let value = rest.replacingOccurrences(of: ",", with: ".")
            guard let m = search(leadingNumberRE, value) else { return .unknown(message: "could not parse: \(s)") }
            return .command(.preamp(dB: strtodPrefix(m.group)))
        } else if key == "Include" {
            return .command(.include(path: rest))
        } else if key == "GraphicEQ" {
            // Decimal commas only if there is no '.' anywhere; the numbers are all maximal runs of
            // [-+0-9.eE]; consecutive runs are paired as (freq, gain); everything else is a separator.
            let value = rest.contains(".") ? rest : rest.replacingOccurrences(of: ",", with: ".")
            let ns = value as NSString
            let toks = numberTokenRE.matches(in: value, range: NSRange(location: 0, length: ns.length))
                .map { strtodPrefix(ns.substring(with: $0.range)) }
            var pts: [GraphicEQPoint] = []
            var k = 0
            while k + 1 < toks.count { pts.append(GraphicEQPoint(freq: toks[k], gainDB: toks[k + 1])); k += 2 }
            if pts.count < 2 { return .unknown(message: "could not parse GraphicEQ: \(String(s.prefix(60)))") }
            return .command(.graphicEQ(points: pts))
        } else if key.hasPrefix("Filter") {
            return interpretFilter(label: String(key.dropFirst("Filter".count)), rest: rest, line: s)
        } else if knownCommands.contains(key.lowercased()) {
            return .unknown(message: "'\(key)' ignored: Equalizer APO command names are case sensitive: \(s)")
        } else {
            return .unknown(message: "unsupported line, NOT converted: \(s)")
        }
    }

    static func interpretFilter(label: String, rest: String, line: String) -> LineKind {
        // Equalizer APO replaces every ',' by '.' first.
        let value = rest.replacingOccurrences(of: ",", with: ".")
        var enabled = true
        var head = search(typeRE, value)
        if head == nil {
            // "OFF ..." (and anything else without a leading ON) is silently ignored by Equalizer APO.
            guard value.hasPrefix("OFF") else { return .unknown(message: "could not parse filter, NOT converted: \(line)") }
            head = search(offTypeRE, value)
            enabled = false
            if head == nil { return .unknown(message: nil) }
        }
        let type = head!.group
        if type != "None" && !FilterLine.supportedTypes.contains(type) {
            return .unknown(message: enabled ? "filter type '\(type)' unsupported, NOT converted: \(line)" : nil)
        }
        let params = head!.suffix
        var f = FilterLine(label: label, enabled: enabled, type: type)
        if type == "None" { return .command(.filter(f)) }
        if let m = search(freqRE, params) { f.freq = freqValue(m.group) }
        if let m = search(gainRE, params) { f.gainDB = strtodPrefix(m.group) }
        if let m = search(qRE, params) { f.q = strtodPrefix(m.group) }
        if let m = search(bwRE, params) { f.bandwidthOct = strtodPrefix(m.group) }
        if let m = search(slopeRE, params) { f.slopeDB = strtodPrefix(m.group) }
        return .command(.filter(f))
    }
}
