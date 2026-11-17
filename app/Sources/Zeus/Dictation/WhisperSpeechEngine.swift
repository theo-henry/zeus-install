import AVFoundation
import Foundation

/// Audio for dictation: 16 kHz mono Float32 samples, with the level of each part (0...1), on the main queue.
protocol DictationAudioSource: AnyObject {
    /// Asks for the microphone when it was never asked for. Calls back on the main queue with an error text, or nil.
    func authorize(completion: @escaping (String?) -> Void)
    func start(onAudio: @escaping ([Float], Float) -> Void) throws
    /// Stops the audio. `drained` comes on the main queue after the last audio part.
    func stop(drained: @escaping () -> Void)
}

/// Whisper dictation (see `DictationRuntime`): it records until Stop, then the loaded model turns the recording into
/// text. There is no text while the user speaks; the page gets the audio level instead, then "processing".
/// A recording stops by itself after 10 minutes.
final class WhisperSpeechEngine: SpeechEngine {
    /// 10 minutes. Debug builds take `ZEUS_APP_TEST_RECORDING_LIMIT` (seconds) instead, for the tests.
    static let recordingLimit: TimeInterval = {
        #if DEBUG
        if let value = DebugEnvironment.value("ZEUS_APP_TEST_RECORDING_LIMIT").flatMap(TimeInterval.init) { return value }
        #endif
        return 600
    }()
    private static let sampleRate = 16000.0

    private let makeSource: () -> DictationAudioSource
    private var generation = 0
    private var onEvent: ((SpeechEngineEvent) -> Void)?
    private var source: DictationAudioSource?
    private var samples: [Float] = []
    private var language: String?
    /// The microphone runs (after the permission question).
    private var listening = false
    /// The audio parts go into the recording: from the start until the source has given its last part after Stop.
    private var capturing = false
    private var stopping = false
    private var abort: AbortFlag?
    private var lastLevel = Date.distantPast
    /// Keeps macOS from slowing the app (App Nap) while the user dictates and Whisper processes, also behind other apps.
    private var activity: NSObjectProtocol?

    init(makeSource: @escaping () -> DictationAudioSource) {
        self.makeSource = makeSource
    }

    /// The languages of the loaded model, with auto-detection first for a multilingual model.
    func languages(completion: @escaping (SpeechLanguages) -> Void) {
        let runtime = DictationRuntime.shared
        let role = runtime.loaded?.role ?? DictationSettings.shared.role
        var languages = DictationSettings.languages(of: DictationModels.shared.model(for: role))
            .map { SpeechLanguages.Language(id: $0.id, name: $0.name) }
        if runtime.multilingual {
            languages.insert(SpeechLanguages.Language(id: "auto", name: "Auto-detect"), at: 0)
        } else {
            languages = languages.filter { $0.id == "en" }
        }
        let setting = DictationSettings.shared.language
        let defaultID = languages.contains { $0.id == setting } ? setting : languages.first?.id ?? "auto"
        DispatchQueue.main.async { completion(SpeechLanguages(locales: languages, defaultID: defaultID)) }
    }

    func start(locale: String?, onEvent: @escaping (SpeechEngineEvent) -> Void) {
        reset()
        generation += 1
        let generation = generation
        self.onEvent = onEvent
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Zeus dictation")
        language = DictationRuntime.shared.language(for: locale == "auto" ? nil : locale)
        let source = makeSource()
        self.source = source
        source.authorize { [weak self] problem in
            guard let self, self.generation == generation, self.onEvent != nil else { return }
            if let problem { self.finish(.failed(.permissionDenied, problem)); return }
            // A stop during the permission question ends the recognition before it listens.
            if self.stopping { self.finish(.ended); return }
            self.listen(source, generation: generation)
        }
    }

    private func listen(_ source: DictationAudioSource, generation: Int) {
        capturing = true
        do {
            try source.start { [weak self] chunk, level in
                guard let self, self.generation == generation, self.capturing else { return }
                self.samples.append(contentsOf: chunk)
                let now = Date()
                if !self.stopping, now.timeIntervalSince(self.lastLevel) >= 0.05 {
                    self.lastLevel = now
                    self.onEvent?(.level(level))
                }
                if Double(self.samples.count) >= Self.recordingLimit * Self.sampleRate { self.endRecording(limit: true) }
            }
        } catch {
            finish(.failed(.unavailable, (error as? TranscriptionError)?.message ?? error.localizedDescription))
            return
        }
        listening = true
        onEvent?(.listening)
    }

    func stop() {
        guard onEvent != nil, !stopping else { return }
        // Before the microphone runs, the recognition ends when the permission question is answered.
        guard listening else { stopping = true; return }
        endRecording(limit: false)
    }

    /// "processing" at once; the transcription starts when the source has given its last audio.
    private func endRecording(limit: Bool) {
        guard !stopping else { return }
        stopping = true
        onEvent?(.processing(limit: limit))
        let generation = generation
        let source = self.source
        self.source = nil
        source?.stop { [weak self] in
            guard let self, self.generation == generation, self.onEvent != nil else { return }
            self.capturing = false
            let recorded = self.samples
            self.samples = []
            let seconds = Double(recorded.count) / Self.sampleRate
            Trace.log("speech: whisper recording \(String(format: "%.1f", seconds)) s" + (limit ? " (10-minute limit)" : ""))
            self.abort = DictationRuntime.shared.transcribe(recorded, language: self.language) { [weak self] result in
                guard let self, self.generation == generation, self.onEvent != nil else { return }
                switch result {
                case let .success(text): self.finish(.final(text))
                case .failure(.cancelled): self.finish(.ended)
                case let .failure(.failed(message)): self.finish(.failed(.failed, "Dictation failed: \(message)"))
                }
            }
        }
    }

