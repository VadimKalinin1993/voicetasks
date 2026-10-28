import Foundation
import Testing
@testable import Zadachi

// Юнит-тесты чистой логики: даты и секции, склонение, порядок и перетаскивание,
// закрытие и «Вернуть», чтение файлов, разбор ответа Gemini, выбор модели, очередь фраз.

@MainActor
private func day(_ s: String, hour: Int = 12) -> Date {
    let d = Dates.date(s)!
    return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: d)!
}

@MainActor
private func task(_ id: String, due: String? = nil, priority: Priority = .normal,
                  created: Date = Date(timeIntervalSince1970: 1_800_000_000), position: Double? = nil) -> TaskItem {
    TaskItem(id: id, title: "Задача \(id)", due: due, priority: priority, created: created, position: position)
}

// MARK: - Склонение

@MainActor
struct CountTests {
    @Test(arguments: [
        (0, "0 задач"), (1, "1 задача"), (2, "2 задачи"), (4, "4 задачи"), (5, "5 задач"),
        (11, "11 задач"), (12, "12 задач"), (14, "14 задач"), (21, "21 задача"),
        (22, "22 задачи"), (25, "25 задач"), (101, "101 задача"), (111, "111 задач"), (112, "112 задач")
    ])
    func declension(_ n: Int, _ expected: String) {
        #expect(tasksCount(n) == expected)
    }
}

// MARK: - Даты и заголовки секций

@MainActor
struct DatesTests {
    let now = day("2026-10-27")   // вторник

    /// Заголовок секции; «!» в конце — секция просроченная (оранжевая).
    private func head(_ s: String?, _ now: Date) -> String {
        let h = Dates.sectionTitle(s, now: now)
        return h.title + (h.overdue ? "!" : "")
    }

    @Test func validDates() {
        #expect(Dates.valid("2026-10-27") == "2026-10-27")
        #expect(Dates.valid("2026-02-30") == nil)
        #expect(Dates.valid("27.10.2026") == nil)
        #expect(Dates.valid("2026-10-27T10:00") == nil)
        #expect(Dates.valid("") == nil)
        #expect(Dates.valid(nil) == nil)
    }

    @Test func sectionTitles() {
        #expect(head("2026-10-27", now) == "Сегодня")
        #expect(head("2026-10-28", now) == "Завтра")
        #expect(head("2026-10-30", now) == "Пятница, 30 октября")
        #expect(head("2026-10-26", now) == "Просрочено · вчера!")
        #expect(head("2026-10-25", now) == "Просрочено · 25 октября!")
        #expect(head("2027-01-05", now) == "Вторник, 5 января 2027")
        #expect(head(nil, now) == "Без срока")
        #expect(head("ерунда", now) == "Без срока")
    }

    /// Поздно вечером и сразу после полуночи день считается по календарю, а не по 24 часам.
    @Test func dayBoundaries() {
        let lateEvening = day("2026-10-27", hour: 23)
        #expect(head("2026-10-28", lateEvening) == "Завтра")
        let afterMidnight = day("2026-10-28", hour: 0)
        #expect(head("2026-10-27", afterMidnight) == "Просрочено · вчера!")
        #expect(head("2026-10-28", afterMidnight) == "Сегодня")
    }

    @Test func headerIsTodayDate() {
        #expect(Dates.headerTitle("2026-10-28") == "28 октября")
        #expect(Dates.headerTitle("2027-02-27") == "27 февраля")
        #expect(Dates.headerTitle("2026-03-15") == "15 марта")
    }

    @Test func doneTitles() {
        #expect(Dates.doneSectionTitle(day("2026-10-27", hour: 9), now: now) == "Сегодня")
        #expect(Dates.doneSectionTitle(day("2026-10-26", hour: 23), now: now) == "Вчера")
        #expect(Dates.doneSectionTitle(day("2026-10-21"), now: now) == "Среда, 21 октября")
    }
}

// MARK: - Список: порядок, перетаскивание, закрытие, «Вернуть»

