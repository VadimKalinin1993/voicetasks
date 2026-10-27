@preconcurrency import AVFoundation
@preconcurrency import Speech
import Observation

struct SpeechError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Аудиобуферы приходят в фоновом потоке, поэтому запрос оборачиваем в простой контейнер.
nonisolated final class RequestBox: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
}

/// Слабая ссылка, которую можно передать в фоновый поток (для колбэков из аудио, сети и т.п.).
nonisolated final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

// MARK: - Аудиосессия

/// Все включения и выключения аудиосессии идут по очереди в одном фоновом потоке:
/// выключение не тормозит интерфейс и запрос к Gemini, а новое включение
/// всегда ждёт, пока закончится предыдущее выключение.
nonisolated enum AudioSession {
    static let queue = DispatchQueue(label: "zadachi.audio-session", qos: .userInitiated)

    static func activateForRecording() throws {
        try queue.sync {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
            // Без этого iOS глушит вибрацию, пока активна сессия записи.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }
    }

    static func activateForSpeaking() {
        queue.sync {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? session.setActive(true)
        }
    }

    /// Возвращаем звук другим приложениям — в фоне, не дожидаясь.
    static func deactivateLater() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

// MARK: - Распознавание речи (на устройстве)

@MainActor
@Observable
final class SpeechInput {
    /// Громкость 0…1 для анимации кнопки.
    var level: Float = 0

    /// Новый движок на каждую запись: если между записями подключили или отключили наушники,
    /// старый движок помнит прежний формат микрофона, и установка «прослушки» может уронить приложение.
    @ObservationIgnored private var engine: AVAudioEngine?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var box: RequestBox?
    @ObservationIgnored private var transcript = ""
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var lastChange = Date()
    @ObservationIgnored private var continuation: CheckedContinuation<String?, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?

    /// Сколько ждём тишины после речи, прежде чем отправить фразу сами.
    /// Раньше отправить можно нажатием на микрофон.
    static let pause: TimeInterval = 1.2

    static func authorize() async -> String? {
        let speech = await speechAuthorization()
        guard speech == .authorized else {
            return "Нет доступа к распознаванию речи. Разреши его: Настройки → Задачи."
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return mic ? nil : "Нет доступа к микрофону. Разреши его: Настройки → Задачи."
    }

    nonisolated private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
    }

    /// Слушает до паузы и возвращает текст (nil — ничего не расслышали или запись отменили).
    func listen() async throws -> String? {
        // На случай повторного запуска: прошлая запись завершается, а не «зависает».
        if continuation != nil { complete(nil) }

        guard let recognizer, recognizer.isAvailable else {
            throw SpeechError(message: "Распознавание речи сейчас недоступно.")
        }

        do {
            try AudioSession.activateForRecording()

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            let box = RequestBox(request)
            self.box = box

            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw SpeechError(message: "Микрофон недоступен.")
            }
            let me = WeakRef(self)
            let onLevel: @Sendable (Float) -> Void = { v in
                Task { @MainActor in me.value?.level = v }
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(box, onLevel: onLevel))
            engine.prepare()
            try engine.start()

            transcript = ""
            started = Date()
            lastChange = Date()

            let onResult: @Sendable (String?, Bool, Bool) -> Void = { text, isFinal, failed in
                Task { @MainActor in me.value?.handle(text, isFinal: isFinal, failed: failed) }
            }

            return await withCheckedContinuation { cont in
                self.continuation = cont
                self.task = recognizer.recognitionTask(with: request, resultHandler: Self.makeHandler(onResult))
                self.watcher = Task { [weak self] in await self?.watch() }
            }
        } catch {
            // Запись не началась — убираем за собой, чтобы музыка в других приложениях не осталась приглушённой.
            teardown()
            throw error
        }
    }

    func finish() { complete(transcript.trimmingCharacters(in: .whitespacesAndNewlines)) }
    func cancel() { complete(nil) }

    private func handle(_ text: String?, isFinal: Bool, failed: Bool) {
        guard continuation != nil else { return }
        if let text, text != transcript {
            transcript = text
            lastChange = Date()
        }
        if isFinal || failed { finish() }
    }

    private func watch() async {
        while continuation != nil {
            try? await Task.sleep(for: .milliseconds(100))
            guard continuation != nil else { return }
            let now = Date()
            if !transcript.isEmpty && now.timeIntervalSince(lastChange) > Self.pause { finish(); return }
            if transcript.isEmpty && now.timeIntervalSince(started) > 7 { finish(); return }
            if now.timeIntervalSince(started) > 30 { finish(); return }
        }
    }

    private func complete(_ text: String?) {
        guard let c = continuation else { return }
        continuation = nil
        watcher?.cancel()
        watcher = nil
        teardown()
        let result = (text?.isEmpty ?? true) ? nil : text
        c.resume(returning: result)
    }

    /// Останавливает запись и освобождает микрофон. Аудиосессия выключается в фоне,
    /// поэтому запрос к Gemini уходит сразу, не дожидаясь этого.
    private func teardown() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        box?.request.endAudio()
        task?.cancel()
        task = nil
        box = nil
        level = 0
        AudioSession.deactivateLater()
    }

    nonisolated private static func makeTap(_ box: RequestBox, onLevel: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            box.request.append(buffer)
            guard let channel = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += channel[i] * channel[i] }
            onLevel(min(1, (sum / Float(n)).squareRoot() / 0.08))
        }
    }

    nonisolated private static func makeHandler(_ sink: @escaping @Sendable (String?, Bool, Bool) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        return { result, error in
            sink(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }
}

// MARK: - Озвучка вопросов (только при VoiceOver)

@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    /// Номер текущей фразы: таймер прошлой фразы не обрывает следующую.
    private var token = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) async {
        stop()
        token += 1
        let my = token
        AudioSession.activateForSpeaking()
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.voice()
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        let limit = 2 + Double(text.count) * 0.09
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            synth.speak(u)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(limit))
                guard let self, self.token == my else { return }
                self.resume()
            }
        }
        if token == my {
            if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
            // Возвращаем громкость другим приложениям.
            AudioSession.deactivateLater()
        }
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        resume()
    }

    private func resume() {
        continuation?.resume()
        continuation = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    private static func voice() -> AVSpeechSynthesisVoice? {
        let ru = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ru") }
        return ru.first { $0.quality == .premium }
            ?? ru.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }
}
