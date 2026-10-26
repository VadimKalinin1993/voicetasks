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
    var settingsOpen = false
    var timing: Timing?

    let speech = SpeechInput()
    let gemini = Gemini()
    private let speaker = Speaker()
    private let store: TaskStore

    @ObservationIgnored private var pending: [NewTask]?
    @ObservationIgnored private var lastQuestion: String?
    @ObservationIgnored private var authorized = false
    @ObservationIgnored private var toastToken = UUID()

    init(store: TaskStore) {
        self.store = store
        if let data = UserDefaults.standard.data(forKey: "timing") {
            timing = try? JSONDecoder().decode(Timing.self, from: data)
        }
    }

    private var speakAloud: Bool { UserDefaults.standard.object(forKey: "tts") as? Bool ?? true }
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
            break
        case .idle:
            Task { await run(auto: false) }
        }
    }

    func cancelAll() {
        if phase == .listening { speech.cancel() }
        if phase == .speaking { phase = .idle; speaker.stop() }
    }

    private func run(auto: Bool) async {
        guard !gemini.key.isEmpty else { settingsOpen = true; return }
        if !authorized {
            if let error = await SpeechInput.authorize() {
                withAnimation { bubble = Bubble(heard: nil, text: error) }
                return
            }
            authorized = true
        }

        toast = nil
        phase = .listening
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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

        guard let heard = recognized else {
            phase = .idle
            withAnimation {
                bubble = Bubble(heard: nil, text: pending != nil ? (lastQuestion ?? "Когда нужно сделать?") : "Не расслышал. Попробуй ещё раз.")
            }
            return
        }

        phase = .thinking
        do {
            let result = try await gemini.ask(heard, context: context())
            saveTiming(Timing(model: result.model, speech: speechTime, ai: Double(result.ms) / 1000))
            await handle(result.reply, heard: heard)
        } catch let e as GeminiError {
            phase = .idle
            withAnimation { bubble = Bubble(heard: heard, text: e.message) }
            if e.isKey { settingsOpen = true }
        } catch {
            phase = .idle
            withAnimation { bubble = Bubble(heard: heard, text: error.localizedDescription) }
        }
    }

    // MARK: Ответ Gemini

    private func handle(_ r: AssistantReply, heard: String) async {
        let list: [NewTask] = (r.tasks ?? []).compactMap { t in
            guard let title = t.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            return NewTask(title: title, due: Dates.valid(t.due), priority: Priority(loose: t.priority))
        }
        let action = r.action ?? "none"
        let hadPending = pending != nil
        var reply = (r.reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Добавление, отметка и правка проходят молча: подтверждение видно в самом списке.
        if (action == "add" && !list.isEmpty) || (action == "ask_due" && !list.isEmpty && hadPending) {
            withAnimation(.snappy) { store.add(list) }
            done()
            return
        }

        if action == "update" {
            var changed: [String] = []
            for u in r.updates ?? [] where store.contains(u.id) {
                if let p = Priority(rawValue: u.priority ?? "") { store.setPriority(u.id, p) }
                if let d = Dates.valid(u.due) {
                    store.setDue(u.id, d)
                } else if u.clear_due == true {
                    store.setDue(u.id, nil)
                }
                changed.append(u.id)
            }
            if !changed.isEmpty {
                withAnimation(.snappy) { store.markFresh(changed) }
                done()
                return
            }
            pending = nil
            reply = "Не нашёл такую задачу."
        } else if action == "complete" {
            let ids = Set(r.complete_ids ?? [])
            if store.tasks.contains(where: { ids.contains($0.id) }) {
                complete(ids)
                done()
                return
            }
            pending = nil
            reply = "Не нашёл такую задачу."
        } else if action == "ask_due" && !list.isEmpty {
            pending = list
            if reply.isEmpty { reply = "Когда нужно сделать?" }
            lastQuestion = reply
        } else if reply.isEmpty {
            reply = "Не расслышал. Попробуй ещё раз."
        }

        withAnimation(.snappy) { bubble = Bubble(heard: heard, text: reply) }
        if speakAloud {
            phase = .speaking
            await speaker.speak(reply)
            guard phase == .speaking else { return }   // нажали «стоп»
        }
        phase = .idle
        if pending != nil && autoListen { await run(auto: true) }
    }

    private func done() {
        pending = nil
        lastQuestion = nil
        withAnimation(.snappy) { bubble = nil }
        phase = .idle
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: Список

    func complete(_ ids: Set<String>) {
        let removed = withAnimation(.snappy) { store.complete(ids: ids) }
        guard !removed.isEmpty else { return }
        showToast(removed.count == 1 ? "Готово: \(removed[0].title)" : "Готово: \(tasksCount(removed.count))")
    }

    func undo() {
        withAnimation(.snappy) {
            store.undo()
            toast = nil
        }
    }

    /// Крестик на вопросе о сроке: добавляем задачу без срока, чтобы она не потерялась.
    func dismissBubble() {
        if let p = pending {
            withAnimation(.snappy) { store.add(p.map { NewTask(title: $0.title, due: nil, priority: $0.priority) }) }
            pending = nil
            lastQuestion = nil
        }
        withAnimation(.snappy) { bubble = nil }
    }

    private func showToast(_ text: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.snappy) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if toastToken == token { withAnimation(.snappy) { toast = nil } }
        }
    }

    // MARK: Контекст для Gemini

    private func context() -> [String: Any] {
        func value(_ s: String?) -> Any {
            if let s { return s }
            return NSNull()
        }
        let current: [[String: Any]] = store.tasks.map {
            ["id": $0.id, "title": $0.title, "due": value($0.due), "priority": $0.priority.rawValue]
        }
        var ctx: [String: Any] = [
            "today": Dates.today(),
            "weekday": Dates.todayWeekday(),
            "current_tasks": current
        ]
        if let pending {
            let p: [[String: Any]] = pending.map { ["title": $0.title, "due": value($0.due), "priority": $0.priority.rawValue] }
            ctx["pending"] = p
        } else {
            ctx["pending"] = NSNull()
        }
        ctx["last_question"] = value(lastQuestion)
        return ctx
    }

    private func saveTiming(_ t: Timing) {
        timing = t
        if let data = try? JSONEncoder().encode(t) { UserDefaults.standard.set(data, forKey: "timing") }
    }
}
