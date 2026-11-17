import AVFoundation
import Speech
import WebKit

/// Speech to text for the Zeus pages (the chat and Zeus Editor), on this Mac only: no audio leaves the Mac.
///
/// Engines:
/// - Whisper (`WhisperSpeechEngine`, `DictationRuntime`): the dictation model of the settings. It gives the text after Stop.
/// - Apple's speech recognition (`AppleSpeechEngine`), while no Whisper model is loaded (the first download,
///   or the load after the app start). It gives text while the user speaks.
/// - For a version 1 page while a Whisper model is loaded, both (`HybridSpeechEngine`): Apple's text while the user
///   speaks, then the Whisper text when it is ready within the page's stop deadline.
///
/// The bridge has versions 1 and 2; docs/speech-bridge.md is the contract.
/// - At document start, `window.zeusApp.speech = {version: 1, versions: [1, 2]}`: version 1 pages check `version === 1`.
/// - A version 2 session starts with `{type: "speech-start", id, version: 2}`; a start without it is a version 1 session.
/// - A page posts `{type: "speech-…"}` messages to `window.webkit.messageHandlers.zeusApp`.
/// - The app calls `window.zeusSpeech?.onEvent(event)` in that page only; the status and settings events go to each
///   page that sent a speech message.
///
/// One recognition runs at a time in the app, from its start until "stopped" (also while Whisper processes).
/// A start while one runs gets the error "busy". After "listening", a recognition always ends with "stopped"
/// (after its "final" text or an error). An error before "listening" is the only answer to that start.
final class SpeechService {
    static let shared = SpeechService()

    /// The page bridge: `window.zeusApp.speech` (see `WebViewHandler.pageBridgeScript`).
    static let pageInfo: [String: Any] = ["version": 1, "versions": [1, 2]]

    private let apple: SpeechEngine
    private let whisper: SpeechEngine
    private let hybrid: HybridSpeechEngine
    private var current: Recognition?
    /// The pages that use speech to text: they get the status and settings events.
    private let pages = NSHashTable<WKWebView>.weakObjects()
    private var statusQueued = false

    private final class Recognition {
        let id: String
        let engine: SpeechEngine
        let engineName: String
        weak var webView: WKWebView?
        var listening = false
        var stopAt: Date?
        init(id: String, engine: SpeechEngine, engineName: String, webView: WKWebView) {
            self.id = id
            self.engine = engine
            self.engineName = engineName
            self.webView = webView
        }
    }

    private init() {
        #if DEBUG
        let mode = DebugEnvironment.value("ZEUS_APP_TEST_SPEECH") ?? ""
        if mode == "whisper" {
            // The whisper path with simulated audio and a simulated model (see `SimulatedTranscriber`).
            apple = SimulatedSpeechEngine(mode: "1")
            whisper = WhisperSpeechEngine { TestAudioSource() }
            hybrid = HybridSpeechEngine(apple: apple) { TestAudioSource() }
            DictationRuntime.shared.factory = { _, file in try SimulatedTranscriber(model: file) }
        } else if !mode.isEmpty {
            apple = SimulatedSpeechEngine(mode: mode)
            whisper = WhisperSpeechEngine { TestAudioSource() }
            hybrid = HybridSpeechEngine(apple: apple) { TestAudioSource() }
        } else if DebugEnvironment.value("ZEUS_APP_TEST_AUDIO_FILE") != nil {
            // The real model, with a sound file instead of the microphone.
            apple = AppleSpeechEngine()
            whisper = WhisperSpeechEngine { TestAudioSource() }
            hybrid = HybridSpeechEngine(apple: apple) { TestAudioSource() }
        } else {
            let appleEngine = AppleSpeechEngine()
            apple = appleEngine
            whisper = WhisperSpeechEngine { MicrophoneSource() }
            hybrid = HybridSpeechEngine(apple: appleEngine) { TapAudioSource(tap: appleEngine.tap) }
        }
        #else
        let appleEngine = AppleSpeechEngine()
        apple = appleEngine
        whisper = WhisperSpeechEngine { MicrophoneSource() }
        // One microphone: Whisper gets the buffers of Apple's recognizer.
        hybrid = HybridSpeechEngine(apple: appleEngine) { TapAudioSource(tap: appleEngine.tap) }
        #endif
        DictationModels.shared.onChange.append { [weak self] in self?.queueStatus() }
        DictationRuntime.shared.onChange.append { [weak self] in self?.queueStatus() }
        DictationSettings.shared.onChange.append { [weak self] in
            self?.queueStatus()
            self?.broadcastSettings()
        }
    }