@MainActor
struct StoreTests {
    @Test func sortInsideDay() {
        let today = Dates.today()
        let store = TaskStore(preview: [
            task("low", due: today, priority: .low, created: Date(timeIntervalSince1970: 1)),
            task("new", due: today, priority: .high, created: Date(timeIntervalSince1970: 3)),
            task("old", due: today, priority: .high, created: Date(timeIntervalSince1970: 2)),
            task("manual", due: today, priority: .low, position: 0)
        ], done: [])
        let ids = store.sections.first?.items.map(\.id)
        // Сначала расставленное вручную, потом по приоритету, внутри — по времени создания.
        #expect(ids == ["manual", "old", "new", "low"])
    }

    @Test func sectionsOrder() {
        let today = Dates.today()
        let store = TaskStore(preview: [task("a"), task("b", due: today), task("c", due: "2020-01-01")], done: [])
        #expect(store.sections.map(\.id) == ["2020-01-01", today, "~none"])
        #expect(store.sections.first?.overdue == true)
        #expect(store.sections.last?.title == "Без срока")
    }

    @Test func moveInsideDay() {
        let today = Dates.today()
        let store = TaskStore(preview: [
            task("a", due: today, priority: .high),
            task("b", due: today, priority: .normal),
            task("c", due: today, priority: .low)
        ], done: [])
        store.move(section: today, from: IndexSet(integer: 2), to: 0)
        #expect(store.sections.first?.items.map(\.id) == ["c", "a", "b"])
    }

    @Test func dueChangeResetsManualPlace() {
        let store = TaskStore(preview: [task("a", due: "2026-10-27", position: 0)], done: [])
        #expect(store.setDue("a", "2026-10-30"))
        #expect(store.tasks.first?.position == nil)
        #expect(store.setDue("a", "2026-10-30") == false)        // ничего не поменялось
        #expect(store.setPriority("a", .normal) == false)
        #expect(store.setPriority("a", .high))
        #expect(store.setPriority("нет такой", .high) == false)
    }

    @Test func completeAndUndo() {
        let store = TaskStore(preview: [task("a"), task("b")], done: [])
        let removed = store.complete(ids: ["a"])
        #expect(removed.map(\.id) == ["a"])
        #expect(store.tasks.map(\.id) == ["b"])
        #expect(store.done.map(\.id) == ["a"])
        #expect(store.done.first?.completed != nil)

        store.undo()
        #expect(Set(store.tasks.map(\.id)) == ["a", "b"])
        #expect(store.done.isEmpty)
        #expect(store.tasks.first { $0.id == "a" }?.completed == nil)

        #expect(store.complete(ids: ["нет такой"]).isEmpty)
    }

    @Test func deleteAndUndo() {
        let store = TaskStore(preview: [task("a", due: "2026-10-27", priority: .high, position: 1), task("b")], done: [])
        let removed = store.delete(id: "a")
        #expect(removed?.id == "a")
        #expect(store.tasks.map(\.id) == ["b"])
        #expect(store.done.isEmpty)                         // в «Выполнено» не попадает

        store.undo()
        let back = store.tasks.first { $0.id == "a" }
        #expect(back?.due == "2026-10-27")                  // тот же день, приоритет и место
        #expect(back?.priority == .high)
        #expect(back?.position == 1)
        #expect(store.done.isEmpty)

        store.delete(id: "a")
        store.forgetUndo()                                  // тост исчез
        store.undo()
        #expect(store.tasks.map(\.id) == ["b"])            // вернуть уже нельзя
        #expect(store.delete(id: "нет такой") == nil)
    }

    @Test func undoAfterCompleteStillWorks() {
        let store = TaskStore(preview: [task("a")], done: [task("old")])
        store.complete(ids: ["a"])
        store.undo()
        #expect(store.tasks.map(\.id) == ["a"])
        #expect(store.done.map(\.id) == ["old"])
    }

    @Test func addMakesUniqueIDs() {
        let store = TaskStore(preview: [], done: [])
        store.add((0..<50).map { NewTask(title: "t\($0)", due: nil, priority: .normal) })
        #expect(Set(store.tasks.map(\.id)).count == 50)
        #expect(store.tasks.count == 50)
    }
}

// MARK: - Чтение файлов задач (старые форматы и повреждения)

