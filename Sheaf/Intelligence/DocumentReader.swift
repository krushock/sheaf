import CoreGraphics
import Foundation
import FoundationModels
import NaturalLanguage
import OSLog
import Security

/// The text of one page of a document.
nonisolated struct PageText: Sendable, Equatable {
    var pageIndex: Int
    var text: String
}

/// A stretch of a page, a few paragraphs long: the unit that is handed to the model.
nonisolated struct Passage: Sendable, Equatable {
    var pageIndex: Int
    var text: String
}

/// The two ways a document is summed up, as in Writing Tools.
nonisolated enum SummaryKind: String, Sendable, CaseIterable, Identifiable {
    case summary, keyPoints

    var id: Self { self }
}

/// How far a summary has come.
nonisolated enum ReadingStep: Sendable, Equatable {
    /// A long document is read a part at a time before anything is written.
    case reading(part: Int, of: Int)
    /// What is written so far.
    case writing(String)
}

/// Which of the system's models reads the document.
nonisolated enum ReadingEngine: String, Sendable, CaseIterable, Identifiable {
    /// The model on this Mac. Nothing leaves the Mac.
    case device
    /// Apple's larger model on Private Cloud Compute. The text goes to Apple's servers,
    /// which are built not to keep it or show it to anyone, Apple included. It takes in
    /// four times as much at once and reasons better, and macOS limits how much it is used.
    case cloud

    var id: Self { self }
}

/// What was made of a document, and by which model.
nonisolated struct Reading: Sendable, Equatable {
    var text: String
    var engine: ReadingEngine
    /// Why the model on this Mac was used although the other was asked for, if so.
    var note: String?
}

/// What a document says in answer to a question.
nonisolated struct DocumentAnswer: Sendable, Equatable {
    var text: String
    /// The pages the answer comes from, counted from zero.
    var pageIndexes: [Int]
    var engine = ReadingEngine.device
    /// Why the model on this Mac was used although the other was asked for, if so.
    var note: String?
}

/// A title, a subject and keywords for a document's properties.
@Generable
nonisolated struct SuggestedInfo: Sendable, Equatable {
    @Guide(description: "A title for the document, at most ten words, without quotation marks")
    var title: String
    @Guide(description: "What the document is about, in one sentence")
    var subject: String
    @Guide(description: "Keywords someone would search for to find this document", .count(3...6))
    var keywords: [String]
}

@Generable
nonisolated struct GeneratedSearchTerms {
    @Guide(description: "Words or short phrases likely to appear in the passage that answers the question", .count(3...8))
    var terms: [String]
}

nonisolated enum ReaderError: LocalizedError {
    case noText
    case unavailable(String)
    case nothingWritten

    var errorDescription: String? {
        switch self {
        case .noText: String(localized: "There is no text to read here. A scanned page has to have its text recognized first.")
        case .unavailable(let reason): reason
        case .nothingWritten: String(localized: "Apple Intelligence could not work with this text.")
        }
    }
}