    /// The engine of a version 2 start now: Whisper when its model is loaded, otherwise Apple's recognizer.
    private var engineNow: (engine: SpeechEngine, name: String) {
        DictationRuntime.shared.isReady ? (whisper, "whisper") : (apple, "apple")
    }

    /// The engine of a version 1 start: Apple's text while the user speaks, with the Whisper text at the end when a
    /// model is loaded.
    private var engineV1: (engine: SpeechEngine, name: String) {
        DictationRuntime.shared.isReady ? (hybrid, "hybrid") : (apple, "apple")
    }

    private static func isVersion2(_ message: [String: Any]) -> Bool {
        ((message["version"] as? NSNumber)?.intValue ?? 1) >= 2
    }

    /// Handles a speech message from a page. Returns false for every other message.
    func handle(_ body: Any, from webView: WKWebView?) -> Bool {
        guard let message = body as? [String: Any], let type = message["type"] as? String,
              type.hasPrefix("speech-") else { return false }
        // Only Zeus pages on this Mac can use the microphone.
        guard let webView, let url = webView.url, ["http", "https"].contains(url.scheme ?? ""), WebViewHandler.isLocal(url) else { return true }
        pages.add(webView)
        switch type {
        case "speech-languages":
            // A version 1 page gets the locales of Apple's recognizer, as before.
            let now: (engine: SpeechEngine, name: String) = Self.isVersion2(message) ? engineNow : (apple, "apple")
            now.engine.languages { [weak webView] languages in
                guard let webView else { return }
                Self.send(["type": "languages", "engine": now.name,
                           "locales": languages.locales.map { ["id": $0.id, "name": $0.name, "onDevice": true] },
                           "default": languages.defaultID], to: webView)
            }
        case "speech-start":
            guard let id = message["id"] as? String, !id.isEmpty else { return true }
            start(id: id, locale: message["locale"] as? String, version2: Self.isVersion2(message), in: webView)
        case "speech-stop":
            guard let id = message["id"] as? String, let current, current.id == id, current.webView === webView else { return true }
            Trace.log("speech: stop \(id) (page)")
            current.stopAt = current.stopAt ?? Date()
            current.engine.stop()
        case "speech-cancel":
            guard let id = message["id"] as? String, let current, current.id == id, current.webView === webView else { return true }
            cancelCurrent(reason: "page")
            Self.send(["type": "state", "id": id, "state": "stopped", "cancelled": true], to: webView)
        case "speech-status":
            Self.send(status(), to: webView)
        case "speech-settings":
            sendSettings(to: [webView], error: nil)
        case "speech-settings-set":
            let words = (message["customWords"] as? [Any]).map { $0.compactMap { $0 as? String } }
            let result = DictationSettings.shared.apply(model: message["model"] as? String, language: message["language"] as? String,
                                                        customWords: words)
            // A change goes to every page through `DictationSettings.onChange`; the sender always gets an answer.
            if !result.changed || result.error != nil { sendSettings(to: [webView], error: result.error) }
        case "speech-model-download":
            if let role = message["model"] as? String { DictationModels.shared.download(role: role) }
        case "speech-model-cancel":
            if let role = message["model"] as? String { DictationModels.shared.cancel(role: role) }
        default:
            break
        }
        return true
    }

