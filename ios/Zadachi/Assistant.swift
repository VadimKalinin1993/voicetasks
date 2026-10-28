import SwiftUI
import UIKit
import Observation

enum Phase: Equatable {
    case idle, listening, thinking, speaking
}

struct Timing: Codable, Equatable {
    var model: String
    var speech: Double   // сколько шла запись, с
    var ai: Double       // ответ Gemini, с
}

/// Вопрос о сроке, на который ещё не ответили. Хранится на диске:
/// если приложение выгрузят, после открытия вопрос снова на экране, а задачи не пропадут.
struct OpenQuestion: Codable, Equatable {
    var tasks: [NewTask]
    var question: String
    var heard: String?
}

typealias AskResult = (reply: AssistantReply, model: String, ms: Int)

/// Связывает микрофон, Gemini и список задач.
@MainActor
@Observable
final class Assistant {
    struct Bubble: Equatable {
        var heard: String?
        var text: String
    }

    var phase: Phase = .idle
    var bubble: Bubble?
    var toast: String?
    var settingsOpen = false {
        // Закрыли настройки (например, вставили ключ) — пробуем отправить то, что ждёт в очереди.
        didSet { if oldValue && !settingsOpen { Task { await flushQueue(force: true) } } }
    }
    var timing: Timing?
    /// Запрос идёт дольше 3 секунд — на кнопке микрофона появляется «стоп».
    private(set) var stoppable = false
    /// Подробности последней ошибки Gemini (по моделям) — показываются в настройках.
    private(set) var lastError: String? = UserDefaults.standard.string(forKey: "lastError")

    let speech = SpeechInput()
    let gemini = Gemini()
    private let speaker = Speaker()
    private let store: TaskStore
    /// Фразы, на которые ещё не пришёл ответ (закрыли приложение, пропала сеть).
    @ObservationIgnored private let queue: PhraseQueue
    @ObservationIgnored private var network: NetworkWatcher?
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var lastFlush = Date.distantPast
    /// Текущий запрос к Gemini — его можно отменить (кнопка «стоп» или новая запись).
    @ObservationIgnored private var request: Task<AskResult, Error>?

    /// Открытый вопрос о сроке (задачи без срока и сам вопрос).
    @ObservationIgnored private var question: OpenQuestion? {
        didSet { if !store.isPreview { saveQuestion() } }
    }
    private var pending: [NewTask]? { question?.tasks }
    @ObservationIgnored private var authorized = false
    @ObservationIgnored private var toastToken = UUID()
    /// Нажатие на микрофон уже принято, запись вот-вот начнётся — второе нажатие не запускает ещё одну.
    @ObservationIgnored private var starting = false
    /// Запись остановили не для отправки (крестик, уход в фон) — «Не расслышал» не показываем.
    @ObservationIgnored private var silentCancel = false

    init(store: TaskStore) {
        self.store = store
        self.queue = PhraseQueue(inMemory: store.isPreview)
        if let data = UserDefaults.standard.data(forKey: "timing") {
            timing = try? JSONDecoder().decode(Timing.self, from: data)
        }
        if !store.isPreview {
            if let data = UserDefaults.standard.data(forKey: "question"),
               let q = try? JSONDecoder().decode(OpenQuestion.self, from: data) {
                question = q
                bubble = Bubble(heard: q.heard, text: q.question)
            }
            let me = WeakRef(self)
            network = NetworkWatcher { Task { await me.value?.flushQueue(force: false) } }
        }
    }

    /// Голосом отвечаем только при включённом VoiceOver, в остальных случаях — только текст.
    private var speakAloud: Bool { UIAccessibility.isVoiceOverRunning }
    private var autoListen: Bool { UserDefaults.standard.object(forKey: "autoListen") as? Bool ?? true }

    // MARK: Кнопка микрофона

    func micTapped() {
        switch phase {
        case .listening:
            speech.finish()
        case .speaking:
            phase = .idle
            speaker.stop()
        case .thinking:
            // Запрос завис — «стоп» обрывает его, и можно диктовать заново.
            if stoppable { request?.cancel() }
        case .idle:
            guard !starting else { return }
            starting = true
            // Фоновый повтор фразы из очереди уступает новой записи: фраза подождёт следующего раза.
            request?.cancel()
            Task { await run(auto: false) }
        }
    }

