import Foundation

// MARK: - Ответ модели

struct AssistantReply: Decodable {
    struct NewItem: Decodable {
        var title: String?
        var due: String?
        var priority: String?
    }
    struct Change: Decodable {
        var id: String
        var priority: String?
        var due: String?
        var clear_due: Bool?
    }
    var heard: String?
    var action: String?
    var tasks: [NewItem]?
    var updates: [Change]?
    var complete_ids: [String]?
    var reply: String?
}

struct GeminiError: Error {
    var message: String
    var isKey = false
}

// MARK: - Клиент

@MainActor
final class Gemini {
    static let api = "https://generativelanguage.googleapis.com/v1beta"
    /// Если список моделей получить не удалось, пробуем эти. Lite — самые быстрые.
    static let fallbackModels = ["gemini-3.1-flash-lite", "gemini-2.5-flash-lite", "gemini-3.5-flash", "gemini-3-flash-preview"]

    private let defaults = UserDefaults.standard
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12
        return URLSession(configuration: c)
    }()

    var key: String { Keychain.get("apiKey") ?? "" }
    var lastModel: String { defaults.string(forKey: "model") ?? "" }

    func resetModels() {
        defaults.removeObject(forKey: "models")
        defaults.removeObject(forKey: "model")
    }

    /// Заранее устанавливаем соединение, чтобы первый запрос не ждал рукопожатия.
    func warmUp() {
        let key = self.key
        guard !key.isEmpty, let url = URL(string: "\(Self.api)/models?pageSize=1") else { return }
        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let session = self.session
        Task { _ = try? await session.data(for: req) }
    }

    // MARK: Разбор фразы

    func ask(_ heard: String, context: [String: Any]) async throws -> (reply: AssistantReply, model: String, ms: Int) {
        let ctxData = try JSONSerialization.data(withJSONObject: context)
        let prompt = "Распознанная речь: «\(heard)»\nКонтекст: " + String(decoding: ctxData, as: UTF8.self)

        let part: [String: Any] = ["text": prompt]
        let content: [String: Any] = ["role": "user", "parts": [part]]
        let system: [String: Any] = ["parts": [["text": Self.systemPrompt]]]
        let config: [String: Any] = [
            "responseMimeType": "application/json",
            "responseSchema": Self.schema,
            "temperature": 0.2
        ]
        let body: [String: Any] = ["systemInstruction": system, "contents": [content], "generationConfig": config]

        let result = try await generate(body)
        guard let data = Self.extractJSON(result.text),
              let reply = try? JSONDecoder().decode(AssistantReply.self, from: data) else {
            throw GeminiError(message: "Не получилось разобрать ответ. Попробуй ещё раз.")
        }
        return (reply, result.model, result.ms)
    }

    /// Проверка ключа из настроек: список моделей и один короткий запрос.
    func test() async throws -> (model: String, ms: Int) {
        resetModels()
        let models = try await discoverModels(key: key)
        defaults.set(models, forKey: "models")
        let part: [String: Any] = ["text": "Ответь одним словом: ок"]
        let content: [String: Any] = ["role": "user", "parts": [part]]
        let r = try await generate(["contents": [content]])
        return (r.model, r.ms)
    }

    // MARK: Запрос с перебором моделей

    func generate(_ body: [String: Any]) async throws -> (text: String, model: String, ms: Int) {
        let key = self.key
        guard !key.isEmpty else { throw GeminiError(message: "Вставь ключ Gemini в настройках.", isKey: true) }

        var models = defaults.stringArray(forKey: "models") ?? []
        if models.isEmpty {
            do {
                models = try await discoverModels(key: key)
                defaults.set(models, forKey: "models")
            } catch let e as GeminiError where e.isKey {
                throw e
            } catch {
                models = []
            }
        }

        var all: [String] = []
        for m in [lastModel] + models + Self.fallbackModels where !m.isEmpty && !all.contains(m) { all.append(m) }
        let candidates = Array((all.filter { $0.contains("lite") } + all.filter { !$0.contains("lite") }).prefix(4))

        var thinkCache = defaults.dictionary(forKey: "think") as? [String: Int] ?? [:]
        var log: [String] = []
        var rateLimited = false

        for model in candidates {
            let steps = Self.thinkingSteps(model)
            var si = min(thinkCache[model] ?? 0, steps.count - 1)
            while si < steps.count {
                var b = body
                if let think = steps[si] {
                    var gc = b["generationConfig"] as? [String: Any] ?? [:]
                    gc["thinkingConfig"] = think
                    b["generationConfig"] = gc
                }
                guard let url = URL(string: "\(Self.api)/models/\(model):generateContent") else { break }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = 12
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                req.httpBody = try JSONSerialization.data(withJSONObject: b)

                let started = Date()
                let data: Data
                let code: Int
                do {
                    let (d, r) = try await session.data(for: req)
                    data = d
                    code = (r as? HTTPURLResponse)?.statusCode ?? 0
                } catch {
                    let ns = error as NSError
                    if ns.code == NSURLErrorNotConnectedToInternet {
                        throw GeminiError(message: "Нет интернета.")
                    }
                    log.append("\(model): " + (ns.code == NSURLErrorTimedOut ? "нет ответа за 12 с" : "сеть: \(ns.localizedDescription)"))
                    break
                }

                if code == 200 {
                    if lastModel != model { defaults.set(model, forKey: "model") }
                    if (thinkCache[model] ?? 0) != si {
                        thinkCache[model] = si
                        defaults.set(thinkCache, forKey: "think")
                    }
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    return (Self.text(from: data), model, ms)
                }

                let err = Self.apiError(code, data)
                if err.isKey { throw err }
                if steps[si] != nil, code == 400, err.message.lowercased().contains("thinking"), si < steps.count - 1 {
                    si += 1
                    continue
                }
                log.append("\(model): \(code) \(err.message.prefix(90))")
                if code == 404 || err.message.range(of: "not found|not supported|deprecat", options: [.regularExpression, .caseInsensitive]) != nil {
                    if lastModel == model { defaults.removeObject(forKey: "model") }
                } else if code == 429 {
                    rateLimited = true
                } else if code < 500 {
                    throw GeminiError(message: "Gemini вернул ошибку:\n" + log.joined(separator: "\n"))
                }
                break
            }
        }
        let head = rateLimited ? "Лимит бесплатных запросов исчерпан. Попробуй чуть позже." : "Не получилось достучаться до Gemini."
        throw GeminiError(message: head + "\n" + log.joined(separator: "\n"))
    }

    func discoverModels(key: String) async throws -> [String] {
        guard let url = URL(string: "\(Self.api)/models?pageSize=1000") else { return [] }
        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Self.apiError(code, data) }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["models"] as? [[String: Any]] else { return [] }
        let names: [String] = list.compactMap { m in
            guard let name = m["name"] as? String,
                  let methods = m["supportedGenerationMethods"] as? [String],
                  methods.contains("generateContent") else { return nil }
            let n = name.replacingOccurrences(of: "models/", with: "")
            guard n.hasPrefix("gemini-"), n.contains("flash"),
                  n.range(of: "image|tts|live|audio|embed|robotics|computer|thinking|exp|8b", options: .regularExpression) == nil
            else { return nil }
            return n
        }
        return names.sorted { Self.score($0) > Self.score($1) }
    }

    // MARK: Помощники

    static func score(_ name: String) -> Double {
        var s = 0.0
        if let r = name.range(of: #"^gemini-\d+(\.\d+)?"#, options: .regularExpression) {
            s = (Double(name[r].dropFirst(7)) ?? 0) * 100
        }
        if name.contains("lite") { s += 500 }
        if name.contains("preview") { s -= 25 }
        return s
    }

    /// Минимум размышлений — быстрее ответ. Если модель не поддерживает уровень, пробуем следующий.
    static func thinkingSteps(_ model: String) -> [[String: Any]?] {
        if model.range(of: #"^gemini-[3-9]"#, options: .regularExpression) != nil {
            return [["thinkingLevel": "minimal"], ["thinkingLevel": "low"], nil]
        }
        if model.hasPrefix("gemini-2.5") {
            return [["thinkingBudget": 0], nil]
        }
        return [nil]
    }

    static func text(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["candidates"] as? [[String: Any]])?.first,
              let parts = (first["content"] as? [String: Any])?["parts"] as? [[String: Any]] else { return "" }
        return parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    static func extractJSON(_ text: String) -> Data? {
        let data = Data(text.utf8)
        if (try? JSONSerialization.jsonObject(with: data)) != nil { return data }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return Data(text[start...end].utf8)
    }

    static func apiError(_ code: Int, _ data: Data) -> GeminiError {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(code)"
        let isKey = code == 403 || (code == 400 && msg.range(of: "api.?key", options: [.regularExpression, .caseInsensitive]) != nil)
        return GeminiError(message: isKey ? "Ключ не подошёл. Проверь его в настройках." : msg, isKey: isKey)
    }

    // MARK: Схема ответа и инструкция

    static let schema: Any = {
        let json = """
        {
          "type": "OBJECT",
          "properties": {
            "heard": {"type": "STRING"},
            "action": {"type": "STRING"},
            "tasks": {"type": "ARRAY", "items": {"type": "OBJECT", "properties": {
              "title": {"type": "STRING"},
              "due": {"type": "STRING", "nullable": true},
              "priority": {"type": "STRING"}
            }, "required": ["title"]}},
            "updates": {"type": "ARRAY", "items": {"type": "OBJECT", "properties": {
              "id": {"type": "STRING"},
              "priority": {"type": "STRING", "nullable": true},
              "due": {"type": "STRING", "nullable": true},
              "clear_due": {"type": "BOOLEAN", "nullable": true}
            }, "required": ["id"]}},
            "reply": {"type": "STRING"}
          },
          "required": ["heard", "action", "reply"]
        }
        """
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [String: Any]()
    }()

    static let systemPrompt = """
    Ты ведёшь личный список задач. Тебе приходит текст, распознанный из речи пользователя на iPhone, и контекст в JSON. Пользователь говорит в основном по-русски, иногда вставляя английские слова. Распознавание идёт на русском, поэтому английские слова могли записаться кириллицей или с ошибками — восстанови их правильное написание.

    Язык записи:
    - Пиши по-русски, кириллицей.
    - Английские слова и всё, что обычно пишут латиницей (названия сервисов, приложений, брендов, компаний, технические термины, аббревиатуры: Figma, GitHub, Jira, Notion, Netflix, PR, API, deploy, onboarding), пиши латиницей в оригинальном написании («фигма» → Figma, «гитхаб» → GitHub, «пиар» в смысле pull request → PR).
    - Если вся фраза сказана по-английски, пиши её по-английски.

    Верни JSON:
    - heard: что сказал пользователь, исправленное по тем же правилам языка.
    - action: "add", "ask_due", "update" или "none".
    - tasks: [{title, due, priority}]. title — с заглавной буквы, в форме действия, без дня и даты, без приоритета и без «мне нужно». Если названо время суток, оно обязательно остаётся в title в формате «в ЧЧ:ММ» (пример: «Английский язык в 16:00», «Позвонить маме в 9:30»; «в 4 часа дня» → «в 16:00»). День в title не пиши — он уходит в due. Сокращай, где можно (пример: «Позвонить маме», «Обновить макеты в Figma»), но сохраняй важные детали: кому, что именно, где, сумма, номер, условие. Если деталей много, title может быть длиннее — до 3 строк, примерно до 120 символов. due — "YYYY-MM-DD" или null. priority — "high", "normal" или "low".
    - updates: [{id, priority, due, clear_due}] — изменения существующих задач для "update" (указывай только то, что меняется; clear_due = true, если срок нужно убрать).
    - reply: одна короткая фраза по-русски, без эмодзи и разметки. Для "add" и "update" — пустая строка.

    Правила:
    1. Новая задача со сроком → "add". Если пользователь прямо сказал, что срока нет («без срока», «когда-нибудь») → "add" с due = null.
    2. pending = null и у какой-то новой задачи срок не назван → "ask_due" со всеми новыми задачами (где срок известен, due заполнен); reply — короткий вопрос, например «Когда нужно позвонить маме?».
    3. pending не null → это ответ про срок: "add" для задач из pending с проставленным due. «Не знаю», «без срока» или непонятно → due = null. Если вместо ответа надиктованы новые задачи — "add" и pending (due = null), и новых. Дважды не спрашивай.
    4. Убирать задачи голосом нельзя: пользователь делает это сам в списке. Если он говорит, что сделал задачу, или просит удалить, убрать, отметить выполненной → "none", reply: «Голосом задачи не убираются — отметь её кружком в списке.» Слова «удали», «удалить», «убери» никогда не удаляют задачи.
    5. Непонятно или не про задачи → "none" с короткой репликой.
    6. Приоритет: "high", если звучит «важно», «срочно», «обязательно», «горит», «в первую очередь»; "low", если «не срочно», «не горит», «когда будет время», «не важно», «если успею»; иначе "normal". Про приоритет не переспрашивай.
    7. Пользователь просит поменять существующую задачу («сделай звонок маме важным», «перенеси отчёт на понедельник», «убери срок у фотографий») → "update" с id из current_tasks.
    8. Если пользователь назвал только время без дня («английский в 16:00»), считай, что это сегодня (если время уже прошло по now — завтра), и не переспрашивай срок.
    9. Даты считай от today (день недели указан): «в пятницу» — ближайшая будущая пятница (если сегодня пятница — сегодня); «на этой неделе», «до конца недели» — ближайшее воскресенье; «на следующей неделе» — воскресенье следующей недели; «через N дней» — today + N; «в конце месяца» — последний день месяца; «в течение месяца» — today + 30. Приблизительные сроки округляй до конкретной даты.
    """
}