    private func start(id: String, locale: String?, version2: Bool, in webView: WKWebView) {
        if current != nil {
            Trace.log("speech: start \(id) refused, busy")
            Self.send(["type": "error", "id": id, "code": "busy",
                       "message": "Speech to text is already on in another Zeus page. Stop it there first."], to: webView)
            return
        }
        let now = version2 ? engineNow : engineV1
        let recognition = Recognition(id: id, engine: now.engine, engineName: now.name, webView: webView)
        current = recognition
        let locale = locale.flatMap { $0.isEmpty ? nil : $0 }
        Trace.log("speech: start \(id) locale=\(locale ?? "default") engine=\(now.name) bridge=\(version2 ? 2 : 1)")
        // Without a locale, Apple's recognizer of a version 2 session takes the fixed language of the dictation settings.
        let language = DictationSettings.shared.language
        let engineLocale = locale ?? (version2 && now.name == "apple" && language != "auto" ? language : nil)
        now.engine.start(locale: engineLocale) { [weak self, weak recognition] event in
            guard let self, let recognition, self.current === recognition else { return }
            self.deliver(event, for: recognition)
        }
    }

    private func deliver(_ event: SpeechEngineEvent, for recognition: Recognition) {
        let id = recognition.id
        var events: [[String: Any]] = []
        switch event {
        case .listening:
            recognition.listening = true
            events.append(["type": "state", "id": id, "state": "listening", "engine": recognition.engineName])
        case let .level(level):
            // Many per second: no trace line.
            if let webView = recognition.webView { Self.send(["type": "level", "id": id, "level": Double(level)], to: webView) }
            return
        case let .processing(limit):
            recognition.stopAt = recognition.stopAt ?? Date()
            var item: [String: Any] = ["type": "state", "id": id, "state": "processing"]
            if limit { item["reason"] = "limit" }
            events.append(item)
        case let .partial(text):
            events.append(["type": "partial", "id": id, "text": text])
        case let .final(text):
            let engine = (recognition.engine as? HybridSpeechEngine)?.finalEngine ?? recognition.engineName
            if let stopAt = recognition.stopAt {
                Trace.log("speech: final \(id) engine=\(engine) stop-to-text=\(Int(Date().timeIntervalSince(stopAt) * 1000)) ms")
            }
            events.append(["type": "final", "id": id, "text": text, "engine": engine])
        case let .failed(code, message):
            events.append(["type": "error", "id": id, "code": code.rawValue, "message": message])
        case .ended:
            break
        }
        if event.isEnd {
            current = nil
            if recognition.listening || event == .ended { events.append(["type": "state", "id": id, "state": "stopped"]) }
        }
        for item in events {
            Trace.log("speech event: \(Self.describe(item))")
            if let webView = recognition.webView { Self.send(item, to: webView) }
        }
    }

    /// Ends the recording of this page and gives the page its last text: for a tab that the user leaves.
    /// The page keeps the session until its "stopped", also while Whisper processes.
    func stop(in webView: WKWebView?, reason: String) {
        guard let current, let webView, current.webView === webView else { return }
        Trace.log("speech: stop \(current.id) (\(reason))")
        current.stopAt = current.stopAt ?? Date()
        current.engine.stop()
    }

    /// Ends the recognition of this page at once, without more events: for a page that closes or goes away.
    /// A Whisper transcription that runs stops too.
    func cancel(in webView: WKWebView?, reason: String) {
        guard let current, let webView, current.webView === webView else { return }
        cancelCurrent(reason: reason)
    }

    /// Ends any recognition at once: the app quits.
    func cancelAll(reason: String) {
        guard current != nil else { return }
        cancelCurrent(reason: reason)
    }

    private func cancelCurrent(reason: String) {
        guard let recognition = current else { return }
        Trace.log("speech: cancel \(recognition.id) (\(reason))")
        current = nil
        recognition.engine.cancel()
    }

    // MARK: Status and settings