    func cancelAll() {
        if phase == .listening {
            silentCancel = true
            speech.cancel()
        }
        if phase == .speaking { phase = .idle; speaker.stop() }
    }

    private func run(auto: Bool) async {
        defer { starting = false }
        guard !gemini.key.isEmpty else { settingsOpen = true; return }
        if !authorized {
            if let error = await SpeechInput.authorize() {
                withAnimation { bubble = Bubble(heard: nil, text: error) }
                return
            }
            authorized = true
        }

        toast = nil
        silentCancel = false
        phase = .listening
        starting = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Пока говоришь, соединение с Gemini уже устанавливается.
        gemini.warmUp()
        let started = Date()

        let recognized: String?
        do {
            recognized = try await speech.listen()
        } catch {
            phase = .idle
            withAnimation { bubble = Bubble(heard: nil, text: error.localizedDescription) }
            return
        }
        let speechTime = Date().timeIntervalSince(started)

        if silentCancel {
            silentCancel = false
            phase = .idle
            return
        }
        guard let heard = recognized else {
            phase = .idle
            withAnimation {
                bubble = Bubble(heard: question?.heard, text: question?.question ?? "Не расслышал. Попробуй ещё раз.")
            }
            return
        }

        // Сразу кладём фразу на диск: если приложение закроют или пропадёт сеть,
        // она не потеряется и уйдёт снова при следующем открытии.
        let item = queue.enqueue(heard: heard, context: context())
        await send(item, speechTime: speechTime, retry: false)
    }

    // MARK: Отправка и очередь

    /// Отправляет фразу в Gemini. Возвращает false, если ответа нет и фраза осталась в очереди.
    /// retry = фоновый повтор из очереди: он идёт незаметно и не занимает кнопку микрофона.
    @discardableResult
    private func send(_ item: QueuedPhrase, speechTime: Double?, retry: Bool) async -> Bool {
        if !retry { phase = .thinking }
        // Пока идёт запрос, просим у iOS время доработать, даже если приложение свернули.
        let background = BackgroundTime.begin("gemini")

        // Задачи, про срок которых спрашивали: из памяти или из сохранённой фразы.
        let asked = pending ?? queue.pendingTasks(of: item)
        let ctx = queue.context(for: item, currentTasks: currentTasks())
        let gemini = self.gemini
        let request = Task { try await gemini.ask(item.heard, context: ctx) }
        self.request = request

        // Если ответ не пришёл за 3 секунды — показываем «стоп» на кнопке микрофона.
        let stopTimer: Task<Void, Never>? = retry ? nil : Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.phase == .thinking else { return }
            withAnimation(.snappy) { self.stoppable = true }
        }
        defer { background.end() }
        /// Запрос закончился (ответом, ошибкой или «стопом») — убираем «стоп» с кнопки сразу,
        /// ещё до обработки ответа.
        func finish() {
            stopTimer?.cancel()
            if self.request == request { self.request = nil }
            if stoppable { withAnimation(.snappy) { stoppable = false } }
        }

