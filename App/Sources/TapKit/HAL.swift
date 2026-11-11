import CoreAudio
import Foundation

// Thin helpers over the C HAL property API (AudioHardware.h / AudioHardwareBase.h), adapted from
// poc-tap. The C API is used because the Swift AudioHardwareSystem overlay is macOS 15+, while the
// tap API itself is macOS 14.2+.

public struct HALError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let what: String
    public var description: String { "\(what) failed: \(osStatusString(status))" }
}

public func osStatusString(_ s: OSStatus) -> String {
    let u = UInt32(bitPattern: s)
    let bytes = [UInt8((u >> 24) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 8) & 0xff), UInt8(u & 0xff)]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return "\(s) ('\(String(decoding: bytes, as: UTF8.self))')"
    }
    return "\(s)"
}

func fourCC(_ u: UInt32) -> String {
    let bytes = [UInt8((u >> 24) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 8) & 0xff), UInt8(u & 0xff)]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(decoding: bytes, as: UTF8.self) }
    return String(format: "0x%08x", u)
}

@inline(__always)
func check(_ s: OSStatus, _ what: @autoclosure () -> String) throws {
    if s != noErr { throw HALError(status: s, what: what()) }
}

public func addr(_ sel: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
}

public enum HAL {
    public static let system = AudioObjectID(kAudioObjectSystemObject)

    public static func has(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
        var a = a
        return AudioObjectHasProperty(obj, &a)
    }

    public static func get<T: BitwiseCopyable>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ initial: T) throws -> T {
        var a = a
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value), "get \(fourCC(a.mSelector)) on \(obj)")
        return value
    }

    public static func getArray<T: BitwiseCopyable>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ zero: T) throws -> [T] {
        var a = a
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size), "size \(fourCC(a.mSelector))")
        let n = Int(size) / MemoryLayout<T>.stride
        if n == 0 { return [] }
        var arr = [T](repeating: zero, count: n)
        try arr.withUnsafeMutableBytes { raw in
            try check(AudioObjectGetPropertyData(obj, &a, 0, nil, &size, raw.baseAddress!), "get \(fourCC(a.mSelector))")
        }
        return Array(arr.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    public static func getString(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) throws -> String {
        var a = a
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &cf), "get \(fourCC(a.mSelector))")
        guard let s = cf?.takeRetainedValue() else { return "" }
        return s as String
    }

    public static func set<T: BitwiseCopyable>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: T) throws {
        var a = a
        var v = value
        try check(AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v),
                  "set \(fourCC(a.mSelector)) on \(obj)")
    }

    // MARK: devices

    public static func allDevices() -> [AudioObjectID] {
        (try? getArray(system, addr(kAudioHardwarePropertyDevices), AudioObjectID(0))) ?? []
    }

    public static func name(_ dev: AudioObjectID) -> String {
        (try? getString(dev, addr(kAudioObjectPropertyName))) ?? "?"
    }

    public static func uid(_ dev: AudioObjectID) -> String? {
        try? getString(dev, addr(kAudioDevicePropertyDeviceUID))
    }

    public static func channels(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func sampleRate(_ dev: AudioObjectID) -> Double {
        (try? get(dev, addr(kAudioDevicePropertyNominalSampleRate), Float64(0))) ?? 0
    }

    public static func transportType(_ dev: AudioObjectID) -> UInt32 {
        (try? get(dev, addr(kAudioDevicePropertyTransportType), UInt32(0))) ?? 0
    }

    public static func isAlive(_ dev: AudioObjectID) -> Bool {
        (uint32(dev, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0
    }

    public static func defaultOutput() -> AudioObjectID? {
        guard let d = try? get(system, addr(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)),
              d != kAudioObjectUnknown else { return nil }
        return d
    }

    public static func setDefaultOutput(_ dev: AudioObjectID) throws {
        try set(system, addr(kAudioHardwarePropertyDefaultOutputDevice), dev)
    }

    public static func outputDevices() -> [AudioObjectID] {
        allDevices().filter { channels($0, scope: kAudioObjectPropertyScopeOutput) > 0 }
    }

    /// Find a device by exact UID, then exact name, then case-insensitive name prefix.
    public static func findDevice(_ key: String) -> AudioObjectID? {
        let devs = allDevices()
        if let d = devs.first(where: { uid($0) == key }) { return d }
        if let d = devs.first(where: { name($0) == key }) { return d }
        return devs.first(where: { name($0).lowercased().hasPrefix(key.lowercased()) })
    }

    public static func device(forUID key: String) -> AudioObjectID? {
        allDevices().first(where: { uid($0) == key })
    }

    public static func streams(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        (try? getArray(dev, addr(kAudioDevicePropertyStreams, scope), AudioObjectID(0))) ?? []
    }

    public static func streamFormat(_ stream: AudioObjectID) -> AudioStreamBasicDescription? {
        try? get(stream, addr(kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription())
    }

    public static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var p = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj),
                  "translate PID to process object")
        return obj
    }

    public static func uint32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        let a = addr(sel, scope)
        guard has(obj, a) else { return nil }
        return try? get(obj, a, UInt32(0))
    }

    /// Visible process taps (only public ones from other processes; our own private ones too).
    public static func tapList() -> [AudioObjectID] {
        (try? getArray(system, addr(kAudioHardwarePropertyTapList), AudioObjectID(0))) ?? []
    }

    /// A compact description of what an engine depends on: if this changes, the engine is rebuilt.
    public static func formatSignature(_ dev: AudioObjectID) -> String {
        var parts = ["sr=\(sampleRate(dev))", "out=\(channels(dev, scope: kAudioObjectPropertyScopeOutput))"]
        if let s = streams(dev, scope: kAudioObjectPropertyScopeOutput).first, let f = streamFormat(s) {
            parts.append("fmt=\(f.mSampleRate)/\(f.mChannelsPerFrame)/\(f.mFormatFlags)/\(f.mBitsPerChannel)")
        }
        return parts.joined(separator: ",")
    }
}

public func describe(_ f: AudioStreamBasicDescription) -> String {
    let flags = f.mFormatFlags
    let isFloat = flags & kAudioFormatFlagIsFloat != 0
    let nonInt = flags & kAudioFormatFlagIsNonInterleaved != 0
    return "\(fourCC(f.mFormatID)) \(f.mSampleRate) Hz \(f.mChannelsPerFrame) ch \(f.mBitsPerChannel)-bit " +
        "\(isFloat ? "float" : "int") \(nonInt ? "non-interleaved" : "interleaved")"
}