    private func queueStatus() {
        guard !statusQueued else { return }
        statusQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusQueued = false
            let status = self.status()
            for webView in self.pages.allObjects { Self.send(status, to: webView) }
        }
    }

    /// The dictation status: the engine of a start now, the loaded model, and the state of each model of the model list.
    private func status() -> [String: Any] {
        let models = DictationModels.shared
        let runtime = DictationRuntime.shared
        var status: [String: Any] = [
            "type": "status",
            "engine": engineNow.name,
            "selected": DictationSettings.shared.role,
            "active": runtime.loaded.map { loaded -> Any in
                ["role": loaded.role, "id": loaded.id, "name": models.model(for: loaded.role)?.name ?? loaded.role]
            } ?? NSNull(),
        ]
        switch runtime.state {
        case .idle: status["runtime"] = "idle"
        case let .loading(id): status["runtime"] = "loading"; status["loading"] = id
        case .ready: status["runtime"] = "ready"
        case let .failed(_, message): status["runtime"] = "failed"; status["runtimeError"] = message
        }
        status["models"] = models.manifest.models.map { model -> [String: Any] in
            var item: [String: Any] = [
                "role": model.role, "id": model.id, "name": model.name, "description": model.description,
                "bytes": model.bytes, "multilingual": model.multilingual, "license": model.license,
                "installed": models.installedID(for: model.role) == model.id,
            ]
            if let languages = model.languages { item["languages"] = languages }
            switch models.state(of: model) {
            case .missing: item["state"] = "missing"
            case let .downloading(received, total): item["state"] = "downloading"; item["received"] = received; item["total"] = total
            case .verifying: item["state"] = "verifying"
            case .downloaded: item["state"] = "ready"
            case let .failed(message):
                item["state"] = "failed"
                item["error"] = message
                if let retry = models.retryAt[model.id] { item["retryAt"] = Int(retry.timeIntervalSince1970 * 1000) }
            case .cancelled: item["state"] = "cancelled"
            }
            return item
        }
        return status
    }

    private func broadcastSettings() {
        sendSettings(to: pages.allObjects, error: nil)
    }

    /// The settings, with the prompt of the custom words counted in tokens of the loaded model.
    private func sendSettings(to webViews: [WKWebView], error: String?) {
        let settings = DictationSettings.shared
        let model = DictationModels.shared.model(for: settings.role)
        var languages: [[String: Any]] = DictationSettings.languages(of: model).map { ["id": $0.id, "name": $0.name] }
        if model?.multilingual == true { languages.insert(["id": "auto", "name": "Auto-detect"], at: 0) }
        let words = settings.customWords
        let prompt = DictationRuntime.shared.prompt(words: words)
        var event: [String: Any] = [
            "type": "settings",
            "model": settings.role,
            "models": DictationModels.shared.manifest.models.map { ["role": $0.role, "name": $0.name, "description": $0.description] },
            "language": settings.language,
            "effectiveLanguage": settings.effectiveLanguage(for: model) ?? "auto",
            "languages": languages,
            "allLanguages": DictationSettings.allLanguages.map { ["id": $0.id, "name": $0.name] },
            "customWords": words,
            "prompt": ["limit": DictationSettings.promptTokenLimit, "tokens": prompt.tokens, "included": prompt.included,
                       "total": words.count, "estimated": prompt.estimated],
            "recordingLimitSeconds": Int(WhisperSpeechEngine.recordingLimit),
        ]
        if let error { event["error"] = error }
        for webView in webViews { Self.send(event, to: webView) }
    }


    /// The trace line of an event: its type, id, and state or error code; of a text only its length.
    private static func describe(_ event: [String: Any]) -> String {
        let type = event["type"] as? String ?? "-"
        let id = event["id"] as? String ?? "-"
        let detail = event["state"] as? String ?? event["code"] as? String
            ?? (event["text"] as? String).map { "chars=\($0.count)" } ?? ""
        let engine = (event["engine"] as? String).map { " engine=\($0)" } ?? ""
        return "\(type) \(id) \(detail)\(engine)"
    }

    private static func send(_ event: [String: Any], to webView: WKWebView) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.zeusSpeech?.onEvent?.(\(json)); void 0")
    }
}

