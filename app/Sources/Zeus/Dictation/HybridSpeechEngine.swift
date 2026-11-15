import AVFoundation
import Foundation

/// Speech to text for a version 1 page (one that does not start with `version: 2`) while a Whisper model is loaded.
///
/// A version 1 page shows the words while the user speaks, and gives up 4 s after it posts Stop. So Apple's
/// recognizer runs as before (partial text), and Whisper records the same microphone audio at the same time.
/// When the loaded model does not decode the language of the page's locale, Apple does the whole session.
/// At Stop, the Whisper text replaces Apple's text when it is ready within `whisperDeadline`;
/// otherwise (a long recording, an empty or failed Whisper result) the page gets Apple's final text.
/// The page always gets its final text within Apple's own 3 s stop limit.
final class HybridSpeechEngine: SpeechEngine {
    /// The time from Stop that Whisper has for its text. Debug builds take `ZEUS_APP_TEST_V1_DEADLINE` (seconds).
    static let whisperDeadline: TimeInterval = {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["ZEUS_APP_TEST_V1_DEADLINE"].flatMap(TimeInterval.init) { return value }
        #endif
        return 2.8
    }()

    private let apple: SpeechEngine
    private let makeSource: () -> DictationAudioSource
    private var generation = 0
    private var onEvent: ((SpeechEngineEvent) -> Void)?
    private var source: DictationAudioSource?
    private var samples: [Float] = []
    private var capturing = false
    private var language: String?
    /// Whisper records: the loaded model decodes the language of the page's locale.
    private var whisper = false
    private var stopped = false
    /// Whisper has the recording of this session and works on it.
    private var whisperRunning = false
    private var whisperDone = false
    private var deadlinePassed = false
    /// Apple's end event, kept while Whisper still works.
    private var appleEnd: SpeechEngineEvent?
    private var abort: AbortFlag?
    private var deadline: Timer?
    /// The engine of the last final text: "whisper" or "apple".
    private(set) var finalEngine = "apple"

    init(apple: SpeechEngine, makeSource: @escaping () -> DictationAudioSource) {
        self.apple = apple
        self.makeSource = makeSource
    }

    func languages(completion: @escaping (SpeechLanguages) -> Void) {
        apple.languages(completion: completion)
    }

    func start(locale: String?, onEvent: @escaping (SpeechEngineEvent) -> Void) {
        reset()
        generation += 1
        let generation = generation
        self.onEvent = onEvent
        finalEngine = "apple"
        let runtime = DictationRuntime.shared
        language = runtime.language(for: locale)
        whisper = locale.map { runtime.decodes(DictationRuntime.languageCode(of: $0)) } ?? true
        apple.start(locale: locale) { [weak self] event in
            guard let self, self.generation == generation, self.onEvent != nil else { return }
            self.handleApple(event, generation: generation)
        }
    }

    private func handleApple(_ event: SpeechEngineEvent, generation: Int) {
        switch event {
        case .listening:
            if whisper { startCapture(generation: generation) }
            onEvent?(.listening)
        case .partial:
            onEvent?(event)
        case .level, .processing:
            break
        case .final, .failed, .ended:
            if stopped, whisperRunning, !whisperDone, !deadlinePassed {
                appleEnd = event
            } else {
                finish(event)
            }
        }
    }

    private func startCapture(generation: Int) {
        let source = makeSource()
        self.source = source
        source.authorize { [weak self] problem in
            guard let self, self.generation == generation, self.source === source, !self.stopped, problem == nil else { return }
            do {
                try source.start { [weak self] chunk, _ in
                    guard let self, self.generation == generation, self.capturing else { return }
                    if Double(self.samples.count) < WhisperSpeechEngine.recordingLimit * 16000 { self.samples.append(contentsOf: chunk) }
                }
                self.capturing = true
            } catch {
                Trace.log("speech: v1 Whisper capture does not start: \(error.localizedDescription)")
                self.source = nil
            }
        }
    }

    func stop() {
        guard onEvent != nil, !stopped else { return }
        stopped = true
        let generation = generation
        apple.stop()
        guard let source, capturing else {
            source?.stop {}
            self.source = nil
            return
        }
        self.source = nil
        whisperRunning = true
        deadline = Timer.scheduledTimer(withTimeInterval: Self.whisperDeadline, repeats: false) { [weak self] _ in
            guard let self, self.generation == generation, !self.whisperDone else { return }
            self.deadlinePassed = true
            self.abort?.set()
            Trace.log("speech: v1 Whisper text not ready in \(Self.whisperDeadline) s; Apple's text goes")
            if let end = self.appleEnd { self.finish(end) }
        }
        source.stop { [weak self] in
            guard let self, self.generation == generation, self.onEvent != nil else { return }
            self.capturing = false
            let recorded = self.samples
            self.samples = []
            Trace.log("speech: v1 Whisper recording \(String(format: "%.1f", Double(recorded.count) / 16000)) s")
            self.abort = DictationRuntime.shared.transcribe(recorded, language: self.language) { [weak self] result in
                guard let self, self.generation == generation, self.onEvent != nil, !self.deadlinePassed else { return }
                self.whisperDone = true
                if case let .success(text) = result, !text.isEmpty {
                    self.finalEngine = "whisper"
                    self.apple.cancel()
                    self.finish(.final(text))
                } else if let end = self.appleEnd {
                    self.finish(end)
                }
            }
        }
    }

    func cancel() {
        generation += 1
        apple.cancel()
        abort?.set()
        reset()
    }

    private func finish(_ event: SpeechEngineEvent) {
        let onEvent = self.onEvent
        reset()
        onEvent?(event)
    }

    private func reset() {
        onEvent = nil
        source?.stop {}
        source = nil
        samples = []
        capturing = false
        stopped = false
        whisperRunning = false
        whisperDone = false
        deadlinePassed = false
        appleEnd = nil
        abort = nil
        deadline?.invalidate()
        deadline = nil
    }
}

/// Passes the buffers of a microphone tap to a listener; the tap runs on an audio thread.
final class BufferTap: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((AVAudioPCMBuffer) -> Void)?

    func set(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(buffer)
    }
}

/// The audio of Apple's recognizer microphone for Whisper: one microphone for both engines.
final class TapAudioSource: DictationAudioSource {
    private let tap: BufferTap
    private let queue = DispatchQueue(label: "io.github.theo-henry.zeus.dictation.tap", qos: .userInitiated)

    init(tap: BufferTap) { self.tap = tap }

    /// Apple's recognizer already has the microphone.
    func authorize(completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async { completion(nil) }
    }

    func start(onAudio: @escaping ([Float], Float) -> Void) throws {
        var converter: DictationConverter?
        let queue = queue
        tap.set { buffer in
            guard let copy = MicrophoneSource.copy(buffer) else { return }
            queue.async {
                if converter == nil { converter = DictationConverter(from: copy.format) }
                guard let chunk = converter?.convert(copy), !chunk.isEmpty else { return }
                let level = DictationConverter.level(chunk)
                DispatchQueue.main.async { onAudio(chunk, level) }
            }
        }
    }

    func stop(drained: @escaping () -> Void) {
        tap.set(nil)
        queue.async { DispatchQueue.main.async(execute: drained) }
    }
}
