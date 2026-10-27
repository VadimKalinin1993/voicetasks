import SwiftUI
import Observation

// MARK: - Priority

enum Priority: String, Codable, CaseIterable {
    case high, normal, low

    var label: String {
        switch self {
        case .high: return "Важно"
        case .normal: return "Обычно"
        case .low: return "Потом"
        }
    }

    var color: Color {
        switch self {
        case .high: return .red
        case .normal: return .blue
        case .low: return .gray
        }
    }

    var rank: Int {
        switch self {
        case .high: return 0
        case .normal: return 1
        case .low: return 2
        }
    }

    var next: Priority {
        switch self {
        case .high: return .normal
        case .normal: return .low
        case .low: return .high
        }
    }

    init(loose: String?) {
        self = Priority(rawValue: loose ?? "") ?? .normal
    }
}

// MARK: - Task

struct TaskItem: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var due: String?          // "yyyy-MM-dd" или nil
    var priority: Priority
    var created: Date
}

/// Задача, которую распознал Gemini, но которая ещё не в списке.
struct NewTask: Equatable {
    var title: String
    var due: String?
    var priority: Priority
}

struct TaskSection: Identifiable {
    let id: String
    let title: String
    let overdue: Bool
    let items: [TaskItem]
}

func tasksCount(_ n: Int) -> String {
    let a = n % 10, b = n % 100
    let word: String
    if a == 1 && b != 11 {
        word = "задача"
    } else if a >= 2 && a <= 4 && (b < 12 || b > 14) {
        word = "задачи"
    } else {
        word = "задач"
    }
    return "\(n) \(word)"
}

// MARK: - Dates

@MainActor
enum Dates {
    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let dayMonth = ru("d MMMM")
    static let dayMonthYear = ru("d MMMM yyyy")
    static let weekday = ru("EEEE")

    private static func ru(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = format
        return f
    }

    static func today() -> String { iso.string(from: Date()) }
    static func todayWeekday() -> String { weekday.string(from: Date()) }
    static func nowTime() -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
    static func date(_ s: String) -> Date? { iso.date(from: s) }

    /// Принимает только корректную дату "yyyy-MM-dd".
    static func valid(_ s: String?) -> String? {
        guard let s, s.count == 10, date(s) != nil else { return nil }
        return s
    }

    static func dayDiff(_ s: String) -> Int? {
        guard let d = date(s) else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day
    }

    static func longDate(_ d: Date) -> String {
        let cal = Calendar.current
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: Date())
        return (sameYear ? dayMonth : dayMonthYear).string(from: d)
    }

    /// Заголовок секции целиком описывает срок, поэтому у самих задач даты нет.
    static func sectionTitle(_ s: String?) -> (title: String, overdue: Bool) {
        guard let s, let n = dayDiff(s), let d = date(s) else { return ("Без срока", false) }
        if n < 0 { return (n == -1 ? "Просрочено · вчера" : "Просрочено · \(longDate(d))", true) }
        if n == 0 { return ("Сегодня", false) }
        if n == 1 { return ("Завтра", false) }
        let wd = weekday.string(from: d)
        return (wd.prefix(1).uppercased() + wd.dropFirst() + ", " + longDate(d), false)
    }
}

// MARK: - Store

@MainActor
@Observable
final class TaskStore {
    private(set) var tasks: [TaskItem] = []
    /// Только что добавленные или изменённые задачи — на секунду подсвечиваются.
    var freshIDs: Set<String> = []
    @ObservationIgnored private var lastRemoved: [TaskItem] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }()

    init() { load() }

    var title: String { tasks.isEmpty ? "Задач нет" : tasksCount(tasks.count) }

    var sections: [TaskSection] {
        var groups: [String: [TaskItem]] = [:]
        for t in tasks { groups[t.due ?? "~none", default: []].append(t) }
        return groups.keys.sorted().map { key in
            let items = (groups[key] ?? []).sorted {
                ($0.priority.rank, $0.created) < ($1.priority.rank, $1.created)
            }
            let head = Dates.sectionTitle(key == "~none" ? nil : key)
            return TaskSection(id: key, title: head.title, overdue: head.overdue, items: items)
        }
    }

    func contains(_ id: String) -> Bool { tasks.contains { $0.id == id } }

    func add(_ list: [NewTask]) {
        var ids: [String] = []
        for n in list {
            let id = makeID()
            tasks.append(TaskItem(id: id, title: n.title, due: n.due, priority: n.priority, created: Date()))
            ids.append(id)
        }
        save()
        markFresh(ids)
    }

    @discardableResult
    func complete(ids: Set<String>) -> [TaskItem] {
        let removed = tasks.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return [] }
        tasks.removeAll { ids.contains($0.id) }
        lastRemoved = removed
        save()
        return removed
    }

    func undo() {
        for t in lastRemoved where !contains(t.id) { tasks.append(t) }
        lastRemoved = []
        save()
    }

    func setPriority(_ id: String, _ p: Priority) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].priority = p
        save()
    }

    func setDue(_ id: String, _ due: String?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].due = due
        save()
    }

    func markFresh(_ ids: [String]) {
        freshIDs.formUnion(ids)
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            self.freshIDs.subtract(ids)
        }
    }

    private func makeID() -> String {
        var id: String
        repeat { id = String(UUID().uuidString.prefix(6)).lowercased() } while contains(id)
        return id
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([TaskItem].self, from: data) else { return }
        tasks = list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
