import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Mailer's writing help — suggested replies, ghost text that finishes your
/// sentence, and grammar fixes — all on this Mac, nothing sent anywhere.
///
/// The model is the owner's own: Qwen 3.5 4B (4-bit, MLX) that Cued already
/// downloaded into ~/.cache/huggingface, run in-process on the GPU. Apple's
/// on-device model is the fallback when that folder isn't there (owner,
/// 2026-11-12: "don't use Apple model, keep it as a fallback").
///
/// Qwen takes ~3 GB of memory, so it loads on first use and is let go after
/// three idle minutes; Mailer sits in the menu bar all day and should not
/// hold that much for nothing.
actor Writer {

    static let shared = Writer()

    enum Backend: Equatable, Sendable {
        case qwen(URL)
        case apple
        case none

        var title: String {
            switch self {
            case .qwen: "Qwen 3.5 4B on this Mac"
            case .apple: "Apple's on-device model"
            case .none: "No writing model found"
            }
        }
    }

    // MARK: Which model

    /// The first complete Qwen 3.5 / 3 MLX chat model of 4B+ in the Hugging
    /// Face cache, else Apple's model if this Mac has it.
    nonisolated static func backend() -> Backend {
        if let qwen = qwenFolder() { return .qwen(qwen) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability { return .apple }
        #endif
        return .none
    }

    nonisolated static func qwenFolder() -> URL? {
        let hub = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        let repos = ((try? FileManager.default.contentsOfDirectory(atPath: hub.path)) ?? [])
            .filter { $0.lowercased().hasPrefix("models--mlx-community--qwen3") && !$0.lowercased().contains("vl") }
            .sorted { $0.contains("Qwen3.5-4B") && !$1.contains("Qwen3.5-4B") }
        for repo in repos {
            let snapshots = hub.appendingPathComponent(repo).appendingPathComponent("snapshots")
            for snap in (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? [] {
                let dir = snapshots.appendingPathComponent(snap, isDirectory: true)
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                if files.contains("config.json"), files.contains("tokenizer.json"), files.contains(where: { $0.hasSuffix(".safetensors") }) {
                    return dir
                }
            }
        }
        return nil
    }

    // MARK: Suggested replies

    /// Three short replies to the newest message, each with a different
    /// intent, in the owner's plain voice. Empty when nothing fits.
    func replies(to message: Message, myName: String) async -> [String] {
        let system = """
        You suggest quick replies that \(myName) could send back to \(message.senderLabel). \
        The reply is written BY \(myName) TO \(message.senderLabel): if it greets anyone, it greets \(Self.firstName(message.senderLabel)), \
        never \(myName). Write the way a normal person writes to someone they know: \
        short, warm, plain words, contractions. No corporate phrases (no "I hope this finds you well", "kindly", \
        "please be advised", "best regards"). No emojis unless the sender used them.
        Never invent facts: no times, dates, numbers, names, places or promises that are not in the email.
        Reply to what the email actually says. If it's just a greeting or a friendly hello, reply in kind \
        (say hi back, ask how they are or what's up). If it asks for something, give one yes, one short question \
        for a detail, and one "not right now / I'll get back to you". If it shares news, react to it.
        The three replies must say different things. Each reply is 2 to 9 words.
        Output only the three replies, one per line, no numbering, no quotes.
        """
        let user = """
        From: \(message.senderLabel)
        Subject: \(message.subject)

        \(String(Self.newestPart(of: message.bodyText).prefix(1500)))
        """
        guard let raw = await generate(system: system, user: user, maxTokens: 80, temperature: 0.6) else { return [] }
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { Self.clean(String($0)) }
            .filter { !$0.isEmpty && $0.split(separator: " ").count <= 14 }
        // A reply never greets the person sending it (the model mixes up who
        // is who when the email says "Hi Harshit") — unless the sender shares
        // the first name.
        let me = Self.firstName(myName).lowercased()
        let them = Self.firstName(message.senderLabel).lowercased()
        let source = "\(message.subject) \(message.bodyText)"
        let addressed = lines.filter { (me.count < 2 || me == them || !$0.lowercased().contains(me)) && !Self.inventsNumbers($0, source: source) }
        var seen = Set<String>()
        return Array(addressed.filter { seen.insert($0.lowercased()).inserted }.prefix(3))
    }

    // MARK: Ghost text

    /// The next few words of a draft, or nil when the model isn't sure.
    func continuation(of draft: String, replyingTo context: String?) async -> String? {
        let system = """
        You continue an email draft with the next few words the writer would most likely type, in their voice. \
        At most 8 words, ending at a natural break. Never repeat what's already written. Never invent facts, \
        times, numbers or names. If you are not confident, output nothing. Output only the continuation text.
        """
        var user = ""
        if let context, !context.isEmpty { user += "They are replying to:\n\(context.prefix(800))\n\n" }
        user += "Draft so far (continue right after the last character):\n\(draft.suffix(1200))"
        guard var text = await generate(system: system, user: user, maxTokens: 14, temperature: 0.2) else { return nil }
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        // Keep the join natural: no double space, one space after a word.
        if draft.hasSuffix(" ") || draft.hasSuffix("\n") { text = String(text.drop(while: { $0 == " " })) }
        else if let first = text.first, first.isLetter || first.isNumber { text = " " + text }
        // A suggestion may not bring in a time, date or amount that isn't
        // already in the draft or the email (it offered "9:00 AM" once).
        guard !Self.inventsNumbers(text, source: draft + " " + (context ?? "")) else { return nil }
        let words = text.split(separator: " ")
        guard !words.isEmpty, words.count <= 10, !draft.lowercased().hasSuffix(text.lowercased().trimmingCharacters(in: .whitespaces)) else { return nil }
        return text
    }

    // MARK: Grammar

    /// The same sentence with grammar, spelling, capitals and punctuation
    /// fixed, or nil when it's already fine or the model went too far.
    func proofread(_ sentence: String) async -> String? {
        let system = """
        You fix grammar, spelling, capitalization and punctuation. Keep the writer's own words, tone and meaning; \
        do not make it more formal, do not add or remove ideas, do not rephrase what is already correct. \
        If the text is already correct, return it exactly as it is. Output only the corrected text.
        """
        guard let raw = await generate(system: system, user: sentence, maxTokens: max(24, sentence.count / 2), temperature: 0)
        else { return nil }
        let fixed = Self.clean(raw, keepPunctuation: true)
        guard !fixed.isEmpty, fixed != sentence.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // A proofread changes a few letters, not the sentence: refuse rewrites.
        let ratio = Double(fixed.count) / Double(max(1, sentence.count))
        guard ratio > 0.7, ratio < 1.35, fixed.contains("\n") == sentence.contains("\n"),
              !Self.inventsNumbers(fixed, source: sentence) else { return nil }
        return fixed
    }

    // MARK: Running a model

    private var container: ModelContainer?
    private var loading: Task<ModelContainer, Error>?
    private var unloadTask: Task<Void, Never>?

    private func generate(system: String, user: String, maxTokens: Int, temperature: Float) async -> String? {
        let started = Date()
        defer { scheduleUnload() }
        switch Self.backend() {
        case .qwen(let folder):
            do {
                let model = try await qwen(folder)
                let text = try await model.perform { context in
                    let input = try await context.processor.prepare(input: UserInput(messages: [
                        ["role": "system", "content": system],
                        ["role": "user", "content": user]
                    ], additionalContext: ["enable_thinking": false]))
                    let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature, topP: 0.9)
                    var output = ""
                    for await item in try MLXLMCommon.generate(input: input, parameters: parameters, context: context) {
                        if Task.isCancelled { break }
                        if case .chunk(let piece) = item { output += piece }
                    }
                    return output
                }
                Log.write("writer qwen \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                return Self.stripThinking(text)
            } catch {
                Log.error("writer qwen failed; trying Apple's model", error)
                return await apple(system: system, user: user)
            }
        case .apple:
            return await apple(system: system, user: user)
        case .none:
            return nil
        }
    }

    private func qwen(_ folder: URL) async throws -> ModelContainer {
        if let container { return container }
        if let loading { return try await loading.value }
        let task = Task<ModelContainer, Error> {
            // A hard cap keeps MLX's GPU cache from growing on a shared-memory Mac.
            Memory.cacheLimit = 256 * 1024 * 1024
            let t0 = Date()
            let c = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: ModelConfiguration(directory: folder)
            ) { _ in }
            Log.write("writer: Qwen loaded in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            return c
        }
        loading = task
        defer { loading = nil }
        let c = try await task.value
        container = c
        return c
    }

    /// Lets go of the model three minutes after the last use.
    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            guard !Task.isCancelled else { return }
            self.container = nil
            Memory.clearCache()
            Log.write("writer: Qwen unloaded after 3 idle minutes")
        }
    }

    /// Loads the model ahead of need (opening a conversation or Compose), so
    /// the first suggestion doesn't wait for it.
    func warmUp() async {
        guard case .qwen(let folder) = Self.backend() else { return }
        _ = try? await qwen(folder)
        scheduleUnload()
    }

    private func apple(system: String, user: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: system)
            return try? await session.respond(to: user).content
        }
        #endif
        return nil
    }

    // MARK: Text helpers

    /// True when `text` has a number (a time, date, amount) that `source`
    /// doesn't. The model is told never to invent facts; this makes sure.
    static func inventsNumbers(_ text: String, source: String) -> Bool {
        func numbers(_ s: String) -> Set<String> {
            Set(s.split(whereSeparator: { !$0.isNumber }).map(String.init))
        }
        return !numbers(text).isSubset(of: numbers(source))
    }

    static func firstName(_ name: String) -> String {
        name.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." }).first.map(String.init) ?? name
    }

    static func stripThinking(_ s: String) -> String {
        var text = s
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops list markers and wrapping quotes the model sometimes adds.
    static func clean(_ s: String, keepPunctuation: Bool = false) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"^(\d+[\.\)]|[-•*])\s+"#, with: "", options: .regularExpression)
        if t.count > 1, let f = t.first, let l = t.last, "\"“'".contains(f), "\"”'".contains(l) {
            t = String(t.dropFirst().dropLast())
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// The message itself, without the quoted thread below it.
    static func newestPart(of body: String) -> String {
        var kept: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix(">") { break }
            if l.hasPrefix("On "), l.hasSuffix("wrote:") { break }
            if l.hasPrefix("---------- Forwarded message") { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