// MARK: - Engines

enum SpeechErrorCode: String {
    case permissionDenied = "permission-denied"
    case noOnDevice = "no-on-device"
    case unavailable
    case failed
}

enum SpeechEngineEvent: Equatable {
    case listening
    /// The loudness of the microphone, 0...1 (Whisper, about 20 times a second).
    case level(Float)
    /// The recording has ended and Whisper turns it into text (`limit`: after the 10-minute limit).
    case processing(limit: Bool)
    case partial(String)
    /// The last text. The recognition then has ended.
    case final(String)
    /// The recognition has ended with an error.
    case failed(SpeechErrorCode, String)
    /// The recognition ended before it listened (a stop during the permission questions).
    case ended

    var isEnd: Bool {
        switch self {
        case .final, .failed, .ended: return true
        case .listening, .level, .processing, .partial: return false
        }
    }
}

struct SpeechLanguages {
    struct Language {
        let id: String
        let name: String
    }

    let locales: [Language]
    let defaultID: String
}

/// A speech recognizer. All calls and callbacks are on the main queue. After `start`, the engine sends at most one
/// `.listening`, then levels or partial texts, at most one `.processing`, then exactly one end event
/// (`.final`, `.failed`, or `.ended`), unless `cancel` comes first.
protocol SpeechEngine: AnyObject {
    func languages(completion: @escaping (SpeechLanguages) -> Void)
    /// `locale` nil is the language of this Mac.
    func start(locale: String?, onEvent: @escaping (SpeechEngineEvent) -> Void)
    /// Ends the audio; the engine then sends the last text.
    func stop()
    /// Ends at once, with no more events.
    func cancel()
}

extension SpeechEngine {
    /// The language of this Mac among the given languages: the same language and region first,
    /// then the same language with the region of this Mac, then the same language.
    static func defaultLocale(among ids: [String]) -> String {
        let wanted = Locale.preferredLanguages + [Locale.current.identifier]
        let normalized = wanted.map(Self.bcp47)
        if let exact = normalized.first(where: { ids.contains($0) }) { return exact }
        let region = Locale.current.region?.identifier
        for candidate in normalized {
            let language = Self.languageCode(candidate)
            let same = ids.filter { Self.languageCode($0) == language }
            if let match = same.first(where: { Self.regionCode($0) == region }) ?? same.first { return match }
        }
        return normalized.first ?? "en-US"
    }

    static func bcp47(_ identifier: String) -> String {
        // "en_US@calendar=..." becomes "en-US".
        let base = identifier.split(separator: "@").first.map(String.init) ?? identifier
        return base.replacingOccurrences(of: "_", with: "-")
    }

    static func languageCode(_ id: String) -> String {
        String(id.split(separator: "-").first ?? "").lowercased()
    }

    static func regionCode(_ id: String) -> String? {
        id.split(separator: "-").dropFirst().last.map(String.init)?.uppercased()
    }

    static func displayName(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }
}

/// Apple's speech recognition (SFSpeechRecognizer) with the microphone (AVAudioEngine), on this Mac only.
final class AppleSpeechEngine: SpeechEngine {
    /// The microphone buffers, also for Whisper in a version 1 session (see `HybridSpeechEngine`).
    let tap = BufferTap()
    private var generation = 0
    private var onEvent: ((SpeechEngineEvent) -> Void)?
    private var audio: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastText = ""
    private var stopping = false

    /// The languages that this Mac can recognize on the Mac.
    private static func onDeviceLocales() -> [String] {
        let ids = SFSpeechRecognizer.supportedLocales()
            .map { bcp47($0.identifier) }
            .filter { SFSpeechRecognizer(locale: Locale(identifier: $0))?.supportsOnDeviceRecognition == true }
        return Set(ids).sorted()
    }

