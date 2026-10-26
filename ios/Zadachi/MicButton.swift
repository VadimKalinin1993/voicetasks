import SwiftUI
import UIKit

struct MicButton: View {
    let phase: Phase
    let level: Float
    let action: () -> Void

    private let size: CGFloat = 76
    static let gradient = LinearGradient(
        colors: [
            Color(red: 0.18, green: 0.42, blue: 1.0),
            Color(red: 0.12, green: 0.64, blue: 1.0),
            Color(red: 0.42, green: 0.36, blue: 1.0)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    private var active: Bool { phase == .listening || phase == .speaking }

    var body: some View {
        Button(action: action) {
            ZStack {
                if active {
                    Ripple(size: size, period: phase == .listening ? 1.8 : 2.6)
                }
                if phase == .listening {
                    Circle()
                        .fill(Color.blue.opacity(0.18))
                        .frame(width: size + 14, height: size + 14)
                        .scaleEffect(1 + CGFloat(level) * 0.32)
                        .animation(.linear(duration: 0.1), value: level)
                }
                if phase == .thinking {
                    Spinner(size: size + 14)
                }
                Circle()
                    .fill(active ? AnyShapeStyle(Self.gradient) : AnyShapeStyle(Color.primary))
                    .frame(width: size, height: size)
                    .shadow(color: active ? Color.blue.opacity(0.4) : .clear, radius: 14, y: 6)
                Image(systemName: active ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Color(.systemBackground))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: size * 1.6, height: size * 1.6)
            .contentShape(Circle())
            .animation(.snappy, value: phase)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(phase == .listening ? "Закончить запись" : "Говорить")
    }
}

/// Две волны, расходящиеся от кнопки.
private struct Ripple: View {
    let size: CGFloat
    let period: Double

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<2, id: \.self) { i in
                    let p = (t / period + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .fill(MicButton.gradient)
                        .frame(width: size, height: size)
                        .scaleEffect(1 + 0.55 * p)
                        .opacity(0.35 * (1 - p))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Градиентное кольцо, пока Gemini думает.
private struct Spinner: View {
    let size: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = (t / 0.9).truncatingRemainder(dividingBy: 1) * 360
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(
                    AngularGradient(
                        colors: [Color.blue.opacity(0), Color(red: 0.18, green: 0.42, blue: 1.0), Color(red: 0.12, green: 0.64, blue: 1.0), Color(red: 0.42, green: 0.36, blue: 1.0)],
                        center: .center, startAngle: .degrees(0), endAngle: .degrees(260)
                    ),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(angle))
        }
        .allowsHitTesting(false)
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
