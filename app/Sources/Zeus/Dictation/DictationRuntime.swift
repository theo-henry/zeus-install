import Foundation
import whisper

/// A stop flag that the decoder reads from its own thread.
final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

enum TranscriptionError: Error {
    case cancelled
    case failed(String)

    var message: String {
        switch self {
        case .cancelled: return "cancelled"
        case let .failed(text): return text
        }
    }
}

/// A loaded model that turns 16 kHz mono Float32 samples into text.
/// Only `DictationRuntime` calls it, on its own queue, one call at a time.
protocol Transcriber: AnyObject {
    var multilingual: Bool { get }
    /// One short run after the load, so that the first dictation does not pay for the first run of the GPU code.
    func warmUp()
    func tokenCount(_ text: String) -> Int
    /// `language` nil is auto-detection.
    func transcribe(_ samples: [Float], language: String?, prompt: DictationSettings.Prompt, abort: AbortFlag) throws -> String
}

/// Keeps one dictation model loaded for the whole app (all chat tabs and Zeus Editor pages share it),
/// and runs each transcription off the main queue.
///
/// The model of the chosen role loads in the background after the app starts and stays loaded.
/// A new model (another role, or a new model of the model list) loads next to the old one;
/// the old one is in use until the new one is ready. Loads and transcriptions run one after the other.
/// All calls and callbacks are on the main queue.
final class DictationRuntime {
    static let shared = DictationRuntime()

    enum State: Equatable {
        case idle
        case loading(String)
        case ready(String)
        case failed(String, String)
    }

    /// Makes the transcriber of a model file; the model list's `engine` picks the code.
    typealias Factory = (_ engine: String, _ file: URL) throws -> Transcriber

    private(set) var state: State = .idle
    /// The role and id of the loaded model.
    private(set) var loaded: (role: String, id: String)?
    private(set) var multilingual = true
    var onChange: [() -> Void] = []

    private let queue = DispatchQueue(label: "io.github.theo-henry.zeus.dictation", qos: .userInitiated)
    /// Only on `queue`.
    private var transcriber: Transcriber?
    private var loadingID: String?
    private var failedIDs = Set<String>()
    private var started = false
    var factory: Factory = DictationRuntime.makeTranscriber

    var isReady: Bool { loaded != nil }

    /// Starts to load the model in the background (after the app start), and follows later changes.
    func start() {
        guard !started else { return }
        started = true
        DictationModels.shared.onChange.append { [weak self] in self?.refresh() }
        DictationSettings.shared.onChange.append { [weak self] in self?.refresh() }
        refresh()
    }

    /// Loads the model of the chosen role when it is on this Mac and is not the loaded one.
    /// While the model of the chosen role is not on this Mac, the loaded model stays in use.
    func refresh() {
        guard started else { return }
        let models = DictationModels.shared
        let role = DictationSettings.shared.role
        guard let candidate = models.candidate(for: role), candidate.id != loaded?.id, candidate.id != loadingID,
              !failedIDs.contains(candidate.id) else { return }
        let engine = models.model(for: role).flatMap { $0.id == candidate.id ? $0.engine : nil } ?? "whisper"
        loadingID = candidate.id
        set(.loading(candidate.id))
        Trace.log("dictation: loading \(candidate.id) for \(role)")
        let started = Date()
        let factory = factory
        queue.async { [weak self] in
            // The swap frees the old model on this queue, after the transcriptions that used it.
            // Only the queue holds a transcriber, so that `shutdown` can free it.
            let result = Result { try factory(engine, candidate.file) }.map { new -> Bool in
                self?.transcriber = new
                return new.multilingual
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingID = nil
                let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
                switch result {
                case let .success(multilingual):
                    self.loaded = (role, candidate.id)
                    self.multilingual = multilingual
                    Trace.log("dictation: loaded \(candidate.id) in \(seconds) s")
                    self.set(.ready(candidate.id))
                    self.warmUp(candidate.id)
                    if !candidate.committed { models.commit(role: role, id: candidate.id) }
                case let .failure(error):
                    let message = (error as? TranscriptionError)?.message ?? error.localizedDescription
                    Trace.log("dictation: loading \(candidate.id) failed after \(seconds) s: \(message)")
                    self.failedIDs.insert(candidate.id)
                    if !candidate.committed {
                        // A new model that does not load: the role keeps its old model.
                        models.reject(id: candidate.id, message: message)
                    }
                    self.set(self.loaded.map { .ready($0.id) } ?? .failed(candidate.id, message))
                }
                self.refresh()
            }
        }
    }

