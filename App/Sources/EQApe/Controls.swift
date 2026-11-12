import AppKit
import SwiftUI

/// Slider over a logarithmic range (frequency, Q). Arrow keys nudge it when focused (NSSlider behaviour).
struct LogSlider: View {
    var value: Double
    var range: ClosedRange<Double>
    var label: String
    var onChange: (Double) -> Void
    var onEnd: () -> Void

    var body: some View {
        Slider(value: Binding(get: { log10(min(max(value, range.lowerBound), range.upperBound)) },
                              set: { onChange(pow(10, $0)) }),
               in: log10(range.lowerBound)...log10(range.upperBound),
               onEditingChanged: { if !$0 { onEnd() } })
            .controlSize(.small)
            .accessibilityLabel(label)
            .accessibilityValue(String(format: "%.3g", value))
    }
}

struct LinearSlider: View {
    var value: Double
    var range: ClosedRange<Double>
    var label: String
    var onChange: (Double) -> Void
    var onEnd: () -> Void

    var body: some View {
        Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { onChange($0) }),
               in: range, onEditingChanged: { if !$0 { onEnd() } })
            .controlSize(.small)
            .accessibilityLabel(label)
            .accessibilityValue(String(format: "%.1f", value))
    }
}

/// Numeric text field that commits on Return or when focus leaves (locale decimal separator accepted).
struct NumberField: View {
    var value: Double
    var digits: Int
    var label: String
    var width: CGFloat = 58
    var onCommit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private func formatted(_ v: Double) -> String {
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = digits
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    var body: some View {
        TextField(label, text: $text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 11).monospacedDigit())
            .frame(width: width)
            .focused($focused)
            .labelsHidden()
            .accessibilityLabel(label)
            .onAppear { text = formatted(value) }
            .onChange(of: value) { _, v in if !focused { text = formatted(v) } }
            .onChange(of: focused) { _, f in if !f { commit() } }
            .onSubmit { commit() }
    }

    private func commit() {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        if let n = f.number(from: cleaned)?.doubleValue ?? Double(cleaned.replacingOccurrences(of: ",", with: ".")) {
            if abs(n - value) > 1e-12 { onCommit(n) }
        }
        text = formatted(value)
    }
}

/// Vertical slider for graphic-EQ bands: drag, click, scroll, arrow keys (when focused) and VoiceOver adjust.
struct VerticalSlider: View {
    var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.5
    var label: String
    var selected: Bool
    var onChange: (Double) -> Void
    var onEnd: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = range.upperBound - range.lowerBound
            let yv = h * CGFloat((range.upperBound - min(max(value, range.lowerBound), range.upperBound)) / span)
            let y0 = h * CGFloat((range.upperBound - 0) / span)
            ZStack(alignment: .top) {
                Capsule().fill(Color.secondary.opacity(0.18)).frame(width: 6)
                Rectangle().fill(Color.accentColor.opacity(0.75))
                    .frame(width: 6, height: abs(y0 - yv))
                    .offset(y: min(y0, yv))
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 14, height: 1).offset(y: y0)
                Circle()
                    .fill(selected || focused ? Color.accentColor : Color(nsColor: .controlColor))
                    .overlay(Circle().stroke(Color.secondary.opacity(0.6), lineWidth: 1))
                    .frame(width: 14, height: 14)
                    .offset(y: yv - 7)
                    .shadow(radius: 0.5)
            }
            .frame(width: geo.size.width, height: h, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let v = range.upperBound - Double(g.location.y / h) * span
                    onChange(((min(max(v, range.lowerBound), range.upperBound)) / 0.1).rounded() * 0.1)
                }
                .onEnded { _ in onEnd() })
        }
        .focusable()
        .focused($focused)
        .onKeyPress(.upArrow) { nudge(step); return .handled }
        .onKeyPress(.downArrow) { nudge(-step); return .handled }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%+.1f dB", value))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: nudge(step)
            case .decrement: nudge(-step)
            @unknown default: break
            }
        }
    }

    private func nudge(_ d: Double) {
        onChange(min(range.upperBound, max(range.lowerBound, ((value + d) * 10).rounded() / 10)))
        onEnd()
    }
}

/// Horizontal level meter (dBFS) with a peak-hold tick and a clip light.
struct LevelMeter: View {
    var label: String
    var db: Double
    var peakHold: Double
    var clip: Bool
    var enabled: Bool

    private func frac(_ d: Double) -> CGFloat { d.isFinite ? CGFloat(min(1, max(0, (d + 60) / 60))) : 0 }

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * frac(db))
                        .opacity(enabled ? 1 : 0)
                    if enabled && peakHold.isFinite {
                        Rectangle().fill(Color.primary.opacity(0.8)).frame(width: 2).offset(x: max(0, g.size.width * frac(peakHold) - 2))
                    }
                }
            }
            .frame(width: 90, height: 7)
            Text(enabled && db.isFinite ? String(format: "%5.1f", db) : "  –  ")
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            Circle().fill(clip ? Color.red : Color.secondary.opacity(0.25)).frame(width: 8, height: 8)
                .help(clip ? "Clipping" : "No clipping")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
        .accessibilityValue(enabled && db.isFinite ? String(format: "%.1f dBFS%@", db, clip ? ", clipping" : "") : "no signal")
    }
}