    func cancel() {
        generation += 1
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
        abort = nil
        listening = false
        capturing = false
        stopping = false
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

// MARK: - Microphone

/// Converts audio parts of one format to 16 kHz mono Float32. It keeps the resampler state between the parts,
/// so that they join without clicks.
final class DictationConverter {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init?(from format: AVAudioFormat) {
        guard format.channelCount > 0, format.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { return nil }
        converter.downmix = true
        self.converter = converter
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        // .noDataNow (not .endOfStream) keeps the converter ready for the next part.
        converter.convert(to: output, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// The loudness of a part, from -50 dBFS (0) to 0 dBFS (1).
    static func level(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        let decibels = 10 * log10(max(power, 1e-10))
        return min(1, max(0, (decibels + 50) / 50))
    }
}

/// The microphone of this Mac through AVAudioEngine, converted to 16 kHz mono off the audio thread.
final class MicrophoneSource: DictationAudioSource {
    private var audio: AVAudioEngine?
    private let queue = DispatchQueue(label: "io.github.theo-henry.zeus.dictation.audio", qos: .userInitiated)

    func authorize(completion: @escaping (String?) -> Void) {
        let denied = "Zeus has no permission for the microphone. Allow Zeus in System Settings > Privacy & Security > Microphone."
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(nil)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { completion(granted ? nil : denied) } }
        default: completion(denied)
        }
    }

    func start(onAudio: @escaping ([Float], Float) -> Void) throws {
        let audio = AVAudioEngine()
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let converter = DictationConverter(from: format) else {
            throw TranscriptionError.failed("Zeus finds no microphone. Connect a microphone and try again.")
        }
        let queue = queue
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // The tap's buffer is reused: copy it before it leaves this callback.
            guard let copy = Self.copy(buffer) else { return }
            queue.async {
                let chunk = converter.convert(copy)
                guard !chunk.isEmpty else { return }
                let level = DictationConverter.level(chunk)
                DispatchQueue.main.async { onAudio(chunk, level) }
            }
        }
        audio.prepare()
        do {
            try audio.start()
        } catch {
            input.removeTap(onBus: 0)
            throw TranscriptionError.failed("The microphone does not start: \(error.localizedDescription)")
        }
        self.audio = audio
    }

    func stop(drained: @escaping () -> Void) {
        if let audio {
            self.audio = nil
            audio.stop()
            audio.inputNode.removeTap(onBus: 0)
        }
        // The parts that the queue still converts reach the main queue before `drained`.
        queue.async { DispatchQueue.main.async(execute: drained) }
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let samplesPerChannel = buffer.format.isInterleaved ? frames * Int(buffer.format.channelCount) : frames
        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels { destination[channel].update(from: source[channel], count: samplesPerChannel) }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels { destination[channel].update(from: source[channel], count: samplesPerChannel) }
        } else if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<channels { destination[channel].update(from: source[channel], count: samplesPerChannel) }
        } else {
            return nil
        }
        return copy
    }
}

#if DEBUG
/// Audio for the tests, with no microphone and no permission question.
/// `ZEUS_APP_TEST_AUDIO_FILE` plays a sound file at the pace of the clock (also when macOS slows the app's timers), in
/// parts of 1024 frames of its own format through the same conversion as the microphone, then silence;
/// otherwise a simulated voice.
final class TestAudioSource: DictationAudioSource {
    private var timer: Timer?
    private var file: AVAudioFile?
    private var converter: DictationConverter?
    private var started = Date()
    /// 16 kHz samples given so far (silence and the simulated voice).
    private var given = 0
    private var onAudio: (([Float], Float) -> Void)?

    init() {
        if let path = DebugEnvironment.value("ZEUS_APP_TEST_AUDIO_FILE"), !path.isEmpty {
            file = try? AVAudioFile(forReading: URL(fileURLWithPath: path))
            converter = file.flatMap { DictationConverter(from: $0.processingFormat) }
            Trace.log("speech: test audio \(path) format=\(file.map { "\($0.processingFormat)" } ?? "unreadable")")
        }
    }

    func authorize(completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async { completion(nil) }
    }

    func start(onAudio: @escaping ([Float], Float) -> Void) throws {
        self.onAudio = onAudio
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.deliver() }
    }

    func stop(drained: @escaping () -> Void) {
        deliver()
        timer?.invalidate()
        timer = nil
        onAudio = nil
        DispatchQueue.main.async(execute: drained)
    }

    /// Gives the audio of the time since the start that is not given yet.
    private func deliver() {
        guard let onAudio else { return }
        let elapsed = Date().timeIntervalSince(started)
        var part: [Float] = []
        if let file, let converter {
            let due = AVAudioFramePosition(elapsed * file.processingFormat.sampleRate)
            while file.framePosition < min(due, file.length) {
                let count = AVAudioFrameCount(min(1024, min(due, file.length) - file.framePosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
                      (try? file.read(into: buffer, frameCount: count)) != nil, buffer.frameLength > 0,
                      let copy = MicrophoneSource.copy(buffer) else { break }
                part += converter.convert(copy)
            }
            // After the file: silence.
            let fileSeconds = Double(file.length) / file.processingFormat.sampleRate
            let silence = Int(max(0, elapsed - fileSeconds) * 16000) - given
            if silence > 0 {
                part += [Float](repeating: 0, count: silence)
                given += silence
            }
        } else {
            let due = Int(elapsed * 16000) - given
            if due > 0 {
                part = (0..<due).map { Float(sin(Double(given + $0) / 8)) * 0.2 }
                given += due
            }
        }
        if !part.isEmpty { onAudio(part, DictationConverter.level(part)) }
    }
}
#endif