    private func warmUp(_ id: String) {
        queue.async { [weak self] in
            guard let transcriber = self?.transcriber else { return }
            let started = Date()
            transcriber.warmUp()
            Trace.log("dictation: warmed up \(id) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        }
    }

    /// Frees the model before the app exits, after a transcription or a load that runs.
    /// ggml stops the process with an assertion when its Metal device ends at exit while a model is still loaded.
    func shutdown() {
        started = false
        queue.sync { transcriber = nil }
        Trace.log("dictation: model freed")
    }

    /// The language of a transcription: the language of a v1 page's locale, or the setting.
    func language(for locale: String?) -> String? {
        if !multilingual { return "en" }
        if let locale { return String(locale.split(separator: "-").first ?? "").lowercased() }
        let setting = DictationSettings.shared.language
        return setting == "auto" ? nil : setting
    }

    /// Runs one transcription with the custom words of the settings. Returns the flag that cancels it.
    @discardableResult
    func transcribe(_ samples: [Float], language: String?, completion: @escaping (Result<String, TranscriptionError>) -> Void) -> AbortFlag {
        let abort = AbortFlag()
        let words = DictationSettings.shared.customWords
        queue.async { [weak self] in
            let result: Result<String, TranscriptionError>
            if let transcriber = self?.transcriber {
                let prompt = DictationSettings.prompt(words: words, count: transcriber.tokenCount)
                do {
                    result = .success(try transcriber.transcribe(samples, language: language, prompt: prompt, abort: abort))
                } catch let error as TranscriptionError {
                    result = .failure(error)
                } catch {
                    result = .failure(.failed(error.localizedDescription))
                }
            } else {
                result = .failure(.failed("The dictation model is not loaded."))
            }
            DispatchQueue.main.async { completion(abort.isSet ? .failure(.cancelled) : result) }
        }
        return abort
    }

    /// The prompt of the custom words, counted with the loaded model when there is one.
    func prompt(words: [String], completion: @escaping (DictationSettings.Prompt) -> Void) {
        queue.async { [weak self] in
            let prompt = DictationSettings.prompt(words: words, count: self?.transcriber?.tokenCount)
            DispatchQueue.main.async { completion(prompt) }
        }
    }

    private func set(_ state: State) {
        self.state = state
        onChange.forEach { $0() }
    }

    static func makeTranscriber(engine: String, file: URL) throws -> Transcriber {
        switch engine {
        case "whisper":
            guard let vad = Bundle.main.url(forResource: "ggml-silero-v5.1.2", withExtension: "bin") else {
                throw TranscriptionError.failed("The voice detector is missing from the app.")
            }
            return try WhisperTranscriber(model: file, vad: vad)
        default:
            throw TranscriptionError.failed("This app does not know the model engine \"\(engine)\". Update Zeus.")
        }
    }
}

/// whisper.cpp through its C API: the weights load once, and each transcription gets a fresh decoder state.
/// Adapted from OpenSuperWhisper (MIT, see THIRD-PARTY-NOTICES.md): its `WhisperEngine` settings, its Silero voice
/// detection, and its speech-only stitching of the samples.
final class WhisperTranscriber: Transcriber {
    private let context: OpaquePointer
    private let vad: OpaquePointer
    let multilingual: Bool

    init(model: URL, vad vadModel: URL) throws {
        Self.silenceLogs()
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let context = whisper_init_from_file_with_params_no_state(model.path, params) else {
            throw TranscriptionError.failed("whisper.cpp cannot load \(model.lastPathComponent).")
        }
        var vadParams = whisper_vad_default_context_params()
        vadParams.n_threads = 1
        guard let vad = whisper_vad_init_from_file_with_params(vadModel.path, vadParams) else {
            whisper_free(context)
            throw TranscriptionError.failed("whisper.cpp cannot load the voice detector.")
        }
        self.context = context
        self.vad = vad
        multilingual = whisper_is_multilingual(context) != 0
    }

    deinit {
        whisper_vad_free(vad)
        whisper_free(context)
    }

    /// whisper.cpp and ggml write much to stderr; Zeus does not show it. Debug builds show it with `ZEUS_APP_WHISPER_LOG=1`.
    private static let silenceLogs: () -> Void = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZEUS_APP_WHISPER_LOG"] == "1" { return {} }
        #endif
        whisper_log_set({ _, _, _ in }, nil)
        return {}
    }()

    func tokenCount(_ text: String) -> Int {
        max(0, Int(-whisper_tokenize(context, text, nil, 0)))
    }

    func warmUp() {
        guard let state = whisper_init_state(context) else { return }
        defer { whisper_free_state(state) }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8)))
        params.no_timestamps = true
        params.single_segment = true
        params.max_tokens = 1
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        let language = strdup("en")
        defer { free(language) }
        params.language = UnsafePointer(language)
        let second = [Float](repeating: 0, count: 16000)
        _ = second.withUnsafeBufferPointer { whisper_full_with_state(context, state, params, $0.baseAddress, Int32($0.count)) }
    }

    func transcribe(_ samples: [Float], language: String?, prompt: DictationSettings.Prompt, abort: AbortFlag) throws -> String {
        guard !abort.isSet else { throw TranscriptionError.cancelled }
        let started = Date()
        let speech = try speechOnly(samples)
        let vadSeconds = Date().timeIntervalSince(started)
        defer {
            Trace.log(String(format: "dictation: transcribed %.1f s of audio (%.1f s of speech): voice detection %.3f s, total %.3f s",
                             Double(samples.count) / 16000, Double(speech.count) / 16000, vadSeconds, Date().timeIntervalSince(started)))
        }
        guard !speech.isEmpty else { return "" }
        guard !abort.isSet else { throw TranscriptionError.cancelled }
        guard let state = whisper_init_state(context) else { throw TranscriptionError.failed("whisper.cpp cannot make a decoder state.") }
        defer { whisper_free_state(state) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8)))
        // As whisper.cpp: on a temperature fallback, the best of 5 samples.
        params.greedy.best_of = 5
        // The text of the earlier 30 s windows of this recording is context for the next window; a fresh state per
        // recording keeps recordings apart.
        params.no_context = false
        let rolling = max(1, Int(whisper_n_text_ctx(context)) / 2)
        params.n_max_text_ctx = Int32(rolling)
        params.no_timestamps = true
        params.suppress_blank = true
        params.temperature = 0
        params.no_speech_thold = 0.6
        params.detect_language = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        // The custom words carry to each window only while they use at most half of the rolling context.
        params.carry_initial_prompt = !prompt.text.isEmpty && prompt.tokens <= max(1, (rolling - 1) / 2)
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<AbortFlag>.fromOpaque(userData).takeUnretainedValue().isSet
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()

        // The C strings live until whisper_full_with_state returns.
        let languageText = strdup(language ?? "auto")
        let promptText = prompt.text.isEmpty ? nil : strdup(prompt.text)
        defer {
            free(languageText)
            free(promptText)
        }
        params.language = UnsafePointer(languageText)
        params.initial_prompt = promptText.map { UnsafePointer($0) }

        let status = speech.withUnsafeBufferPointer { buffer in
            whisper_full_with_state(context, state, params, buffer.baseAddress, Int32(buffer.count))
        }
        if abort.isSet { throw TranscriptionError.cancelled }
        guard status == 0 else { throw TranscriptionError.failed("whisper.cpp stopped with code \(status).") }
        var text = ""
        for index in 0..<whisper_full_n_segments_from_state(state) {
            if let segment = whisper_full_get_segment_text_from_state(state, index) { text += String(cString: segment) }
        }
        return text.replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .replacingOccurrences(of: "[MUSIC]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only the speech of the recording, as whisper.cpp stitches it: each speech part with 0.1 s of the audio after it,
    /// and 0.1 s of silence between the parts. Silence alone gives no samples, so the model cannot invent text for it.
    private func speechOnly(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard let segments = samples.withUnsafeBufferPointer({ buffer in
            whisper_vad_segments_from_samples(vad, whisper_vad_default_params(), buffer.baseAddress, Int32(buffer.count))
        }) else { throw TranscriptionError.failed("The voice detector failed.") }
        defer { whisper_vad_free_segments(segments) }
        let count = Int(whisper_vad_segments_n_segments(segments))
        let perCentisecond = 160
        let gap = 1600
        var result: [Float] = []
        for index in 0..<count {
            let start = min(max(0, Int(whisper_vad_segments_get_segment_t0(segments, Int32(index))) * perCentisecond), samples.count)
            var end = min(Int(whisper_vad_segments_get_segment_t1(segments, Int32(index))) * perCentisecond, samples.count)
            if index < count - 1 { end = min(end + gap, samples.count) }
            guard end > start else { continue }
            result.append(contentsOf: samples[start..<end])
            if index < count - 1 { result.append(contentsOf: repeatElement(0, count: gap)) }
        }
        return result
    }
}

