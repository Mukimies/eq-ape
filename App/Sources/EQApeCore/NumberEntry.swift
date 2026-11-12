import Foundation

/// Parsing and committing of the editor's number fields (the logic of `NumberField`, testable without a UI).
public struct NumberEntry: Sendable {
    public var digits: Int
    public var locale: Locale

    public init(digits: Int, locale: Locale = .current) {
        self.digits = digits
        self.locale = locale
    }

    public func format(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = digits
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// The locale's decimal separator, or "." or "," as decimal separator; no grouping ("4,5" is never 45).
    public func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        if let n = f.number(from: cleaned)?.doubleValue { return n }
        return Double(cleaned.replacingOccurrences(of: ",", with: "."))
    }

    /// What to commit (nil = nothing changes) and the text to show afterwards. The text shows the committed value,
    /// not `current`: right after a commit `current` is still the old value until the view updates, and a second
    /// commit (Return, then the focus change it causes) must not write that old value back.
    public func commit(text: String, current: Double) -> (value: Double?, text: String) {
        guard let n = parse(text) else { return (nil, format(current)) }
        if abs(n - current) > 1e-12 { return (n, format(n)) }
        return (nil, format(n))
    }
}
