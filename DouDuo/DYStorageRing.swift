import SwiftUI

struct DYStorageRing: View {
    let usage: DYStorageFiles.Usage
    let totalLabel: String
    let clearing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title3) private var scaledSize: CGFloat = 158
    private var diameter: CGFloat { min(scaledSize, 200) }
    private var lineWidth: CGFloat { diameter * 0.20 }
    static let appColor = Color.blue

    static func color(for category: DYStorageFiles.Category) -> Color {
        switch category {
        case .video: .teal
        case .offline: .green
        case .images: .orange
        case .web: .indigo
        case .diagnostics: .pink
        case .other: .gray
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.secondary.opacity(0.18), lineWidth: lineWidth)
            slices
                .opacity(clearing ? 0.28 : 1)
            if clearing && !reduceMotion {
                TimelineView(.animation) { context in
                    let turns = context.date.timeIntervalSinceReferenceDate / 0.9
                    Circle()
                        .trim(from: 0, to: 0.24)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .padding(lineWidth / 2)
                        .rotationEffect(.degrees(turns.truncatingRemainder(dividingBy: 1) * 360 - 90))
                }
            }
            Text(totalLabel)
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(width: diameter - 2 * lineWidth - 8)
                .contentTransition(reduceMotion ? .identity : .numericText())
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("总占用")
        .accessibilityValue(totalLabel)
        .accessibilityIdentifier("storage.total")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: usage)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: clearing)
    }

    private var slices: some View {
        let segments = segments
        let radius = (diameter - lineWidth) / 2
        let hasMultipleSlices = segments.lazy.filter { $0.fraction > 0 }.prefix(2).count == 2
        return ZStack {
            ForEach(segments) { segment in
                let gap = hasMultipleSlices ? min(0.002, segment.fraction / 3) : 0
                Circle()
                    .trim(from: segment.start + gap, to: segment.end - gap)
                    .stroke(segment.color, lineWidth: lineWidth)
                    .rotationEffect(.degrees(-90))
                    .padding(lineWidth / 2)

                if segment.fraction >= 0.075 {
                    let angle = (segment.start + segment.end) * .pi - .pi / 2
                    Text(segment.fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: diameter * 0.078, weight: .semibold))
                        .foregroundStyle(segment.labelColor)
                        .offset(x: cos(angle) * radius, y: sin(angle) * radius)
                        .transition(.opacity)
                }
            }
        }
    }

    private var segments: [Segment] {
        let values: [(Color, Color, Int64)] = [(Self.appColor, .white, usage.app)]
            + DYStorageFiles.Category.allCases.map { category in
                let labelColor: Color = category == .images || category == .video || category == .offline ? .black : .white
                return (Self.color(for: category), labelColor, usage.categories[category, default: 0])
            }
        let total = Double(max(usage.total, 1))
        var bytes: Int64 = 0
        return values.enumerated().map { index, value in
            let start = Double(bytes) / total
            bytes += value.2
            return Segment(id: index, start: start, end: Double(bytes) / total, color: value.0, labelColor: value.1)
        }
    }

    private struct Segment: Identifiable {
        let id: Int
        let start: Double
        let end: Double
        let color: Color
        let labelColor: Color
        var fraction: Double { end - start }
    }
}