    func languages(completion: @escaping (SpeechLanguages) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ids = Self.onDeviceLocales()
            let languages = ids.map { SpeechLanguages.Language(id: $0, name: Self.displayName($0)) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let result = SpeechLanguages(locales: languages, defaultID: Self.defaultLocale(among: ids))
            DispatchQueue.main.async { completion(result) }
        }
    }

    func start(locale: String?, onEvent: @escaping (SpeechEngineEvent) -> Void) {
        reset()
        generation += 1
        let generation = generation
        self.onEvent = onEvent
        stopping = false
        lastText = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let id = Self.locale(for: locale)
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id))
            let onDevice = recognizer?.supportsOnDeviceRecognition == true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                guard let recognizer, onDevice else {
                    self.finish(.failed(.noOnDevice, "This Mac cannot recognize \(Self.displayName(id)) on the Mac. "
                        + "Choose another language, or add it in System Settings > Keyboard > Dictation."))
                    return
                }
                self.authorize(generation: generation) { [weak self] in self?.listen(with: recognizer, generation: generation) }
            }
        }
    }

    /// The locale of a start: a full locale as it is; a language without a region ("fr", a Whisper language of the
    /// dictation settings) as the on-device locale of that language, with the region of this Mac first; nil as the Mac.
    private static func locale(for requested: String?) -> String {
        guard let requested else { return defaultLocale(among: onDeviceLocales()) }
        let id = bcp47(requested)
        guard !id.contains("-") else { return id }
        let same = onDeviceLocales().filter { languageCode($0) == id.lowercased() }
        return same.first { regionCode($0) == Locale.current.region?.identifier } ?? same.first ?? id
    }

    /// Asks for speech recognition and the microphone only when they were never asked for.
    private func authorize(generation: Int, then listen: @escaping () -> Void) {
        let speechDenied = "Zeus has no permission for speech recognition. "
            + "Allow Zeus in System Settings > Privacy & Security > Speech Recognition."
        let microphoneDenied = "Zeus has no permission for the microphone. "
            + "Allow Zeus in System Settings > Privacy & Security > Microphone."
        let afterSpeech: (SFSpeechRecognizerAuthorizationStatus) -> Void = { [weak self] status in
            guard let self, self.generation == generation, !self.endedBeforeListening() else { return }
            guard status == .authorized else { self.finish(.failed(.permissionDenied, speechDenied)); return }
            let afterMicrophone: (Bool) -> Void = { [weak self] granted in
                guard let self, self.generation == generation, !self.endedBeforeListening() else { return }
                guard granted else { self.finish(.failed(.permissionDenied, microphoneDenied)); return }
                listen()
            }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: afterMicrophone(true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { afterMicrophone(granted) } }
            default: afterMicrophone(false)
            }
        }
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { status in DispatchQueue.main.async { afterSpeech(status) } }
        } else {
            afterSpeech(status)
        }
    }

    /// A stop that came during the permission questions ends the recognition before it listens.
    private func endedBeforeListening() -> Bool {
        guard stopping else { return false }
        finish(.ended)
        return true
    }

    private func listen(with recognizer: SFSpeechRecognizer, generation: Int) {
        guard recognizer.isAvailable else {
            finish(.failed(.unavailable, "Speech recognition is not available now. Try again in a moment."))
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let audio = AVAudioEngine()
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            finish(.failed(.unavailable, "Zeus finds no microphone. Connect a microphone and try again."))
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [tap] buffer, _ in
            request.append(buffer)
            tap.send(buffer)
        }
        audio.prepare()
        do {
            try audio.start()
        } catch {
            input.removeTap(onBus: 0)
            finish(.failed(.failed, "The microphone does not start: \(error.localizedDescription)"))
            return
        }
        self.audio = audio
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            DispatchQueue.main.async { self?.recognized(text: text, isFinal: isFinal, error: error, generation: generation) }
        }
        onEvent?(.listening)
    }

    private func recognized(text: String?, isFinal: Bool, error: Error?, generation: Int) {
        guard self.generation == generation, onEvent != nil else { return }
        if let text, text != lastText {
            lastText = text
            if !isFinal { onEvent?(.partial(text)) }
        }
        if isFinal { finish(.final(lastText)); return }
        guard let error else { return }
        let nsError = error as NSError
        Trace.log("speech: recognizer error \(nsError.domain) \(nsError.code)")
        // After a stop, or when no speech came, the recognition ends with the text that it has.
        if stopping || (nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110) {
            finish(.final(lastText))
        } else {
            finish(.failed(.failed, "Speech recognition stopped: \(nsError.localizedDescription)"))
        }
    }

    func stop() {
        guard onEvent != nil, !stopping else { return }
        stopping = true
        // Before the microphone runs, the recognition ends when the permission questions are answered.
        guard let audio else { return }
        self.audio = nil
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // The recognizer sends its last result; do not wait for it for ever.
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.generation == generation, self.onEvent != nil else { return }
            self.finish(.final(self.lastText))
        }
    }

    func cancel() {
        generation += 1
        reset()
    }

    private func finish(_ event: SpeechEngineEvent) {
        let onEvent = self.onEvent
        reset()
        onEvent?(event)
    }

    private func reset() {
        onEvent = nil
        if let audio {
            if audio.isRunning { audio.stop() }
            audio.inputNode.removeTap(onBus: 0)
        }
        audio = nil
        task?.cancel()
        task = nil
        request = nil
    }
}

