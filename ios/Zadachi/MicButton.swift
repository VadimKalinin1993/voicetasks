import SwiftUI
import UIKit

/// Стеклянная кнопка микрофона. Во время записи и обработки под стеклом
/// движется размытый синий свет — он виден сквозь стекло и чуть выходит за его край.
struct MicButton: View {
    let phase: Phase
    let level: Float
    /// Запрос к Gemini затянулся — вместо микрофона значок «стоп», нажатие обрывает запрос.
    var stoppable = false
    let action: () -> Void

    private var showsStop: Bool {
        phase == .listening || phase == .speaking || (phase == .thinking && stoppable)
    }

    private let size: CGFloat = 76

    static let blue = Color(red: 0.18, green: 0.42, blue: 1.0)
    static let cyan = Color(red: 0.12, green: 0.64, blue: 1.0)
    static let violet = Color(red: 0.42, green: 0.36, blue: 1.0)

    private var active: Bool { phase != .idle }

    var body: some View {
        Button(action: action) {
            ZStack {
                Glow(phase: phase, level: level, size: size)
                    .opacity(active ? 1 : 0)

                GlassDisc(size: size)

                Image(systemName: showsStop ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(active ? Self.blue : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: size * 1.6, height: size * 1.6)
            .contentShape(Circle())
            .animation(.snappy, value: phase)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(phase == .listening ? "Закончить запись" : (phase == .thinking && stoppable ? "Остановить запрос" : "Говорить"))
    }
}

/// Сам стеклянный круг: Liquid Glass на iOS 26+, на старых системах — системный материал.
private struct GlassDisc: View {
    let size: CGFloat

    var body: some View {
        if #available(iOS 26.0, *) {
            Circle()
                .fill(Color.clear)
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }
}

/// Размытый свет под стеклом.
/// Запись — свет по всему кругу, медленно вращается и «дышит» в такт голосу.
/// Обработка — яркая дуга бежит по кругу, как индикатор загрузки.
/// Вопрос голосом — спокойная пульсация.
private struct Glow: View {
    let phase: Phase
    let level: Float
    let size: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let lvl = CGFloat(level)

            ZStack {
                switch phase {
                case .thinking:
                    arc(trim: 0.62)
                        .rotationEffect(.degrees((t / 1.0).truncatingRemainder(dividingBy: 1) * 360))
                case .listening:
                    arc(trim: 1)
                        .rotationEffect(.degrees((t / 4).truncatingRemainder(dividingBy: 1) * 360))
                        .scaleEffect(1 + lvl * 0.18)
                case .speaking:
                    arc(trim: 1)
                        .rotationEffect(.degrees((t / 6).truncatingRemainder(dividingBy: 1) * 360))
                        .scaleEffect(1 + 0.06 * CGFloat(sin(t * 3)))
                case .idle:
                    EmptyView()
                }
            }
            .animation(.linear(duration: 0.1), value: level)
        }
        .allowsHitTesting(false)
    }

    /// Широкое кольцо, размытое в мягкое свечение.
    private func arc(trim: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: trim)
            .stroke(
                AngularGradient(
                    colors: trim < 1
                        ? [MicButton.blue.opacity(0), MicButton.blue, MicButton.cyan, MicButton.violet]
                        : [MicButton.blue, MicButton.cyan, MicButton.violet, MicButton.blue],
                    center: .center,
                    startAngle: .degrees(0),
                    endAngle: .degrees(360 * Double(trim))
                ),
                style: StrokeStyle(lineWidth: 14, lineCap: .round)
            )
            .frame(width: size - 6, height: size - 6)
            .blur(radius: 14)
            .opacity(0.9)
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
