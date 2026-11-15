import Foundation
import whisper

/// The dictation settings of the user, for both chats: the model ("accurate" or "fast"), the language
/// ("auto" or a Whisper language code), and one list of custom words. Kept in the app settings (`Preferences`).
/// All calls are on the main queue.
final class DictationSettings {
    static let shared = DictationSettings()

    /// The most tokens of the custom words that go to the model as its initial prompt.
    static let promptTokenLimit = 100
    static let maxWordLength = 64
    static let maxWords = 200

    var onChange: [() -> Void] = []

    /// The role of the chosen model; the default role of the model list when the user never chose one.
    var role: String {
        if let stored = Preferences.dictationModel, DictationModels.shared.model(for: stored) != nil { return stored }
        return DictationModels.shared.manifest.defaultRole
    }

    /// "auto" or a Whisper language code, as the user chose it (also when the model does not have it).
    var language: String { Preferences.dictationLanguage ?? "auto" }

    var customWords: [String] { Preferences.dictationCustomWords }

    /// Applies the settings of a page; values that are not valid are ignored.
    /// Returns whether a setting changed, and an error text for the values that are not valid.
    func apply(model: String?, language: String?, customWords: [String]?) -> (changed: Bool, error: String?) {
        var problems: [String] = []
        var changed = false
        if let model {
            if DictationModels.shared.model(for: model) != nil {
                if model != role { Preferences.dictationModel = model; changed = true }
            } else {
                problems.append("unknown model \"\(model)\"")
            }
        }
        if let language {
            if language == "auto" || Self.allLanguages.contains(where: { $0.id == language }) {
                if language != self.language { Preferences.dictationLanguage = language; changed = true }
            } else {
                problems.append("unknown language \"\(language)\"")
            }
        }
        if let customWords {
            let clean = Self.clean(customWords)
            if clean != self.customWords { Preferences.dictationCustomWords = clean; changed = true }
        }
        if changed {
            Trace.log("dictation: settings model=\(role) language=\(self.language) words=\(self.customWords.count)")
            onChange.forEach { $0() }
        }
        return (changed, problems.isEmpty ? nil : problems.joined(separator: ", "))
    }

    /// Trimmed, without empty words or repeats (case-insensitive), each at most 64 characters, at most 200 words.
    static func clean(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for word in words {
            let trimmed = String(word.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxWordLength))
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
            if result.count == maxWords { break }
        }
        return result
    }

    // MARK: Languages

    struct Language: Equatable {
        let id: String
        let name: String
    }

    /// The Whisper languages, with names in the language of this Mac.
    static let allLanguages: [Language] = {
        (0...whisper_lang_max_id()).compactMap { id -> Language? in
            guard let code = whisper_lang_str(id).map({ String(cString: $0) }) else { return nil }
            let name = Locale.current.localizedString(forLanguageCode: code)
                ?? whisper_lang_str_full(id).map { String(cString: $0).capitalized } ?? code
            return Language(id: code, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    /// The languages of a model; a model that is not multilingual has no auto-detection.
    static func languages(of model: DictationModel?) -> [Language] {
        guard let model else { return [] }
        if model.multilingual { return allLanguages }
        let codes = Set(model.languages ?? [])
        return allLanguages.filter { codes.contains($0.id) }
    }

    /// The language that the model decodes: nil is auto-detection.
    func effectiveLanguage(for model: DictationModel?) -> String? {
        guard let model else { return nil }
        let available = Self.languages(of: model).map(\.id)
        if model.multilingual { return language == "auto" ? nil : language }
        if available.contains(language) { return language }
        return available.first
    }

    // MARK: Custom words

    struct Prompt: Equatable {
        /// The initial prompt for the model ("" without words).
        let text: String
        /// The words in the prompt, from the start of the list.
        let included: Int
        let tokens: Int
        /// The token count came from a guess, because no model is loaded.
        let estimated: Bool
    }

    /// The initial prompt: as many words as fit in `promptTokenLimit` tokens, in the order of the list.
    /// `count` gives the tokens of a text with the loaded model; nil makes a guess (about 4 characters a token).
    static func prompt(words: [String], count: ((String) -> Int)?) -> Prompt {
        let measure = count ?? { text in Int((Double(text.utf8.count) / 3.5).rounded(.up)) }
        var included = 0
        var text = ""
        var tokens = 0
        for word in words {
            let candidate = included == 0 ? word : text + ", " + word
            let candidateTokens = measure(candidate + ".")
            if candidateTokens > promptTokenLimit { break }
            text = candidate
            tokens = candidateTokens
            included += 1
        }
        return Prompt(text: included == 0 ? "" : text + ".", included: included, tokens: tokens, estimated: count == nil)
    }
}