        do {
            let result: AskResult
            do {
                result = try await request.value
            } catch {
                finish()
                throw error
            }
            finish()
            // «Стоп» нажали в тот же миг, когда пришёл ответ, — считаем остановленным.
            if request.isCancelled { throw CancellationError() }
            queue.remove(item.id)
            setLastError(nil)
            if let speechTime {
                saveTiming(Timing(model: result.model, speech: speechTime, ai: Double(result.ms) / 1000))
            }
            await handle(result.reply, heard: item.heard, asked: asked, mayListen: !retry)
            return true
        } catch is CancellationError {
            // Фоновый повтор перебили новой записью — фраза ждёт в очереди.
            guard !retry else { return false }
            // Нажали «стоп»: запрос и фразу сбрасываем, можно диктовать заново.
            queue.remove(item.id)
            phase = .idle
            withAnimation { bubble = Bubble(heard: item.heard, text: "Остановлено. Продиктуй ещё раз.") }
            return false
        } catch let e as GeminiError where e.canRetry {
            // Ответа нет (сеть, перегрузка, лимит, ключ) — фраза остаётся в очереди.
            setLastError(e.details)
            guard !retry else { return false }   // повтор в фоне — молча ждём следующего раза
            phase = .idle
            // Вопрос о сроке теперь «живёт» в сохранённой фразе — снимаем его, чтобы не задать дважды.
            question = nil
            let tail: String
            if e.isKey {
                tail = "Фраза сохранена — добавлю задачу, когда ключ заработает."
            } else if e.message.hasPrefix("Нет интернета") {
                tail = "Фраза сохранена — добавлю задачу, когда появится связь."
            } else {
                tail = "Фраза сохранена — попробую ещё раз сам."
            }
            withAnimation { bubble = Bubble(heard: item.heard, text: e.message + "\n" + tail) }
            if e.isKey { settingsOpen = true }
            return false
        } catch {
            // Ответ пришёл, но с ним что-то не так — повтор не поможет, убираем из очереди.
            queue.remove(item.id)
            setLastError((error as? GeminiError)?.details)
            if !retry { phase = .idle }
            let text = (error as? GeminiError)?.message ?? error.localizedDescription
            withAnimation { bubble = Bubble(heard: item.heard, text: text) }
            return false
        }
    }

    /// Отправляет фразы, которые ждут ответа. Вызывается при открытии приложения (force),
    /// после закрытия настроек (force) и когда появляется сеть — не чаще раза в 30 секунд.
    func flushQueue(force: Bool = true) async {
        guard !flushing else { return }
        guard force || Date().timeIntervalSince(lastFlush) > 30 else { return }
        flushing = true
        lastFlush = Date()
        defer { flushing = false }
        while let item = queue.items.first,
              phase == .idle, !starting, pending == nil, !gemini.key.isEmpty,
              UIApplication.shared.applicationState == .active {
            let ok = await send(item, speechTime: nil, retry: true)
            if !ok || pending != nil { break }
        }
    }

    // MARK: Ответ Gemini

    /// asked — задачи, про срок которых спрашивали перед этой фразой (если спрашивали).
    private func handle(_ r: AssistantReply, heard: String, asked: [NewTask]?, mayListen: Bool) async {
        let list: [NewTask] = (r.tasks ?? []).compactMap { t in
            guard let title = t.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            return NewTask(title: title, due: Dates.valid(t.due), priority: Priority(loose: t.priority))
        }
        let action = r.action ?? "none"
        var reply = (r.reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isActive = UIApplication.shared.applicationState == .active

        // Добавление и правка проходят молча: подтверждение видно в самом списке.
        // Если ответ пришёл, когда приложение уже свернули, спросить срок некого — добавляем как есть.
        if (action == "add" && !list.isEmpty) || (action == "ask_due" && !list.isEmpty && (asked != nil || !isActive)) {
            withAnimation(.snappy) { store.add(list) }
            done()
            return
        }

        // Спрашивали срок, а в ответ прозвучало что-то другое (правка, «удали…», непонятное).
        // Дважды не спрашиваем: задачи из вопроса добавляем без срока, чтобы они не потерялись.
        let leftover = asked.map { $0.map { NewTask(title: $0.title, due: nil, priority: $0.priority) } }

        if action == "update" {
            var changed: [String] = []
            var found = false
            for u in r.updates ?? [] {
                guard let id = u.id, store.contains(id) else { continue }
                found = true
                var did = false
                if let p = Priority(rawValue: u.priority ?? "") { did = store.setPriority(id, p) || did }
                if let d = Dates.valid(u.due) {
                    did = store.setDue(id, d) || did
                } else if u.clear_due == true {
                    did = store.setDue(id, nil) || did
                }
                if did { changed.append(id) }
            }
            if let leftover, !leftover.isEmpty { withAnimation(.snappy) { store.add(leftover) } }
            if !changed.isEmpty || leftover != nil {
                withAnimation(.snappy) { store.markFresh(changed) }
                done()
                return
            }
            // Задачу нашли, но менять нечего (она уже такая) — без вибрации «успеха».
            reply = found ? "У этой задачи уже так." : "Не нашёл такую задачу."
        } else if action == "ask_due" && !list.isEmpty {
            if reply.isEmpty { reply = "Когда нужно сделать?" }
            question = OpenQuestion(tasks: list, question: reply, heard: heard)
        } else {
            if action == "complete" { reply = "Голосом задачи не убираются — отметь её кружком в списке." }
            if reply.isEmpty { reply = "Не расслышал. Попробуй ещё раз." }
            if let leftover, !leftover.isEmpty {
                withAnimation(.snappy) { store.add(leftover) }
                question = nil
            }
        }
        if action != "ask_due" { question = nil }

        withAnimation(.snappy) { bubble = Bubble(heard: heard, text: reply) }
        if speakAloud {
            phase = .speaking
            await speaker.speak(reply)
            guard phase == .speaking else { return }   // нажали «стоп»
        }
        phase = .idle
        if pending != nil && autoListen && mayListen {
            try? await Task.sleep(for: .milliseconds(400))   // время прочитать вопрос
            guard phase == .idle, !starting, pending != nil, !settingsOpen,
                  UIApplication.shared.applicationState == .active else { return }
            await run(auto: true)
        }
    }

    private func done() {
        question = nil
        withAnimation(.snappy) { bubble = nil }
        phase = .idle
        let haptic = UINotificationFeedbackGenerator()
        haptic.prepare()
        haptic.notificationOccurred(.success)
    }

    // MARK: Список

    func complete(_ ids: Set<String>) {
        let removed = withAnimation(.snappy) { store.complete(ids: ids) }
        guard !removed.isEmpty else { return }
        showToast(removed.count == 1 ? "Готово: \(removed[0].title)" : "Готово: \(tasksCount(removed.count))")
    }

    /// Свайп влево: задача удаляется совсем, в тосте — «Вернуть».
    func delete(_ id: String) {
        guard let removed = withAnimation(.snappy, { store.delete(id: id) }) else { return }
        showToast("Удалено: \(removed.title)")
    }

    func undo() {
        withAnimation(.snappy) {
            store.undo()
            toast = nil
        }
    }

    /// Крестик на сообщении. Если это вопрос о сроке — добавляем задачу без срока, чтобы она не потерялась,
    /// и останавливаем запись ответа, если она уже идёт.
    func dismissBubble() {
        if let p = pending {
            if phase == .listening {
                silentCancel = true
                speech.cancel()
            }
            withAnimation(.snappy) { store.add(p.map { NewTask(title: $0.title, due: nil, priority: $0.priority) }) }
            question = nil
        }
        withAnimation(.snappy) { bubble = nil }
    }

    private func showToast(_ text: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.snappy) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if toastToken == token {
                withAnimation(.snappy) { toast = nil }
                store.forgetUndo()
            }
        }
    }

    // MARK: Контекст для Gemini

    private func value(_ s: String?) -> Any {
        if let s { return s }
        return NSNull()
    }

    private func currentTasks() -> [[String: Any]] {
        store.tasks.map {
            ["id": $0.id, "title": $0.title, "due": value($0.due), "priority": $0.priority.rawValue]
        }
    }

    private func context() -> [String: Any] {
        var ctx: [String: Any] = [
            "today": Dates.today(),
            "weekday": Dates.todayWeekday(),
            "now": Dates.nowTime(),
            "current_tasks": currentTasks()
        ]
        if let pending {
            let p: [[String: Any]] = pending.map { ["title": $0.title, "due": value($0.due), "priority": $0.priority.rawValue] }
            ctx["pending"] = p
        } else {
            ctx["pending"] = NSNull()
        }
        ctx["last_question"] = value(question?.question)
        return ctx
    }

    private func setLastError(_ details: String?) {
        guard details != lastError else { return }
        lastError = details
        if let details {
            UserDefaults.standard.set(details, forKey: "lastError")
        } else {
            UserDefaults.standard.removeObject(forKey: "lastError")
        }
    }

    private func saveTiming(_ t: Timing) {
        timing = t
        if let data = try? JSONEncoder().encode(t) { UserDefaults.standard.set(data, forKey: "timing") }
    }

    private func saveQuestion() {
        if let question, let data = try? JSONEncoder().encode(question) {
            UserDefaults.standard.set(data, forKey: "question")
        } else {
            UserDefaults.standard.removeObject(forKey: "question")
        }
    }
}
