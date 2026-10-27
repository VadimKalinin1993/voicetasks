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
        case .high: return .orange
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

    /// Незнакомое значение в файле не ломает чтение списка — считаем его «Обычно».
    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = Priority(loose: raw)
    }
}

// MARK: - Task

struct TaskItem: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var due: String?          // "yyyy-MM-dd" или nil
    var priority: Priority
    var created: Date
    /// Когда задачу закрыли (только у задач в истории).
    var completed: Date? = nil
    /// Место в списке дня, если задачу двигали вручную.
    var position: Double? = nil

    /// Порядок внутри дня: сначала то, что расставлено вручную, потом по приоритету и времени создания.
    var sortKey: Double {
        position ?? (1e12 + Double(priority.rank) * 1e10 + created.timeIntervalSince1970)
    }
}

extension TaskItem {
    private enum CodingKeys: String, CodingKey {
        case id, title, due, priority, created, completed, position
    }

    /// Мягкое чтение: старые файлы без новых полей и с неожиданными значениями читаются,
    /// обязательны только id и текст.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        let dueRaw: String? = try? c.decodeIfPresent(String.self, forKey: .due)
        due = Dates.valid(dueRaw)
        let p: Priority? = try? c.decodeIfPresent(Priority.self, forKey: .priority)
        priority = p ?? .normal
        let made: Date? = try? c.decodeIfPresent(Date.self, forKey: .created)
        created = made ?? Date()
        completed = try? c.decodeIfPresent(Date.self, forKey: .completed)
        position = try? c.decodeIfPresent(Double.self, forKey: .position)
    }
}

/// Элемент массива, который может не прочитаться: тогда пропускаем только его, а не весь файл.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(T.self)
    }
}

/// Чтение файлов со списками задач.
enum TaskFile {
    /// complete = false, если часть файла (или весь) прочитать не удалось.
    static func decode(_ data: Data) -> (items: [TaskItem], complete: Bool) {
        guard let list = try? JSONDecoder().decode([Lossy<TaskItem>].self, from: data) else { return ([], false) }
        let items = list.compactMap(\.value)
        return (items, items.count == list.count)
    }

    /// Читает файл. Если прочитался не целиком — кладёт рядом копию оригинала,
    /// чтобы следующее сохранение не стёрло то, что не удалось разобрать.
    static func read(_ url: URL) -> [TaskItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }   // файла ещё нет
        let result = decode(data)
        if !result.complete {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingPathExtension().appendingPathExtension("backup-\(stamp).json")
            try? data.write(to: backup, options: .atomic)
        }
        return result.items
    }
}

/// Задача, которую распознал Gemini, но которая ещё не в списке.
struct NewTask: Codable, Equatable {
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
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let dayMonth = ru("d MMMM")
    static let dayMonthYear = ru("d MMMM yyyy")
    static let weekday = ru("EEEE")

    private static func ru(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = .autoupdatingCurrent
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

    /// Принимает только корректную дату "yyyy-MM-dd". Несуществующие даты вроде 30 февраля
    /// форматтер «исправляет» на 2 марта — такие отсекаем сверкой туда-обратно.
    static func valid(_ s: String?) -> String? {
        guard let s, s.count == 10, let d = date(s), iso.string(from: d) == s else { return nil }
        return s
    }

    static func dayDiff(_ s: String, now: Date = Date()) -> Int? {
        guard let d = date(s) else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day
    }

    static func longDate(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: now)
        return (sameYear ? dayMonth : dayMonthYear).string(from: d)
    }

    /// Заголовок секции в истории — день, когда задачу закрыли.
    static func doneSectionTitle(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
        if n == 0 { return "Сегодня" }
        if n == 1 { return "Вчера" }
        let wd = weekday.string(from: d)
        return wd.prefix(1).uppercased() + wd.dropFirst() + ", " + longDate(d, now: now)
    }

    /// Заголовок секции целиком описывает срок, поэтому у самих задач даты нет.
    static func sectionTitle(_ s: String?, now: Date = Date()) -> (title: String, overdue: Bool) {
        guard let s, let n = dayDiff(s, now: now), let d = date(s) else { return ("Без срока", false) }
        if n < 0 { return (n == -1 ? "Просрочено · вчера" : "Просрочено · \(longDate(d, now: now))", true) }
        if n == 0 { return ("Сегодня", false) }
        if n == 1 { return ("Завтра", false) }
        let wd = weekday.string(from: d)
        return (wd.prefix(1).uppercased() + wd.dropFirst() + ", " + longDate(d, now: now), false)
    }
}

