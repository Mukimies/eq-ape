import Foundation

public enum BiquadKind: Sendable { case peaking, lowShelf, highShelf, lowPass, highPass, notch, allPass, bandPass }

public struct BiquadSpec: Equatable, Sendable {
    public var kind: BiquadKind
    public var freq: Double
    public var gainDB: Double
    public var q: Double?
    public var slopeDBPerOct: Double?
    /// Bandwidth in octaves ("BW Oct" in Equalizer APO). Additive field: when set it takes precedence over `q`
    /// for non-shelf kinds (Equalizer APO: alpha = sin(w) * sinh(ln2/2 * BW * w / sin(w))). Ignored for shelves.
    public var bandwidthOct: Double?
    public init(kind: BiquadKind, freq: Double, gainDB: Double = 0, q: Double? = nil, slopeDBPerOct: Double? = nil,
                bandwidthOct: Double? = nil) {
        self.kind = kind; self.freq = freq; self.gainDB = gainDB; self.q = q; self.slopeDBPerOct = slopeDBPerOct
        self.bandwidthOct = bandwidthOct
    }
}

public struct GraphicEQPoint: Equatable, Sendable {
    public var freq: Double
    public var gainDB: Double
    public init(freq: Double, gainDB: Double) { self.freq = freq; self.gainDB = gainDB }
}

public enum Stage: Equatable, Sendable {
    case gain(dB: Double)
    case biquad(BiquadSpec)
    case graphicEQ(points: [GraphicEQPoint])
}

/// Stereo config. For mono / multichannel devices `left` drives channel 0 and `right` all other channels.
public struct EQConfig: Equatable, Sendable {
    public var left: [Stage]
    public var right: [Stage]
    public init(left: [Stage] = [], right: [Stage] = []) { self.left = left; self.right = right }
}

public struct ParseResult {
    public var config: EQConfig
    public var warnings: [String]
    public init(config: EQConfig, warnings: [String]) { self.config = config; self.warnings = warnings }
}
