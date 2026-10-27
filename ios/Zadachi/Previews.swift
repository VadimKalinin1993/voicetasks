import SwiftUI

// Предпросмотр экранов в Xcode (Editor → Canvas). На телефон не влияет.

@MainActor
private enum PreviewData {
    static func day(_ offset: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        return Dates.iso.string(from: d)
    }

    static func ago(days: Int, hours: Int = 0) -> Date {
        Date().addingTimeInterval(-Double(days * 86_400 + hours * 3_600))
    }

    static let tasks: [TaskItem] = [
        TaskItem(id: "p1", title: "Оплатить интернет", due: day(-2), priority: .high, created: ago(days: 3)),
        TaskItem(id: "p2", title: "Английский язык в 16:00", due: day(0), priority: .high, created: ago(days: 1)),
        TaskItem(id: "p3", title: "Купить корм коту", due: day(0), priority: .normal, created: ago(days: 1)),
        TaskItem(id: "p4", title: "Обновить макеты в Figma и отправить ссылку команде в Slack до вечера", due: day(1), priority: .normal, created: ago(days: 1)),
        TaskItem(id: "p5", title: "Подготовить отчёт по юзабилити-тесту", due: day(3), priority: .high, created: ago(days: 2)),
        TaskItem(id: "p6", title: "Разобрать фотографии", due: nil, priority: .low, created: ago(days: 5))
    ]

    static let done: [TaskItem] = [
        TaskItem(id: "d1", title: "Позвонить маме", due: day(0), priority: .high, created: ago(days: 1), completed: ago(days: 0, hours: 1)),
        TaskItem(id: "d2", title: "Сделать ревью PR в GitHub", due: day(0), priority: .normal, created: ago(days: 2), completed: ago(days: 0, hours: 3)),
        TaskItem(id: "d3", title: "Записаться к стоматологу", due: day(-1), priority: .normal, created: ago(days: 4), completed: ago(days: 1)),
        TaskItem(id: "d4", title: "Купить продукты", due: day(-6), priority: .low, created: ago(days: 7), completed: ago(days: 6))
    ]

    static func environment(empty: Bool = false) -> (TaskStore, Assistant) {
        let store = TaskStore(preview: empty ? [] : tasks, done: empty ? [] : done)
        return (store, Assistant(store: store))
    }
}

#Preview("Задачи") {
    let (store, assistant) = PreviewData.environment()
    return ContentView()
        .environment(store)
        .environment(assistant)
}

#Preview("Задачи — тёмная тема") {
    let (store, assistant) = PreviewData.environment()
    return ContentView()
        .environment(store)
        .environment(assistant)
        .preferredColorScheme(.dark)
}

#Preview("Выполнено") {
    let (store, assistant) = PreviewData.environment()
    return ContentView(startInDone: true)
        .environment(store)
        .environment(assistant)
}

#Preview("Пусто") {
    let (store, assistant) = PreviewData.environment(empty: true)
    return ContentView()
        .environment(store)
        .environment(assistant)
}

#Preview("Кнопка микрофона") {
    VStack(spacing: 24) {
        MicButton(phase: .idle, level: 0) {}
        MicButton(phase: .listening, level: 0.6) {}
        MicButton(phase: .thinking, level: 0) {}
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