// MARK: - Store

@MainActor
@Observable
final class TaskStore {
    private(set) var tasks: [TaskItem] = []
    /// История выполненных задач. Хранится на телефоне без ограничения по сроку.
    private(set) var done: [TaskItem] = []
    /// Только что добавленные или изменённые задачи — на секунду подсвечиваются.
    var freshIDs: Set<String> = []
    /// Текущий день. Меняется после полуночи и при открытии приложения на следующий день —
    /// тогда заголовки «Сегодня», «Завтра», «Просрочено» пересчитываются сами.
    private(set) var today = Dates.today()
    @ObservationIgnored private var lastRemoved: [TaskItem] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }()
    private let doneURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("done.json")
    }()

    init() { load() }

    /// Для предпросмотра в Xcode: задачи в памяти, ничего не пишется на диск.
    init(preview tasks: [TaskItem], done: [TaskItem]) {
        self.tasks = tasks
        self.done = done
        self.isPreview = true
    }
    @ObservationIgnored private(set) var isPreview = false

    var title: String { tasks.isEmpty ? "Задач нет" : tasksCount(tasks.count) }

    /// Вызывается при открытии приложения и в полночь.
    func refreshDay() {
        let now = Dates.today()
        if now != today { today = now }
    }

    var sections: [TaskSection] {
        _ = today   // заголовки зависят от текущего дня
        var groups: [String: [TaskItem]] = [:]
        for t in tasks { groups[t.due ?? "~none", default: []].append(t) }
        return groups.keys.sorted().map { key in
            let items = (groups[key] ?? []).sorted { $0.sortKey < $1.sortKey }
            let head = Dates.sectionTitle(key == "~none" ? nil : key)
            return TaskSection(id: key, title: head.title, overdue: head.overdue, items: items)
        }
    }

    /// Выполненные задачи по дням закрытия, свежие сверху.
    var doneSections: [TaskSection] {
        _ = today
        let cal = Calendar.current
        var groups: [Date: [TaskItem]] = [:]
        for t in done {
            let day = cal.startOfDay(for: t.completed ?? t.created)
            groups[day, default: []].append(t)
        }
        return groups.keys.sorted(by: >).map { day in
            let items = (groups[day] ?? []).sorted { ($0.completed ?? $0.created) > ($1.completed ?? $1.created) }
            return TaskSection(id: "done-\(day.timeIntervalSince1970)", title: Dates.doneSectionTitle(day), overdue: false, items: items)
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
        let now = Date()
        done.append(contentsOf: removed.map { var t = $0; t.completed = now; return t })
        save()
        saveDone()
        return removed
    }

    func undo() {
        let ids = Set(lastRemoved.map(\.id))
        for t in lastRemoved where !contains(t.id) { tasks.append(t) }
        done.removeAll { ids.contains($0.id) }
        lastRemoved = []
        save()
        saveDone()
    }

    /// Перетаскивание задачи внутри дня (долгое нажатие и движение пальцем).
    func move(section id: String, from: IndexSet, to: Int) {
        guard var items = sections.first(where: { $0.id == id })?.items else { return }
        items.move(fromOffsets: from, toOffset: to)
        for (i, t) in items.enumerated() {
            if let k = tasks.firstIndex(where: { $0.id == t.id }) { tasks[k].position = Double(i) }
        }
        save()
    }

    /// Возвращает true, если что-то действительно поменялось.
    @discardableResult
    func setPriority(_ id: String, _ p: Priority) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].priority != p else { return false }
        tasks[i].priority = p
        save()
        return true
    }

    /// Перенос на другой день: ручное место из старого дня в новом не действует.
    @discardableResult
    func setDue(_ id: String, _ due: String?) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].due != due else { return false }
        tasks[i].due = due
        tasks[i].position = nil
        save()
        return true
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
        tasks = TaskFile.read(fileURL)
        done = TaskFile.read(doneURL)
    }

    private func save() {
        guard !isPreview else { return }
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func saveDone() {
        guard !isPreview else { return }
        guard let data = try? JSONEncoder().encode(done) else { return }
        try? data.write(to: doneURL, options: .atomic)
    }
}