@MainActor
struct TaskFileTests {
    @Test func oldFileWithoutNewFields() {
        let json = #"[{"id":"a1","title":"Позвонить маме","due":"2026-10-27","priority":"high","created":800000000}]"#
        let r = TaskFile.decode(Data(json.utf8))
        #expect(r.complete)
        #expect(r.items.count == 1)
        #expect(r.items.first?.position == nil)
        #expect(r.items.first?.completed == nil)
        #expect(r.items.first?.priority == .high)
    }

    @Test func unknownPriorityAndBadDate() {
        let json = #"[{"id":"a1","title":"Т","due":"завтра","priority":"urgent","created":1}]"#
        let r = TaskFile.decode(Data(json.utf8))
        #expect(r.complete)
        #expect(r.items.first?.priority == .normal)
        #expect(r.items.first?.due == nil)
    }

    @Test func brokenItemIsSkippedNotEverything() {
        let json = #"[{"id":"a1","title":"Хорошая","created":1},{"id":"a2"},{"id":"a3","title":"Тоже хорошая"}]"#
        let r = TaskFile.decode(Data(json.utf8))
        #expect(r.complete == false)
        #expect(r.items.map(\.id) == ["a1", "a3"])
    }

    @Test func garbage() {
        let r = TaskFile.decode(Data("не json".utf8))
        #expect(r.items.isEmpty)
        #expect(r.complete == false)
    }

    @Test func roundTrip() throws {
        let t = TaskItem(id: "x", title: "Т", due: "2026-10-27", priority: .low, created: Date(timeIntervalSince1970: 5),
                         completed: Date(timeIntervalSince1970: 6), position: 2)
        let data = try JSONEncoder().encode([t])
        #expect(TaskFile.decode(data).items == [t])
    }

    @Test func backupWhenNotComplete() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tasks.json")
        try Data(#"[{"id":"a1","title":"Ок","created":1},{"id":"a2"}]"#.utf8).write(to: url)
        let items = TaskFile.read(url)
        #expect(items.map(\.id) == ["a1"])
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.hasPrefix("tasks.backup-") })
    }
}

// MARK: - Разбор ответа Gemini

@MainActor
struct ReplyTests {
    @Test func normalReply() throws {
        let r = try #require(Gemini.parse(#"{"heard":"английский в 16","action":"add","tasks":[{"title":"Английский язык в 16:00","due":"2026-10-27","priority":"normal"}],"reply":""}"#))
        #expect(r.action == "add")
        #expect(r.tasks?.first?.title == "Английский язык в 16:00")
        #expect(r.tasks?.first?.due == "2026-10-27")
    }

    @Test func jsonInsideText() throws {
        let r = try #require(Gemini.parse("Вот ответ:\n```json\n{\"action\":\"none\",\"reply\":\"Не понял\"}\n```"))
        #expect(r.reply == "Не понял")
    }

    @Test func looseFields() throws {
        let r = try #require(Gemini.parse(#"{"action":"update","updates":[{"id":123,"clear_due":"true"},{"priority":"high"},{"id":"ab12","priority":null,"due":"2026-10-30"}],"reply":""}"#))
        #expect(r.updates?.count == 3)
        #expect(r.updates?[0].id == "123")
        #expect(r.updates?[0].clear_due == true)
        #expect(r.updates?[1].id == nil)          // правка без id не ломает остальные
        #expect(r.updates?[2].priority == nil)
        #expect(r.updates?[2].due == "2026-10-30")
    }

    @Test func badItemsAreSkipped() throws {
        let r = try #require(Gemini.parse(#"{"action":"add","tasks":["строка вместо объекта",{"title":"Нормальная"}],"reply":""}"#))
        #expect(r.tasks?.map(\.title) == ["Нормальная"])
    }

    @Test func missingFields() throws {
        let r = try #require(Gemini.parse("{}"))
        #expect(r.action == nil)
        #expect(r.tasks == nil)
    }

    @Test func notJSON() {
        #expect(Gemini.parse("") == nil)
        #expect(Gemini.parse("просто текст") == nil)
        #expect(Gemini.parse("{ сломано") == nil)
    }

    @Test func geminiText() {
        let body = #"{"candidates":[{"content":{"parts":[{"text":"думаю","thought":true},{"text":"{\"a\":1}"}]}}]}"#
        #expect(Gemini.text(from: Data(body.utf8)) == #"{"a":1}"#)
        #expect(Gemini.text(from: Data("{}".utf8)) == "")
    }
}

