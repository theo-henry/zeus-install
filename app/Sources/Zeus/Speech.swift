import AVFoundation
import Speech
import WebKit

/// Speech to text for the Zeus pages (the chat and Zeus Editor), with Apple's speech recognition on this Mac.
/// The recognition runs on the Mac only (`requiresOnDeviceRecognition`): no audio leaves the Mac.
///
/// The bridge between a page and the app:
/// - The app tells each page that it can do speech to text: `window.zeusApp.speech.version === 1`.
/// - A page posts `{type: "speech-languages"}`, `{type: "speech-start", id, locale}` (`locale` is a BCP-47 id or null
///   for the default), and `{type: "speech-stop", id}` to `window.webkit.messageHandlers.zeusApp`.
/// - The app calls `window.zeusSpeech?.onEvent(event)` in that page only, with
///   `{type: "languages", locales: [{id, name, onDevice: true}], default}`, `{type: "state", id, state: "listening" | "stopped"}`,
///   `{type: "partial", id, text}`, `{type: "final", id, text}`, and
///   `{type: "error", id, code: "permission-denied" | "no-on-device" | "unavailable" | "busy" | "failed", message}`.
///
/// One recognition runs at a time in the app; a start while one runs gets the error "busy".
/// After "listening", a recognition always ends with "stopped" (after its "final" text or an error).
/// An error before "listening" is the only answer to that start.
final class SpeechService {
    static let shared = SpeechService()

    /// Runs at document start in every Zeus page. A page that replaces `window.zeusApp` (for its close check)
    /// keeps `speech`: the property gives back the page's object with `speech` added.
    static let availabilityScript = WKUserScript(source: """
        (() => {
          const speech = Object.freeze({ version: 1 });
          const withSpeech = (value) => {
            if (value === null || typeof value !== "object" || value.speech === speech) return value;
            if (Object.isExtensible(value)) return Object.assign(value, { speech });
            const wrapped = Object.create(value, { speech: { value: speech, enumerable: true } });
            return Object.isFrozen(value) ? Object.freeze(wrapped) : wrapped;
          };
          let current = withSpeech(Object.assign(window.zeusApp || {}, { speech }));
          Object.defineProperty(window, "zeusApp", {
            configurable: true,
            enumerable: true,
            get: () => current,
            set: (value) => { current = withSpeech(value); },
          });
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)

    private let engine: SpeechEngine
    private var current: Recognition?

    private final class Recognition {
        let id: String
        weak var webView: WKWebView?
        var listening = false
        init(id: String, webView: WKWebView) {
            self.id = id
            self.webView = webView
        }
    }

    private init() {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["ZEUS_APP_TEST_SPEECH"], !mode.isEmpty {
            engine = SimulatedSpeechEngine(mode: mode)
            return
        }
        #endif
        engine = AppleSpeechEngine()
    }

    /// Handles a speech message from a page. Returns false for every other message.
    func handle(_ body: Any, from webView: WKWebView?) -> Bool {
        guard let message = body as? [String: Any], let type = message["type"] as? String,
              type.hasPrefix("speech-") else { return false }
        // Only Zeus pages on this Mac can use the microphone.
        guard let webView, let url = webView.url, ["http", "https"].contains(url.scheme ?? ""), WebViewHandler.isLocal(url) else { return true }
        switch type {
        case "speech-languages":
            engine.languages { [weak webView] languages in
                guard let webView else { return }
                Self.send(["type": "languages",
                           "locales": languages.locales.map { ["id": $0.id, "name": $0.name, "onDevice": true] },
                           "default": languages.defaultID], to: webView)
            }
        case "speech-start":
            guard let id = message["id"] as? String, !id.isEmpty else { return true }
            start(id: id, locale: message["locale"] as? String, in: webView)
        case "speech-stop":
            guard let id = message["id"] as? String, let current, current.id == id, current.webView === webView else { return true }
            Trace.log("speech: stop \(id) (page)")
            engine.stop()
        default:
            break
        }
        return true
    }

    private func start(id: String, locale: String?, in webView: WKWebView) {
        if current != nil {
            Trace.log("speech: start \(id) refused, busy")
            Self.send(["type": "error", "id": id, "code": "busy",
                       "message": "Speech to text is already on in another Zeus page. Stop it there first."], to: webView)
            return
        }
        let recognition = Recognition(id: id, webView: webView)
        current = recognition
        let locale = locale.flatMap { $0.isEmpty ? nil : $0 }
        Trace.log("speech: start \(id) locale=\(locale ?? "default")")
        engine.start(locale: locale) { [weak self, weak recognition] event in
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
            events.append(["type": "state", "id": id, "state": "listening"])
        case let .partial(text):
            events.append(["type": "partial", "id": id, "text": text])
        case let .final(text):
            events.append(["type": "final", "id": id, "text": text])
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

    /// Ends the recognition of this page and gives the page its last text: for a tab that the user leaves.
    func stop(in webView: WKWebView?, reason: String) {
        guard let current, let webView, current.webView === webView else { return }
        Trace.log("speech: stop \(current.id) (\(reason))")
        engine.stop()
    }

    /// Ends the recognition of this page at once, without more events: for a page that closes or goes away.
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
        engine.cancel()
    }

    /// The trace line of an event: its type, id, and state or error code; of a text only its length.
    private static func describe(_ event: [String: Any]) -> String {
        let type = event["type"] as? String ?? "-"
        let id = event["id"] as? String ?? "-"
        let detail = event["state"] as? String ?? event["code"] as? String
            ?? (event["text"] as? String).map { "chars=\($0.count)" } ?? ""
        return "\(type) \(id) \(detail)"
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
        case .listening, .partial: return false
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
/// `.listening`, then partial texts, then exactly one end event (`.final`, `.failed`, or `.ended`), unless `cancel` comes first.
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
            let id = locale.map(Self.bcp47) ?? Self.defaultLocale(among: Self.onDeviceLocales())
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
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
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