#if DEBUG
/// The model of the tests (`ZEUS_APP_TEST_SPEECH=whisper`): the file must start with
/// "ZEUS-SIMULATED-MODEL"; it "hears" "Hello Zeus." and adds the custom words that it got, in brackets.
final class SimulatedTranscriber: Transcriber {
    let multilingual: Bool

    init(model: URL) throws {
        let head = (try? FileHandle(forReadingFrom: model).readData(ofLength: 64)) ?? Data()
        let text = String(decoding: head, as: UTF8.self)
        guard text.hasPrefix("ZEUS-SIMULATED-MODEL") else { throw TranscriptionError.failed("not a simulated model") }
        multilingual = !text.contains("english-only")
        Thread.sleep(forTimeInterval: 0.3)
    }

    func warmUp() {}

    func tokenCount(_ text: String) -> Int { text.split(whereSeparator: { $0 == " " || $0 == "," }).count + 1 }

    func transcribe(_ samples: [Float], language: String?, prompt: DictationSettings.Prompt, abort: AbortFlag) throws -> String {
        Thread.sleep(forTimeInterval: 0.8)
        if abort.isSet { throw TranscriptionError.cancelled }
        guard !samples.isEmpty else { return "" }
        return "Hello Zeus." + (language.map { " (\($0))" } ?? "") + (prompt.text.isEmpty ? "" : " [\(prompt.text)]")
    }
}
#endif
