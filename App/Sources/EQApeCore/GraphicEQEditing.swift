import EQCore
import Foundation

/// Editing operations on the points of a `GraphicEQ:` line, used by the editor's on-graph node editor and its band
/// sheet. Pure functions on `[GraphicEQPoint]`; points are kept sorted by frequency. The curve they describe is
/// EQCore's (`GraphicEQDesigner.interpolateDB`: linear in dB over log frequency, flat outside the end points).
///
/// The layouts mirror the choices of Equalizer APO's Graphic EQ (15 bands, 31 bands or variable); EQ Ape stores no
/// mode in the file (the line is plain `GraphicEQ: f1 g1; f2 g2; ...`), so the mode is inferred from the frequencies.
public enum GraphicEQEditing {
    /// 15 bands, 2/3 octave (ISO).
    public static let fixed15: [Double] = [25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000]
    /// 31 bands, 1/3 octave (ISO).
    public static let fixed31: [Double] = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
                                           1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000]

    public enum Layout: String, CaseIterable, Sendable {
        case fixed15, fixed31, variable
        public var frequencies: [Double]? {
            switch self { case .fixed15: return GraphicEQEditing.fixed15; case .fixed31: return GraphicEQEditing.fixed31; case .variable: return nil }
        }
        public var title: String {
            switch self { case .fixed15: return "15 bands"; case .fixed31: return "31 bands"; case .variable: return "Variable" }
        }
    }

    /// Starting points of "Add graphic EQ (variable)": flat, five nodes.
    public static let defaultVariable: [GraphicEQPoint] = [20, 100, 1000, 10000, 20000].map { GraphicEQPoint(freq: $0, gainDB: 0) }

    /// Allowed node frequencies and gains.
    public static let freqRange: ClosedRange<Double> = 1...24000
    public static let gainRange: ClosedRange<Double> = -30...30
    /// Smallest ratio between neighbouring node frequencies (about 1/70 octave).
    public static let minRatio = 1.01
    /// A line keeps at least this many nodes (Equalizer APO's parser needs two).
    public static let minNodes = 2

    /// The layout whose frequencies the points use exactly, else `.variable`.
    public static func layout(of points: [GraphicEQPoint]) -> Layout {
        let f = sorted(points).map(\.freq)
        if f == fixed15 { return .fixed15 }
        if f == fixed31 { return .fixed31 }
        return .variable
    }

    public static func sorted(_ points: [GraphicEQPoint]) -> [GraphicEQPoint] {
        points.enumerated().sorted { $0.element.freq < $1.element.freq || ($0.element.freq == $1.element.freq && $0.offset < $1.offset) }
            .map(\.element)
    }

    /// Curve value at `freq` (EQCore's interpretation).
    public static func value(_ points: [GraphicEQPoint], at freq: Double) -> Double {
        GraphicEQDesigner.interpolateDB(sorted(points), freq)
    }

    // MARK: rounding (values written by drags; typed values are kept as typed)

    /// Frequency step for dragged nodes: 0.1 Hz below 100 Hz, 1 Hz below 1 kHz, 10 Hz below 10 kHz, else 100 Hz.
    public static func freqStep(_ f: Double) -> Double { f < 100 ? 0.1 : f < 1000 ? 1 : f < 10000 ? 10 : 100 }

    /// Rounded so that `APOFormat.number` prints a short decimal (k / 10 is the double nearest to "k.k").
    public static func roundFreq(_ f: Double, _ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> Double {
        let s = freqStep(f)
        return s < 1 ? (f * 10).rounded(rule) / 10 : (f / s).rounded(rule) * s
    }
    public static func roundGain(_ g: Double) -> Double { (g * 10).rounded() / 10 }

    // MARK: operations

    /// Bounds for node `index` of sorted `points`: between its neighbours with `minRatio` spacing.
    public static func bounds(_ points: [GraphicEQPoint], index: Int) -> ClosedRange<Double> {
        var lo = freqRange.lowerBound, hi = freqRange.upperBound
        if index > 0 { lo = max(lo, points[index - 1].freq * minRatio) }
        if index + 1 < points.count { hi = min(hi, points[index + 1].freq / minRatio) }
        return lo...max(lo, hi)
    }

    /// Move node `index` (of the sorted points) to `freq`/`gain`. A component equal to the node's current value is
    /// kept unchanged (a click does not rewrite it); a changed one is rounded (unless `round` is false) and clamped:
    /// the node stays between its neighbours (`minRatio` spacing) and inside `freqRange`/`gainRange`, so the order
    /// never changes. Returns the new sorted points.
    public static func moveNode(_ points: [GraphicEQPoint], index: Int, freq: Double, gain: Double, round: Bool = true) -> [GraphicEQPoint] {
        var p = sorted(points)
        guard p.indices.contains(index) else { return p }
        let cur = p[index]
        if abs(freq - cur.freq) > 1e-9 {
            let b = bounds(p, index: index)
            if b.upperBound - b.lowerBound > 0 {
                var f = min(max(freq, b.lowerBound), b.upperBound)
                if round {
                    f = roundFreq(f)
                    if f < b.lowerBound { f = roundFreq(b.lowerBound, .up) }
                    if f > b.upperBound { f = roundFreq(b.upperBound, .down) }
                    if f < b.lowerBound || f > b.upperBound { f = cur.freq }   // gap smaller than one step
                }
                p[index].freq = f
            }
        }
        if abs(gain - cur.gainDB) > 1e-9 {
            let g = min(max(gain, gainRange.lowerBound), gainRange.upperBound)
            p[index].gainDB = round ? roundGain(g) : g
        }
        return p
    }

    /// Insert a node at `freq` with the curve's current value there (the response does not change). Returns the new
    /// sorted points and the new node's index, or nil when a node is already within `minRatio` of `freq`.
    public static func addNode(_ points: [GraphicEQPoint], freq: Double, round: Bool = true) -> (points: [GraphicEQPoint], index: Int)? {
        let p = sorted(points)
        var f = min(max(freq, freqRange.lowerBound), freqRange.upperBound)
        if round { f = roundFreq(f) }
        if p.contains(where: { max($0.freq, f) / min($0.freq, f) < minRatio }) { return nil }
        let g = GraphicEQDesigner.interpolateDB(p, f)
        let i = p.firstIndex(where: { $0.freq > f }) ?? p.count
        var n = p
        n.insert(GraphicEQPoint(freq: f, gainDB: round ? roundGain(g) : g), at: i)
        return (n, i)
    }

    /// Remove node `index`; nil when only `minNodes` remain.
    public static func removeNode(_ points: [GraphicEQPoint], index: Int) -> [GraphicEQPoint]? {
        var p = sorted(points)
        guard p.count > minNodes, p.indices.contains(index) else { return nil }
        p.remove(at: index)
        return p
    }

    /// The curve sampled at `freqs` (gains rounded to 0.1 dB): variable -> fixed conversion. Changes the response
    /// wherever the old curve had detail between the new frequencies.
    public static func resample(_ points: [GraphicEQPoint], to freqs: [Double]) -> [GraphicEQPoint] {
        let p = sorted(points)
        return freqs.map { GraphicEQPoint(freq: $0, gainDB: roundGain(GraphicEQDesigner.interpolateDB(p, $0))) }
    }

    /// Largest difference (dB) between two curves over 20 Hz-20 kHz and at both point sets' frequencies.
    public static func maxDifference(_ a: [GraphicEQPoint], _ b: [GraphicEQPoint]) -> Double {
        let sa = sorted(a), sb = sorted(b)
        var fs = (sa + sb).map(\.freq)
        for i in 0..<200 { fs.append(20 * pow(1000, Double(i) / 199)) }
        return fs.map { abs(GraphicEQDesigner.interpolateDB(sa, $0) - GraphicEQDesigner.interpolateDB(sb, $0)) }.max() ?? 0
    }
}

extension ConfigEditSession {
    /// Replace the points of the GraphicEQ line at `ref` (sorted; canonical Equalizer APO text, only that line
    /// changes). Consecutive calls with the same `coalesceKey` form one undo step until `endCoalescing()`.
    @discardableResult
    public func setGraphicEQ(_ points: [GraphicEQPoint], at ref: LineRef, name: String = "Edit Graphic EQ",
                             coalesceKey: String? = nil) -> Bool {
        let p = GraphicEQEditing.sorted(points)
        guard p.count >= GraphicEQEditing.minNodes else { return false }
        return edit(ref.url, name: name, coalesceKey: coalesceKey) { try $0.setCommand(.graphicEQ(points: p), at: ref.line) }
    }

    /// Points of the GraphicEQ command at `ref` (sorted), or nil when that line is not an active GraphicEQ line.
    public func graphicEQPoints(at ref: LineRef) -> [GraphicEQPoint]? {
        guard let d = workspace.document(ref.url), d.lines.indices.contains(ref.line),
              case .command(.graphicEQ(let p)) = d.lines[ref.line].kind else { return nil }
        return GraphicEQEditing.sorted(p)
    }
}
