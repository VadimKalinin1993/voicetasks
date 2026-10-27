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

// MARK: - Распознавание речи (на устройстве)

@MainActor
@Observable
final class SpeechInput {
    /// Громкость 0…1 для анимации кнопки.
    var level: Float = 0

    private let engine = AVAudioEngine()
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
    private let pause: TimeInterval = 1.5

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

    /// Слушает до паузы и возвращает текст (nil — ничего не расслышали).
    func listen() async throws -> String? {
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechError(message: "Распознавание речи сейчас недоступно.")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
        // Без этого iOS глушит вибрацию, пока активна сессия записи.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let box = RequestBox(request)
        self.box = box

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechError(message: "Микрофон недоступен.")
        }
        input.removeTap(onBus: 0)
        let onLevel: @Sendable (Float) -> Void = { [weak self] v in
            Task { @MainActor in self?.level = v }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(box, onLevel: onLevel))
        engine.prepare()
        try engine.start()

        transcript = ""
        started = Date()
        lastChange = Date()

        let onResult: @Sendable (String?, Bool, Bool) -> Void = { [weak self] text, isFinal, failed in
            Task { @MainActor in self?.handle(text, isFinal: isFinal, failed: failed) }
        }

        return await withCheckedContinuation { cont in
            self.continuation = cont
            self.task = recognizer.recognitionTask(with: request, resultHandler: Self.makeHandler(onResult))
            self.watcher = Task { [weak self] in await self?.watch() }
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
            if !transcript.isEmpty && now.timeIntervalSince(lastChange) > pause { finish(); return }
            if transcript.isEmpty && now.timeIntervalSince(started) > 7 { finish(); return }
            if now.timeIntervalSince(started) > 30 { finish(); return }
        }
    }

    private func complete(_ text: String?) {
        guard let c = continuation else { return }
        continuation = nil
        watcher?.cancel()
        watcher = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        box?.request.endAudio()
        task?.cancel()
        task = nil
        box = nil
        level = 0
        // Освобождаем аудиосессию: возвращаем звук другим приложениям и включаем вибрацию.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let result = (text?.isEmpty ?? true) ? nil : text
        c.resume(returning: result)
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

// MARK: - Озвучка вопросов

@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) async {
        stop()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.voice()
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        let limit = 2 + Double(text.count) * 0.09
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            synth.speak(u)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(limit))
                self?.resume()
            }
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