// MARK: - Модели Gemini

@MainActor
struct ModelTests {
    /// Две Lite, потом две обычные: если все Lite перегружены разом, выручают обычные.
    @Test func twoLiteThenTwoFull() {
        let c = Gemini.candidates(last: "", discovered: ["gemini-3.5-flash", "gemini-3.1-flash-lite", "gemini-9-flash", "gemini-9-flash-lite"])
        #expect(c == ["gemini-3.1-flash-lite", "gemini-9-flash-lite", "gemini-3.5-flash", "gemini-9-flash"])
    }

    /// Ровно случай со скриншота: в списке одни Lite — обычная flash всё равно попадает в попытки.
    @Test func fullModelAlwaysTriedWhenOnlyLiteDiscovered() {
        let c = Gemini.candidates(last: "", discovered: ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-3.1-flash-lite-preview", "gemini-2.5-flash-lite"])
        #expect(c.count == 4)
        #expect(c.contains("gemini-3.5-flash"))
    }

    @Test func lastWorkingModelGoesFirstAmongItsKind() {
        let c = Gemini.candidates(last: "gemini-3.1-flash-lite", discovered: [])
        #expect(c == ["gemini-3.1-flash-lite", "gemini-3.5-flash-lite", "gemini-3.5-flash", "gemini-3-flash-preview"])
    }

    @Test func fallbackWhenNothingKnown() {
        #expect(Gemini.candidates(last: "", discovered: []) ==
                ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-3.5-flash", "gemini-3-flash-preview"])
    }

    @Test func fillsFromOtherGroupWhenShort() {
        let c = Gemini.candidates(last: "", discovered: ["gemini-1-lite", "gemini-2-lite", "gemini-3-lite"])
        #expect(c.count == 4)
    }

    @Test func scoreOrder() {
        #expect(Gemini.score("gemini-3.1-flash-lite") > Gemini.score("gemini-3.5-flash"))
        #expect(Gemini.score("gemini-3.5-flash") > Gemini.score("gemini-3-flash-preview"))
    }

    @Test func thinking() {
        #expect(Gemini.thinkingSteps("gemini-3.1-flash-lite").count == 3)
        #expect(Gemini.thinkingSteps("gemini-2.5-flash-lite").count == 2)
        #expect(Gemini.thinkingSteps("gemini-2.0-flash").count == 1)
    }

    @Test func errors() {
        let key = Gemini.apiError(403, Data())
        #expect(key.isKey && key.canRetry)
        let badKey = Gemini.apiError(400, Data(#"{"error":{"message":"API key not valid"}}"#.utf8))
        #expect(badKey.isKey)
        let other = Gemini.apiError(400, Data(#"{"error":{"message":"Invalid schema"}}"#.utf8))
        #expect(!other.isKey && !other.canRetry)
        #expect(other.message == "Invalid schema")
    }
}

// MARK: - Очередь фраз без ответа

@MainActor
struct QueueTests {
    @Test func keepsDictationTimeAndFreshTasks() {
        let q = PhraseQueue(inMemory: true)
        let item = q.enqueue(heard: "завтра", context: [
            "today": "2026-10-27", "now": "23:50",
            "current_tasks": [["id": "old"]],
            "pending": [["title": "Позвонить маме", "due": NSNull(), "priority": "high"]]
        ])
        #expect(q.items.count == 1)

        let ctx = q.context(for: item, currentTasks: [["id": "new"]])
        #expect(ctx["today"] as? String == "2026-10-27")       // дата — как в момент диктовки
        #expect((ctx["current_tasks"] as? [[String: Any]])?.first?["id"] as? String == "new")

        let asked = q.pendingTasks(of: item)
        #expect(asked == [NewTask(title: "Позвонить маме", due: nil, priority: .high)])

        q.remove(item.id)
        #expect(q.items.isEmpty)
    }

    @Test func noQuestion() {
        let q = PhraseQueue(inMemory: true)
        let item = q.enqueue(heard: "купить хлеб", context: ["pending": NSNull()])
        #expect(q.pendingTasks(of: item) == nil)
    }
}