#if DEBUG
/// A recognizer for the tests (`ZEUS_APP_TEST_SPEECH`): no microphone, no permission questions.
/// It knows English, French, Dutch, and German on the Mac, and Japanese only off the Mac. It "hears" "Hello Zeus".
/// With `ZEUS_APP_TEST_SPEECH=denied`, the user did not give permission.
final class SimulatedSpeechEngine: SpeechEngine {
    private let mode: String
    private var generation = 0
    private var onEvent: ((SpeechEngineEvent) -> Void)?
    private var text = ""
    private let onDevice = ["en-US", "fr-FR", "nl-NL", "de-DE"]

    init(mode: String) { self.mode = mode }

    func languages(completion: @escaping (SpeechLanguages) -> Void) {
        let locales = onDevice.map { SpeechLanguages.Language(id: $0, name: Self.displayName($0)) }
        DispatchQueue.main.async { completion(SpeechLanguages(locales: locales, defaultID: "en-US")) }
    }

    func start(locale: String?, onEvent: @escaping (SpeechEngineEvent) -> Void) {
        generation += 1
        let generation = generation
        self.onEvent = onEvent
        text = ""
        let id = locale ?? "en-US"
        after(0.1, generation) { [self] in
            if mode == "denied" {
                finish(.failed(.permissionDenied, "Zeus has no permission for speech recognition."))
            } else if !onDevice.contains(id) {
                finish(.failed(.noOnDevice, "This Mac cannot recognize \(Self.displayName(id)) on the Mac."))
            } else {
                onEvent(.listening)
                after(0.2, generation) { [self] in text = "Hello"; onEvent(.partial(text)) }
                after(0.4, generation) { [self] in text = "Hello Zeus"; onEvent(.partial(text)) }
            }
        }
    }

    func stop() {
        let generation = generation
        after(0.1, generation) { [self] in finish(.final(text.isEmpty ? "" : text + ".")) }
    }

    func cancel() {
        generation += 1
        onEvent = nil
    }

    private func after(_ delay: TimeInterval, _ generation: Int, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == generation, self.onEvent != nil else { return }
            work()
        }
    }

    private func finish(_ event: SpeechEngineEvent) {
        let onEvent = self.onEvent
        self.onEvent = nil
        onEvent?(event)
    }
}
#endif
