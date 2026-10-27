import UIKit
import Network

/// Распознанная фраза, на которую ещё не пришёл ответ Gemini.
/// Лежит на диске, пока ответ не получен: если приложение закрыли во время запроса
/// или пропала сеть, фраза уйдёт снова при следующем открытии (или когда появится связь).
struct QueuedPhrase: Codable, Identifiable, Equatable {
    var id: String
    var heard: String
    var created: Date
    /// Контекст на момент диктовки (JSON): «завтра» и «в 16:00» считаются от того момента,
    /// когда фразу сказали, а не от момента повторной отправки.
    var context: String
}

@MainActor
final class PhraseQueue {
    private(set) var items: [QueuedPhrase] = []
    private let url: URL?

    /// inMemory — для превью: ничего не читается и не пишется на диск.
    init(inMemory: Bool = false) {
        if inMemory {
            url = nil
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("queue.json")
        }
        load()
    }

    @discardableResult
    func enqueue(heard: String, context: [String: Any]) -> QueuedPhrase {
        let json = (try? JSONSerialization.data(withJSONObject: context)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let item = QueuedPhrase(id: UUID().uuidString, heard: heard, created: Date(), context: json)
        items.append(item)
        save()
        return item
    }

    func remove(_ id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        save()
    }

    /// Контекст фразы для отправки: даты — как в момент диктовки, список задач — текущий
    /// (чтобы правка «сделай отчёт важным» нашла задачу, даже если список с тех пор менялся).
    func context(for item: QueuedPhrase, currentTasks: [[String: Any]]) -> [String: Any] {
        var ctx = (try? JSONSerialization.jsonObject(with: Data(item.context.utf8))) as? [String: Any] ?? [:]
        ctx["current_tasks"] = currentTasks
        return ctx
    }

    /// Если фраза была ответом на вопрос о сроке — задачи из этого вопроса.
    func pendingTasks(of item: QueuedPhrase) -> [NewTask]? {
        let ctx = (try? JSONSerialization.jsonObject(with: Data(item.context.utf8))) as? [String: Any]
        guard let list = ctx?["pending"] as? [[String: Any]] else { return nil }
        let tasks = list.compactMap { d -> NewTask? in
            guard let title = d["title"] as? String, !title.isEmpty else { return nil }
            return NewTask(title: title, due: Dates.valid(d["due"] as? String), priority: Priority(loose: d["priority"] as? String))
        }
        return tasks.isEmpty ? nil : tasks
    }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([QueuedPhrase].self, from: data) else { return }
        items = list
    }

    private func save() {
        guard let url else { return }
        if items.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Фоновое время у iOS: пока идёт запрос к Gemini, приложение можно свернуть —
/// iOS даст ему ещё немного поработать, и ответ успеет дойти.
@MainActor
final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    static func begin(_ name: String) -> BackgroundTime {
        let t = BackgroundTime()
        t.id = UIApplication.shared.beginBackgroundTask(withName: name) { t.end() }
        return t
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Следит за сетью: когда связь появляется, вызывает onOnline (на главном потоке).
@MainActor
final class NetworkWatcher {
    private let monitor = NWPathMonitor()

    init(onOnline: @escaping @MainActor () -> Void) {
        monitor.pathUpdateHandler = Self.makeHandler(onOnline)
        monitor.start(queue: DispatchQueue(label: "zadachi.network"))
    }

    nonisolated private static func makeHandler(_ onOnline: @escaping @MainActor () -> Void) -> @Sendable (NWPath) -> Void {
        let box = UncheckedBox(onOnline)
        return { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in box.value() }
        }
    }
}

nonisolated final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