/// Reads documents with the language model that is part of macOS: sums them up, answers
/// questions about them, suggests what to call them. Everything runs on this Mac.
///
/// The model takes in a few pages at a time, so a long document is read in parts:
/// notes are taken on each part and the summary is written from the notes, and a
/// question is answered from the passages that have most to do with it.
nonisolated enum DocumentReader {
    private static let logger = Logger(subsystem: "com.valeryburtsev.Sheaf", category: "intelligence")

    // MARK: Availability

    /// Why the model cannot be used right now, in words for the person, or nil when it can.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): String(localized: "This Mac does not support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled): String(localized: "Turn on Apple Intelligence in System Settings to use this.")
        case .unavailable(.modelNotReady): String(localized: "Apple Intelligence is still getting ready on this Mac. Try again in a while.")
        case .unavailable: String(localized: "Apple Intelligence is not available right now.")
        }
    }

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// The entitlement Apple grants an app, on request, to use Private Cloud Compute.
    static let cloudEntitlement = "com.apple.developer.private-cloud-compute"

    /// Whether this copy of the app is allowed to use Private Cloud Compute. Without the
    /// entitlement macOS refuses the request, and in a development build the framework
    /// stops the app outright, so nothing is sent unless this is true.
    static let isCloudPermitted: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, cloudEntitlement as CFString, nil) as? Bool == true
    }()

    /// Whether Private Cloud Compute can be used by this app on this Mac right now.
    static var isCloudAvailable: Bool {
        guard isCloudPermitted else { return false }
        if #available(macOS 27.0, *) { return isAvailable && PrivateCloudComputeLanguageModel().isAvailable }
        return false
    }

    /// Whether macOS says the allowance for Private Cloud Compute is used up, and until when.
    static var cloudLimit: (isReached: Bool, isNear: Bool, resets: Date?) {
        guard isCloudPermitted, #available(macOS 27.0, *) else { return (false, false, nil) }
        let usage = PrivateCloudComputeLanguageModel().quotaUsage
        var isNear = false
        if case .belowLimit(let state) = usage.status { isNear = state.isApproachingLimit }
        return (usage.isLimitReached, isNear, usage.resetDate)
    }

    /// The model in use for one request, and how much it takes.
    struct Reader: Sendable {
        let engine: ReadingEngine
        /// The model on this Mac, set to work on what a document says without judging
        /// it: a contract about a crime or a medical report is summed up like anything else.
        let device = SystemLanguageModel(guardrails: .permissiveContentTransformations)

        func session(_ instructions: String) -> LanguageModelSession {
            if engine == .cloud, #available(macOS 27.0, *) {
                return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: instructions)
            }
            return LanguageModelSession(model: device, instructions: instructions)
        }

        /// How many tokens a request and its answer may come to.
        func contextSize() async -> Int {
            if engine == .cloud, #available(macOS 27.0, *) {
                return (try? await PrivateCloudComputeLanguageModel().contextSize) ?? 32768
            }
            return device.contextSize
        }

        /// The most tokens of a document to hand over at once: what fits, less room for
        /// the instructions and the reply, and no more than keeps one request reasonably quick.
        func inputTokens(context: Int) -> Int {
            engine == .cloud ? min(context - 3000, 24000) : min(context - 1400, 5000)
        }
    }

    private static func reader(_ engine: ReadingEngine) throws -> Reader {
        if let reason = unavailableReason { throw ReaderError.unavailable(reason) }
        return Reader(engine: engine == .cloud && isCloudAvailable ? .cloud : .device)
    }

    /// What to tell the person when Private Cloud Compute was asked for and the model on
    /// this Mac did the work instead.
    private static func cloudFailureNote(_ error: Error) -> String {
        logger.error("Private Cloud Compute failed: \(String(reflecting: error), privacy: .public)")
        if #available(macOS 27.0, *), let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .quotaLimitReached(let limit):
                if let date = limit.resetDate {
                    return String(localized: "Private Cloud Compute has reached its limit until \(date.formatted(date: .abbreviated, time: .shortened)), so this was made on this Mac.")
                }
                return String(localized: "Private Cloud Compute has reached its limit for now, so this was made on this Mac.")
            case .networkFailure:
                return String(localized: "Private Cloud Compute could not be reached, so this was made on this Mac.")
            default:
                break
            }
        }
        return String(localized: "Private Cloud Compute could not do this, so it was made on this Mac.")
    }

    /// Whether to try again on this Mac after Private Cloud Compute failed: yes, unless
    /// the person stopped it or there is nothing to read.
    private static func fallsBack(after error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return false }
        if let error = error as? ReaderError, case .noText = error { return false }
        return true
    }

    // MARK: Splitting

    /// Cuts pages into passages of at most `limit` characters, at paragraph ends where
    /// there are any, else at sentence ends, else wherever the limit falls.
    static func passages(of pages: [PageText], limit: Int) -> [Passage] {
        var result: [Passage] = []
        for page in pages {
            var current = ""
            func flush() {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(Passage(pageIndex: page.pageIndex, text: trimmed)) }
                current = ""
            }
            for paragraph in page.text.split(whereSeparator: \.isNewline) {
                for piece in pieces(of: String(paragraph), limit: limit) {
                    if !current.isEmpty, current.count + piece.count + 1 > limit { flush() }
                    current += current.isEmpty ? piece : "\n" + piece
                }
            }
            flush()
        }
        return result
    }

    /// A paragraph as it is when it fits, else cut at sentence ends, else by length.
    private static func pieces(of paragraph: String, limit: Int) -> [String] {
        guard paragraph.count > limit else { return [paragraph] }
        var result: [String] = []
        var current = ""
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph
        tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
            var sentence = String(paragraph[range])
            while sentence.count > limit {
                if !current.isEmpty { result.append(current); current = "" }
                result.append(String(sentence.prefix(limit)))
                sentence = String(sentence.dropFirst(limit))
            }
            if current.count + sentence.count > limit, !current.isEmpty { result.append(current); current = "" }
            current += sentence
            return true
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Runs of passages, each run within a budget of characters.
    static func groups(of passages: [Passage], budget: Int) -> [[Passage]] {
        var result: [[Passage]] = []
        var current: [Passage] = []
        var count = 0
        for passage in passages {
            if !current.isEmpty, count + passage.text.count + 1 > budget {
                result.append(current)
                current = []
                count = 0
            }
            current.append(passage)
            count += passage.text.count + 1
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: Measuring

    /// How much text fits: the model counts in tokens, which are a few characters each
    /// in English and about one each in Chinese. The ratio is taken from the document.
    struct Measure: Sendable {
        var charactersPerToken: Double
        var contextSize: Int
        var inputTokens: Int

        init(reader: Reader, sample: String) async {
            contextSize = await reader.contextSize()
            inputTokens = reader.inputTokens(context: contextSize)
            let sample = String(sample.prefix(3000))
            var counted: Int?
            // Counted by the model on this Mac for either: the two cut text up much alike.
            if #available(macOS 26.4, *) { counted = try? await reader.device.tokenCount(for: sample) }
            if let counted, counted > 0, sample.count > 200 {
                charactersPerToken = Double(sample.count) / Double(counted)
            } else {
                // Without a count: letters of alphabets run about three to a token, others one.
                let wide = sample.unicodeScalars.filter { $0.value >= 0x2E80 }.count
                charactersPerToken = Double(sample.unicodeScalars.count) > 0 && Double(wide) / Double(sample.unicodeScalars.count) > 0.3 ? 1 : 3
            }
        }

        /// The characters that fit in a number of tokens, with a margin.
        func characters(forTokens tokens: Int) -> Int {
            max(Int(Double(tokens) * charactersPerToken * 0.85), 400)
        }

        /// Characters of a document that can go into one request, leaving room for the
        /// instructions and for what is written back.
        var inputBudget: Int { characters(forTokens: inputTokens) }
    }

    /// The language most of a text is in, by its English name, for the instructions.
    static func languageName(of text: String) -> String? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: String(text.prefix(4000))) else { return nil }
        return Locale(identifier: "en_US").localizedString(forLanguageCode: language.rawValue)
    }

    private static func isContextOverflow(_ error: Error) -> Bool {
        if #available(macOS 27.0, *), let error = error as? LanguageModelError, case .contextSizeExceeded = error { return true }
        if let error = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = error { return true }
        return false
    }

    // MARK: Summaries

    /// Sums up pages of a document, reporting how far it has come.
    ///
    /// - Parameter engine: The model asked for. When Private Cloud Compute fails, the
    ///   model on this Mac does the work, and the result says so.
    @concurrent static func summarize(_ pages: [PageText], as kind: SummaryKind, using engine: ReadingEngine = .device, update: @escaping @Sendable (ReadingStep) -> Void) async throws -> Reading {
        let reader = try reader(engine)
        do {
            return Reading(text: try await summarize(pages, as: kind, reader: reader, update: update), engine: reader.engine)
        } catch where reader.engine == .cloud && fallsBack(after: error) {
            let note = cloudFailureNote(error)
            let text = try await summarize(pages, as: kind, reader: Reader(engine: .device), update: update)
            return Reading(text: text, engine: .device, note: note)
        }
    }

    private static func summarize(_ pages: [PageText], as kind: SummaryKind, reader: Reader, update: @escaping @Sendable (ReadingStep) -> Void) async throws -> String {
        let whole = pages.map(\.text).joined(separator: "\n")
        guard whole.contains(where: \.isLetter) else { throw ReaderError.noText }
        let measure = await Measure(reader: reader, sample: whole)
        let budget = measure.inputBudget
        let language = languageName(of: whole) ?? "the language of the text"
        let groups = groups(of: passages(of: pages, limit: min(1200, budget)), budget: budget)

        if groups.count == 1 {
            let text = groups[0].map(\.text).joined(separator: "\n")
            do {
                return try await write(kind, from: "The text:\n\n" + text, isShort: text.count < 1500, language: language, reader: reader, update: update)
            } catch where isContextOverflow(error) && budget > 1200 {
                // The measure was off: read it in parts after all.
                let halves = self.groups(of: passages(of: pages, limit: 600), budget: budget / 2)
                return try await summarize(parts: halves, as: kind, language: language, reader: reader, budget: budget / 2, update: update)
            }
        }
        return try await summarize(parts: groups, as: kind, language: language, reader: reader, budget: budget, update: update)
    }

    /// Takes notes on each part, then writes the summary from the notes.
    private static func summarize(parts: [[Passage]], as kind: SummaryKind, language: String, reader: Reader, budget: Int, update: @escaping @Sendable (ReadingStep) -> Void) async throws -> String {
        var notes: [String] = []
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            update(.reading(part: index + 1, of: parts.count))
            let text = part.map(\.text).joined(separator: "\n")
            if let note = try await note(on: text, part: index + 1, of: parts.count, language: language, reader: reader) {
                notes.append(note)
            }
        }
        guard !notes.isEmpty else { throw ReaderError.nothingWritten }
        // Notes on a very long document are themselves too long: they are condensed, a
        // run at a time, until they fit.
        var rounds = 0
        while notes.joined(separator: "\n\n").count > budget, notes.count > 1, rounds < 4 {
            rounds += 1
            let runs = groups(of: notes.map { Passage(pageIndex: 0, text: $0) }, budget: budget)
            guard runs.count < notes.count else { break }
            var condensed: [String] = []
            for (index, run) in runs.enumerated() {
                try Task.checkCancellation()
                update(.reading(part: index + 1, of: runs.count))
                if let note = try await note(on: run.map(\.text).joined(separator: "\n\n"), part: index + 1, of: runs.count, language: language, reader: reader, condensing: true) {
                    condensed.append(note)
                }
            }
            guard !condensed.isEmpty else { break }
            notes = condensed
        }
        var source = "Notes on the consecutive parts of one long document, in order:\n\n" + notes.joined(separator: "\n\n")
        if source.count > budget { source = String(source.prefix(budget)) }
        source += "\n\nFrom these notes, say what kind of document this is, what it covers and its main points. Leave out lists of names, options and other detail from single parts."
        return try await write(kind, from: source, isShort: false, language: language, reader: reader, update: update)
    }

    /// Notes on one part of a document. Nil when the model will not work with the part,
    /// so that one such part does not cost the whole summary.
    ///
    /// - Parameter condensing: The text is notes taken earlier, to be made shorter still.
    private static func note(on text: String, part: Int, of count: Int, language: String, reader: Reader, condensing: Bool = false, depth: Int = 0) async throws -> String? {
        let session = reader.session(condensing ? """
            You are given notes on consecutive parts of one long document. Write them up shorter, so that the whole document can be summarized later: \
            what these parts are about and the few things in them that matter for the document as a whole. Leave out lists of names, options and other detail. \
            Use only what the notes say. Write at most six plain sentences in \(language). No headings, no lists, no preamble.
            """ : """
            You take notes on one part of a longer document, so that the whole document can be summarized from the notes later. \
            Say what this part is about, then what matters most in it: the people and organizations it concerns, and its main facts, figures, dates, decisions and conclusions. \
            Leave out long lists of names, options and other detail. \
            Use only what the text says. Write at most \(reader.engine == .cloud ? "ten" : "five") plain sentences in \(language). No headings, no lists, no preamble.
            """)
        do {
            let response = try await session.respond(to: "Part \(part) of \(count):\n\n\(text)", options: GenerationOptions(temperature: 0.2, maximumResponseTokens: reader.engine == .cloud ? 700 : 320))
            let note = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return note.isEmpty ? nil : note
        } catch is CancellationError {
            throw CancellationError()
        } catch where isContextOverflow(error) && depth < 3 && text.count > 400 {
            // Denser than measured: take the part in two halves.
            let middle = text.index(text.startIndex, offsetBy: text.count / 2)
            let first = try await note(on: String(text[..<middle]), part: part, of: count, language: language, reader: reader, condensing: condensing, depth: depth + 1)
            let second = try await note(on: String(text[middle...]), part: part, of: count, language: language, reader: reader, condensing: condensing, depth: depth + 1)
            let both = [first, second].compactMap(\.self).joined(separator: " ")
            return both.isEmpty ? nil : both
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return nil
        }
    }

    /// Writes the summary itself, handing over what is written as it comes.
    private static func write(_ kind: SummaryKind, from source: String, isShort: Bool, language: String, reader: Reader, update: @escaping @Sendable (ReadingStep) -> Void) async throws -> String {
        let instructions = switch kind {
        case .summary:
            """
            You summarize documents. Say what the document is and what it says: who it concerns, and the facts, figures, dates, obligations and conclusions that matter most. \
            Use only what the text says. Add no opinions and no advice. \
            Write \(isShort ? "two or three sentences" : "at most 150 words, in one to three short paragraphs,") in \(language), as plain prose. Do not go through the text part by part: say what matters about the whole. No headings, no lists, and no preamble such as "Here is a summary".
            """
        case .keyPoints:
            """
            You list the key points of documents. Give between three and eight points, the most important first. \
            Each point is one short sentence on a line of its own, beginning with a dash. No quotation marks around the points. \
            Use only what the text says. Add no opinions and no advice. Write in \(language). No headings and no preamble.
            """
        }
        let session = reader.session(instructions)
        var written = ""
        update(.writing(""))
        for try await snapshot in session.streamResponse(to: source, options: GenerationOptions(temperature: 0.3, maximumResponseTokens: kind == .summary ? 420 : 500)) {
            try Task.checkCancellation()
            written = snapshot.content
            update(.writing(written))
        }
        written = tidied(written, as: kind)
        // Cut off by the limit on its length, a summary ends at its last whole sentence.
        if kind == .summary, let last = written.last, !".!?。！？»”\")".contains(last),
           let end = written.lastIndex(where: { ".!?。！？".contains($0) }), written.distance(from: written.startIndex, to: end) > written.count / 2 {
            written = String(written[...end])
        }
        guard !written.isEmpty else { throw ReaderError.nothingWritten }
        return written
    }

    /// The model's text without the marks of formatting it sometimes adds.
    static func tidied(_ text: String, as kind: SummaryKind) -> String {
        var lines = text.replacingOccurrences(of: "**", with: "").split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if kind == .keyPoints {
            lines = lines.filter { !$0.isEmpty }.map { line in
                var line = line
                // Whatever the model began the line with: a dash, a bullet, a number.
                while let first = line.first, "-•*–—·0123456789.) \u{00A0}\"“".contains(first) { line.removeFirst() }
                if line.hasSuffix("\"") || line.hasSuffix("”") { line.removeLast() }
                return "• " + line
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Questions

    /// A document cut up for looking things up in: its passages, and which words are in which.
    struct Index: Sendable {
        let passages: [Passage]
        private let terms: [[String: Int]]
        private let lengths: [Int]
        private let documentFrequency: [String: Int]
        let language: String?

        init(pages: [PageText]) {
            passages = DocumentReader.passages(of: pages, limit: 1100)
            terms = passages.map { passage in
                DocumentReader.terms(in: passage.text).reduce(into: [:]) { $0[$1, default: 0] += 1 }
            }
            lengths = terms.map { $0.values.reduce(0, +) }
            documentFrequency = terms.reduce(into: [:]) { counts, passage in
                for term in passage.keys { counts[term, default: 0] += 1 }
            }
            language = DocumentReader.languageName(of: passages.prefix(6).map(\.text).joined(separator: "\n"))
        }

        var isEmpty: Bool { passages.isEmpty }
        var characterCount: Int { passages.reduce(0) { $0 + $1.text.count } }

        /// How well each passage matches a query, by the usual measure (BM25): words that
        /// are rare in the document count for more, long passages for less. Each word of
        /// the query has a weight, and a passage that has one of the `literals` in it,
        /// letter for letter, is put well ahead.
        func scores(for query: Query) -> [Double] {
            let average = Double(max(lengths.reduce(0, +), 1)) / Double(max(passages.count, 1))
            let count = Double(passages.count)
            let literals = query.literals.map { $0.lowercased() }
            return terms.indices.map { index in
                var score = 0.0
                for (term, importance) in query.terms {
                    guard let frequency = terms[index][term], let found = documentFrequency[term] else { continue }
                    let rarity = log(1 + (count - Double(found) + 0.5) / (Double(found) + 0.5))
                    let weight = Double(frequency) * 2.2 / (Double(frequency) + 1.2 * (0.25 + 0.75 * Double(lengths[index]) / average))
                    score += rarity * weight * importance
                }
                if !literals.isEmpty {
                    let text = " " + passages[index].text.lowercased().replacingOccurrences(of: "\n", with: " ")
                    for literal in literals where text.contains(" " + literal) { score += 4 }
                }
                return score
            }
        }

        /// The passages to answer from, in the order of the document: all of them when
        /// they fit, else the ones that match best.
        func passages(matching scores: [Double], budget: Int) -> [Passage] {
            if characterCount + passages.count * 12 <= budget { return passages }
            // How a document opens says what it is and whose, which no question's words find.
            var chosen: Set<Int> = [0]
            var used = passages[0].text.count + 12
            let ranked = passages.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
            for (place, index) in ranked.enumerated() {
                // What follows the best matches comes along: an answer often runs on.
                for candidate in place < 4 ? [index, index + 1] : [index] where candidate < passages.count && !chosen.contains(candidate) {
                    let cost = passages[candidate].text.count + 12
                    if used + cost > budget { continue }
                    chosen.insert(candidate)
                    used += cost
                }
                if used > budget - 200 { break }
            }
            return chosen.sorted().map { passages[$0] }
        }
    }

    /// What to look for in a document: words, each with how much it counts, and strings
    /// to find letter for letter.
    struct Query: Sendable {
        var terms: [String: Double] = [:]
        var literals: [String] = []

        mutating func add(_ words: [String], weight: Double) {
            for word in words { terms[word] = max(terms[word] ?? 0, weight) }
        }
    }

    /// The query a question makes. The words that name things count in full, verbs for
    /// less, and the small words of the language ("how", "the", "of") not at all, since
    /// in a manual or a contract those are rare enough to look important. Things written
    /// with signs or digits ("-e", "$PATH", "2B", "12/2026") are looked for as they stand.
    static func query(for question: String, weight: Double = 1) -> Query {
        var query = Query()
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = question
        tagger.enumerateTags(in: question.startIndex..<question.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let importance: Double = switch tag {
            case .noun?, .adjective?, .number?, .otherWord?, nil: 1
            case .verb?: 0.35
            default: 0
            }
            if importance > 0 { query.add(terms(in: String(question[range])), weight: importance * weight) }
            return true
        }
        for word in question.split(whereSeparator: \.isWhitespace) {
            let word = word.trimmingCharacters(in: CharacterSet(charactersIn: "?!.,;:\"“”«»()"))
            guard word.count >= 2 else { continue }
            let letters = word.filter(\.isLetter).count
            if word.contains("-"), letters == word.count - word.filter({ $0 == "-" }).count, letters >= 4 {
                // "read-only" is also written "readonly".
                query.add(terms(in: word.replacingOccurrences(of: "-", with: "")), weight: weight)
            } else if letters < word.count, weight >= 1 {
                query.literals.append(word)
            }
        }
        return query
    }

    /// Cuts a document up for looking things up in, off the main thread.
    @concurrent static func index(of pages: [PageText]) async -> Index {
        Index(pages: pages)
    }

    /// The words of a text as they are compared: lowercased, without accents, and long
    /// words cut to their first letters so that endings do not matter.
    static func terms(in text: String) -> [String] {
        var result: [String] = []
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = folded
        tokenizer.enumerateTokens(in: folded.startIndex..<folded.endIndex) { range, _ in
            let word = folded[range]
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else { return true }
            if word.count == 1, word.unicodeScalars.allSatisfy({ $0.value < 0x2E80 }) { return true }
            result.append(word.count > 7 ? String(word.prefix(6)) : String(word))
            return true
        }
        return result
    }

    /// The passages as the model is shown them, each under its page number.
    static func excerpts(_ passages: [Passage]) -> String {
        var result = ""
        var lastPage: Int?
        for passage in passages {
            if passage.pageIndex != lastPage {
                if !result.isEmpty { result += "\n\n" }
                result += "[Page \(passage.pageIndex + 1)]\n"
                lastPage = passage.pageIndex
            } else {
                result += "\n"
            }
            result += passage.text
        }
        return result
    }

    /// Answers a question from a document, handing over the answer as it is written.
    ///
    /// - Parameter earlier: The last questions and answers, so that "and when?" is understood.
    @concurrent static func answer(_ question: String, from index: Index, earlier: [(question: String, answer: String)] = [], using engine: ReadingEngine = .device, update: @escaping @Sendable (String) -> Void) async throws -> DocumentAnswer {
        let reader = try reader(engine)
        do {
            return try await answer(question, from: index, earlier: earlier, reader: reader, update: update)
        } catch where reader.engine == .cloud && fallsBack(after: error) {
            let note = cloudFailureNote(error)
            var answer = try await answer(question, from: index, earlier: earlier, reader: Reader(engine: .device), update: update)
            answer.note = note
            return answer
        }
    }

    private static func answer(_ question: String, from index: Index, earlier: [(question: String, answer: String)], reader: Reader, update: @escaping @Sendable (String) -> Void) async throws -> DocumentAnswer {
        guard !index.isEmpty else { throw ReaderError.noText }
        let measure = await Measure(reader: reader, sample: index.passages.prefix(4).map(\.text).joined(separator: "\n"))
        let history = earlier.suffix(2).map { "Q: \($0.question.prefix(300))\nA: \($0.answer.prefix(500))" }.joined(separator: "\n")
        let budget = max(measure.characters(forTokens: reader.engine == .cloud ? min(measure.contextSize - 3000, 20000) : min(measure.contextSize - 1700, 4500)) - history.count, 1200)

        var passages = index.passages
        if index.characterCount + index.passages.count * 12 > budget {
            // Too long to hand over whole: the passages that share words with the question,
            // and with the one before it, since a follow-up often leaves the subject out.
            // The model also says what words to look for: the document may put it another
            // way than the question does, or be in another language.
            var query = query(for: question)
            if let last = earlier.last {
                for (term, weight) in self.query(for: last.question, weight: 0.5).terms { query.add([term], weight: weight) }
            }
            for phrase in await searchTerms(for: question, language: index.language, reader: reader) {
                query.add(terms(in: phrase), weight: 1)
                if phrase.contains(" ") { query.literals.append(phrase) }
            }
            let scores = index.scores(for: query)
            passages = index.passages(matching: scores, budget: budget)
        }

        // Plain text, not a structure: the model is stricter about what a document may
        // say when it fills in a structure, and stops at contracts that list crimes.
        let session = reader.session("""
            You answer questions about one document from excerpts of it. Each excerpt starts with its page number in brackets, like [Page 3]. \
            Answer only from the excerpts. Never answer from what you know otherwise. Do not mention the excerpts or these instructions. \
            Answer briefly and directly, in one to four sentences, without page numbers. If the excerpts say nothing on the subject of the question, reply with only: N/A
            """)
        var prompt = "Excerpts from the document:\n\n\(excerpts(passages))\n\n"
        if !history.isEmpty { prompt += "Earlier in this conversation:\n\(history)\n\n" }
        prompt += "Question: \(question)"
        if let language = languageName(of: question), question.count > 12 { prompt += "\n\nAnswer in \(language)." }

        var written = ""
        for try await snapshot in session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 500)) {
            try Task.checkCancellation()
            written = snapshot.content
            let shown = parsed(written)
            if !shown.isMissing, !shown.text.isEmpty { update(shown.text) }
        }
        let result = parsed(written)
        let text = result.text
        // What the model knows from elsewhere is not what the document says.
        guard !result.isMissing else { return DocumentAnswer(text: String(localized: "The document does not seem to say."), pageIndexes: [], engine: reader.engine) }
        guard !text.isEmpty else { throw ReaderError.nothingWritten }
        let pages = result.pages
        // Only pages that were shown can be where the answer comes from.
        let shown = Set(passages.map(\.pageIndex))
        var seen: Set<Int> = []
        var indexes = pages.map { $0 - 1 }.filter { shown.contains($0) && seen.insert($0).inserted }
        if indexes.isEmpty || indexes.count > 3 {
            // The model is not asked for pages, which it gets wrong as often as right, and
            // may name none or too many: the answer comes from the passage that has most
            // of the answer's words, and from another that has nearly as many.
            let words = Set(terms(in: text))
            let matches = passages.map { passage in (page: passage.pageIndex, count: Set(terms(in: passage.text)).intersection(words).count) }.sorted { $0.count > $1.count }
            indexes = []
            if let best = matches.first, best.count >= max(2, words.count / 3) {
                indexes = [best.page]
                if let next = matches.dropFirst().first(where: { $0.page != best.page }), next.count * 10 >= best.count * 9 { indexes.append(next.page) }
            }
            indexes.sort()
        }
        return DocumentAnswer(text: text, pageIndexes: indexes, engine: reader.engine)
    }

    /// An answer as the model writes it ("Answer: … Pages: …"), taken apart: the answer
    /// itself, the page numbers, and whether it said the document has no answer. The
    /// model does not always keep to the form, so the labels are looked for wherever
    /// they are. Works on an answer that is still being written, so that they never show.
    static func parsed(_ written: String) -> (text: String, pages: [Int], isMissing: Bool) {
        var pages: [Int] = []
        func numbers(in text: some StringProtocol) -> [Int] {
            text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        var kept: [String] = []
        let lines = written.replacingOccurrences(of: "**", with: "").split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() {
            var line = line
            let lowered = line.lowercased()
            if lowered.hasPrefix("found:") { continue }
            if lowered.hasPrefix("pages:") || lowered.hasPrefix("page:") {
                pages += numbers(in: line)
                continue
            }
            // The last line while its label is still being written.
            if index == lines.count - 1, lines.count > 1, !line.isEmpty, "pages:".hasPrefix(lowered) { continue }
            if lowered.hasPrefix("answer:") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            // Pages named at the end of the line, or in brackets within it.
            if let label = line.range(of: "pages:", options: [.caseInsensitive, .backwards]) {
                pages += numbers(in: line[label.upperBound...])
                line = String(line[..<label.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            while let open = line.range(of: "[Page", options: .caseInsensitive) ?? line.range(of: "(Page", options: .caseInsensitive),
                  let close = line[open.upperBound...].firstIndex(where: { $0 == "]" || $0 == ")" }) {
                pages += numbers(in: line[open.upperBound..<close])
                line.removeSubrange(open.lowerBound...close)
            }
            kept.append(line.replacingOccurrences(of: "  ", with: " ").replacingOccurrences(of: " .", with: "."))
        }
        var text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Some answers end by saying, against themselves, that nothing was found.
        for ending in ["NOT FOUND.", "NOT FOUND", "N/A.", "N/A"] where text.count > ending.count + 20 && text.uppercased().hasSuffix(ending) {
            text = String(text.dropLast(ending.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let isMissing = text.uppercased().hasPrefix("NOT FOUND") || text.uppercased().hasPrefix("N/A")
        return (isMissing ? "" : text, pages, isMissing)
    }

    /// Words to look for in a document to answer a question, in the document's language.
    private static func searchTerms(for question: String, language: String?, reader: Reader) async -> [String] {
        let session = reader.session("You help search a document\(language.map { " written in \($0)" } ?? ""). Given a question about it, you list the exact words or short phrases\(language.map { " in \($0)" } ?? "") that the passage answering the question is likely to contain: the names of the things asked about, technical terms, synonyms. When the question is in another language, give its key words translated\(language.map { " into \($0)" } ?? ""). No question words.")
        let response = try? await session.respond(to: "Question: \(question)", generating: GeneratedSearchTerms.self, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 120))
        return response?.content.terms ?? []
    }

    // MARK: Properties

    /// A title, a subject and keywords, from how a document starts.
    @concurrent static func suggestInfo(for pages: [PageText]) async throws -> SuggestedInfo {
        let whole = pages.map(\.text).joined(separator: "\n")
        guard whole.contains(where: \.isLetter) else { throw ReaderError.noText }
        let reader = try reader(.device)
        let measure = await Measure(reader: reader, sample: whole)
        let language = languageName(of: whole) ?? "the language of the document"
        let start = String(whole.prefix(min(measure.inputBudget, 6000)))
        // As a structure first; as plain lines when the model will not fill one in for
        // this document (it is stricter about structures).
        let instructions = "You catalogue documents. From the start of a document you suggest a title, a subject and keywords for its properties, in \(language). Use the document's own title when it has one. Use only what the text says."
        var info: SuggestedInfo
        do {
            let session = reader.session(instructions)
            info = try await session.respond(to: "The start of the document:\n\n\(start)", generating: SuggestedInfo.self, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 300)).content
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let session = reader.session(instructions + " Answer in exactly three lines: \"Title: \" and a title of at most ten words; \"Subject: \" and one sentence; \"Keywords: \" and three to six keywords separated by commas.")
            let written = try await session.respond(to: "The start of the document:\n\n\(start)", options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 300)).content
            info = SuggestedInfo(title: "", subject: "", keywords: [])
            for line in written.replacingOccurrences(of: "**", with: "").split(whereSeparator: \.isNewline) {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() {
                case "title": info.title = value
                case "subject": info.subject = value
                case "keywords": info.keywords = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                default: break
                }
            }
            guard !info.title.isEmpty || !info.subject.isEmpty else { throw ReaderError.nothingWritten }
        }
        info.title = info.title.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”«» ").union(.whitespacesAndNewlines))
        info.subject = info.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        info.keywords = info.keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return info
    }

    /// The language to write in when there is no text to go by: the app's, when the model
    /// knows it, else English.
    static var replyLanguage: String {
        let locale = Locale.current
        guard SystemLanguageModel.default.supportsLocale(locale), let code = locale.language.languageCode?.identifier,
              let name = Locale(identifier: "en_US").localizedString(forLanguageCode: code)
        else { return "English" }
        return name
    }

    // MARK: Pictures

    /// Whether the model on this Mac can look at pictures.
    static var canDescribePictures: Bool {
        if #available(macOS 27.0, *) { return isAvailable && SystemLanguageModel.default.capabilities.contains(.vision) }
        return false
    }

    /// What a picture shows, in a sentence or two, for someone who cannot see it.
    @available(macOS 27.0, *)
    @concurrent static func describe(_ image: CGImage, language: String) async throws -> String {
        if let reason = unavailableReason { throw ReaderError.unavailable(reason) }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: "You describe pictures for people who cannot see them: what the picture shows, in one or two plain sentences in \(language). Read out any text in it that matters. No preamble.")
        let response = try await session.respond(options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 200)) {
            "Describe this picture."
            Attachment(image)
        }
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ReaderError.nothingWritten }
        return text
    }
}
