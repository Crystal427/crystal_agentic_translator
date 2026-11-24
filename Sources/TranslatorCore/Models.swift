import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var baseURL: String
    public var apiToken: String
    public var controllerModel: String
    public var translatorModel: String
    public var controllerContext: Int
    public var controllerReasoning: String
    public var controllerTemperature: Double
    public var translatorContext: Int
    public var translatorTemperature: Double
    public var modelStrategy: ModelStrategy
    public var maxChunkCharacters: Int
    public var contextCharacters: Int
    public var batchSize: Int
    public var passScore: Int
    public var maxRetries: Int
    public var overviewMaxWindows: Int
    public var pauseAfterOverview: Bool
    public var memoryMaxCharacters: Int
    public var summaryMaxCharacters: Int
    public var sourceLanguage: String
    public var targetLanguage: String
    public var genre: String
    public var extraInstructions: String

    public init(
        baseURL: String = "http://127.0.0.1:1234",
        apiToken: String = "",
        controllerModel: String = "hemmingway-1.5-i1",
        translatorModel: String = "index-translate-9b",
        controllerContext: Int = 32_768,
        controllerReasoning: String = "low",
        controllerTemperature: Double = 0.3,
        translatorContext: Int = 32_768,
        translatorTemperature: Double = 0,
        modelStrategy: ModelStrategy = .swap,
        maxChunkCharacters: Int = 8_192,
        contextCharacters: Int = 512,
        batchSize: Int = 3,
        passScore: Int = 80,
        maxRetries: Int = 2,
        overviewMaxWindows: Int = 3,
        pauseAfterOverview: Bool = false,
        memoryMaxCharacters: Int = 2_048,
        summaryMaxCharacters: Int = 200,
        sourceLanguage: String = "auto",
        targetLanguage: String = "简体中文",
        genre: String = "小说",
        extraInstructions: String = ""
    ) {
        self.baseURL = baseURL
        self.apiToken = apiToken
        self.controllerModel = controllerModel
        self.translatorModel = translatorModel
        self.controllerContext = controllerContext
        self.controllerReasoning = controllerReasoning
        self.controllerTemperature = controllerTemperature
        self.translatorContext = translatorContext
        self.translatorTemperature = translatorTemperature
        self.modelStrategy = modelStrategy
        self.maxChunkCharacters = max(256, maxChunkCharacters)
        self.contextCharacters = max(0, contextCharacters)
        self.batchSize = min(4, max(2, batchSize))
        self.passScore = min(100, max(0, passScore))
        self.maxRetries = max(0, maxRetries)
        self.overviewMaxWindows = max(1, overviewMaxWindows)
        self.pauseAfterOverview = pauseAfterOverview
        self.memoryMaxCharacters = memoryMaxCharacters == 1_024 ? 1_024 : 2_048
        self.summaryMaxCharacters = max(40, summaryMaxCharacters)
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.genre = genre
        self.extraInstructions = extraInstructions
    }
}

public enum ModelStrategy: String, Codable, CaseIterable, Sendable {
    case swap
    case keep
}

public struct CharacterEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var source: String
    public var target: String
    public var gender: String
    public var role: String
    public var voice: String
    public var aliases: [GlossaryAlias]

    public init(id: UUID = UUID(), source: String, target: String, gender: String = "未知", role: String = "", voice: String = "", aliases: [GlossaryAlias] = []) {
        self.id = id
        self.source = source
        self.target = target
        self.gender = gender
        self.role = role
        self.voice = voice
        self.aliases = aliases
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try container.decode(String.self, forKey: .source)
        target = try container.decode(String.self, forKey: .target)
        gender = try container.decodeIfPresent(String.self, forKey: .gender) ?? "未知"
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        voice = try container.decodeIfPresent(String.self, forKey: .voice) ?? ""
        aliases = try container.decodeIfPresent([GlossaryAlias].self, forKey: .aliases) ?? []
    }

    enum CodingKeys: String, CodingKey { case id, source, target, gender, role, voice, aliases }
}

public struct GlossaryAlias: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var source: String
    public var target: String

    public init(id: UUID = UUID(), source: String, target: String) {
        self.id = id
        self.source = source
        self.target = target
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try container.decode(String.self, forKey: .source)
        target = try container.decode(String.self, forKey: .target)
    }

    enum CodingKeys: String, CodingKey { case id, source, target }
}

public struct GlossaryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var source: String
    public var target: String
    public var category: String
    public var note: String

    public init(id: UUID = UUID(), source: String, target: String, category: String = "其他", note: String = "") {
        self.id = id
        self.source = source
        self.target = target
        self.category = category
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try container.decode(String.self, forKey: .source)
        target = try container.decode(String.self, forKey: .target)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "其他"
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    enum CodingKeys: String, CodingKey { case id, source, target, category, note }
}

public struct TranslationStyle: Codable, Equatable, Sendable {
    public var narration: String
    public var tone: String
    public var diction: String
    public var dialogue: String
    public var punctuation: String

    public init(narration: String = "", tone: String = "", diction: String = "", dialogue: String = "", punctuation: String = "") {
        self.narration = narration
        self.tone = tone
        self.diction = diction
        self.dialogue = dialogue
        self.punctuation = punctuation
    }
}

public struct TranslationGuide: Codable, Equatable, Sendable {
    public var titleZh: String
    public var sourceLanguage: String
    public var genre: String
    public var synopsis: String
    public var style: TranslationStyle
    public var characters: [CharacterEntry]
    public var terms: [GlossaryEntry]
    public var rules: [String]

    public init(titleZh: String = "", sourceLanguage: String = "", genre: String = "", synopsis: String = "", style: TranslationStyle = .init(), characters: [CharacterEntry] = [], terms: [GlossaryEntry] = [], rules: [String] = []) {
        self.titleZh = titleZh
        self.sourceLanguage = sourceLanguage
        self.genre = genre
        self.synopsis = synopsis
        self.style = style
        self.characters = characters
        self.terms = terms
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey {
        case titleZh = "title_zh"
        case sourceLanguage = "source_language"
        case genre, synopsis, style, characters, terms, rules
    }
}

public struct SourceDocument: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var text: String

    public init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }
}

public enum ChunkStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case scouted
    case translating
    case translated
    case reviewing
    case reviewed
    case done
    case flagged
}

public struct ReviewScores: Codable, Equatable, Sendable {
    public var accuracy: Int
    public var completeness: Int
    public var terminology: Int
    public var fluency: Int
    public var style: Int

    public init(accuracy: Int = 0, completeness: Int = 0, terminology: Int = 0, fluency: Int = 0, style: Int = 0) {
        self.accuracy = accuracy
        self.completeness = completeness
        self.terminology = terminology
        self.fluency = fluency
        self.style = style
    }

    public var weighted: Int {
        Int((Double(accuracy) * 0.35 + Double(completeness) * 0.25 + Double(terminology) * 0.15 + Double(fluency) * 0.15 + Double(style) * 0.10) * 10)
    }

    enum CodingKeys: String, CodingKey {
        case accuracy, completeness, terminology, fluency, style
    }
}

public struct ReviewIssue: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var type: String
    public var severity: String
    public var source: String
    public var translation: String
    public var suggestion: String

    public init(id: UUID = UUID(), type: String, severity: String, source: String = "", translation: String = "", suggestion: String = "") {
        self.id = id
        self.type = type
        self.severity = severity
        self.source = source
        self.translation = translation
        self.suggestion = suggestion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try container.decode(String.self, forKey: .type)
        severity = try container.decode(String.self, forKey: .severity)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        translation = try container.decodeIfPresent(String.self, forKey: .translation) ?? ""
        suggestion = try container.decodeIfPresent(String.self, forKey: .suggestion) ?? ""
    }

    enum CodingKeys: String, CodingKey { case id, type, severity, source, translation, suggestion }
}

public struct TranslationReview: Codable, Equatable, Sendable {
    public var scores: ReviewScores
    public var issues: [ReviewIssue]
    public var revisionInstructions: [String]
    public var verdict: String
    public var comment: String
    public var automaticChecks: [QualityFinding]
    public var score: Int
    public var modelReviewed: Bool

    public init(scores: ReviewScores = .init(), issues: [ReviewIssue] = [], revisionInstructions: [String] = [], verdict: String = "revise", comment: String = "", automaticChecks: [QualityFinding] = [], score: Int = 0, modelReviewed: Bool = true) {
        self.scores = scores
        self.issues = issues
        self.revisionInstructions = revisionInstructions
        self.verdict = verdict
        self.comment = comment
        self.automaticChecks = automaticChecks
        self.score = score
        self.modelReviewed = modelReviewed
    }

    enum CodingKeys: String, CodingKey {
        case scores, issues, verdict, comment, score
        case revisionInstructions = "revision_instructions"
        case automaticChecks = "automatic_checks"
        case modelReviewed = "model_reviewed"
    }
}

public struct QualityFinding: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var message: String
    public var hard: Bool
    public var penalty: Int

    public init(id: UUID = UUID(), message: String, hard: Bool = false, penalty: Int = 0) {
        self.id = id
        self.message = message
        self.hard = hard
        self.penalty = penalty
    }
}

public struct TranslationAttempt: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var translation: String
    public var review: TranslationReview?
    public var temperature: Double
    public var finishReason: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), translation: String, review: TranslationReview? = nil, temperature: Double = 0, finishReason: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.translation = translation
        self.review = review
        self.temperature = temperature
        self.finishReason = finishReason
        self.createdAt = createdAt
    }
}

public struct TranslationChunk: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var index: Int
    public var fileIndex: Int
    public var fileName: String
    public var source: String
    public var leadingWhitespace: String
    public var trailingWhitespace: String
    public var previousTail: String
    public var nextHead: String
    public var summary: String
    public var translationNotes: [String]
    public var memoryBefore: String
    public var status: ChunkStatus
    public var attempts: [TranslationAttempt]
    public var explicitRetryPending: Bool?
    public var retryCycleStartIndex: Int?
    public var finalTranslation: String
    public var reviewScore: Int?
    public var needsHumanReview: Bool

    public init(id: UUID = UUID(), index: Int, fileIndex: Int, fileName: String, source: String, leadingWhitespace: String = "", trailingWhitespace: String = "", previousTail: String = "", nextHead: String = "", summary: String = "", translationNotes: [String] = [], memoryBefore: String = "", status: ChunkStatus = .pending, attempts: [TranslationAttempt] = [], explicitRetryPending: Bool? = nil, retryCycleStartIndex: Int? = nil, finalTranslation: String = "", reviewScore: Int? = nil, needsHumanReview: Bool = false) {
        self.id = id
        self.index = index
        self.fileIndex = fileIndex
        self.fileName = fileName
        self.source = source
        self.leadingWhitespace = leadingWhitespace
        self.trailingWhitespace = trailingWhitespace
        self.previousTail = previousTail
        self.nextHead = nextHead
        self.summary = summary
        self.translationNotes = translationNotes
        self.memoryBefore = memoryBefore
        self.status = status
        self.attempts = attempts
        self.explicitRetryPending = explicitRetryPending
        self.retryCycleStartIndex = retryCycleStartIndex
        self.finalTranslation = finalTranslation
        self.reviewScore = reviewScore
        self.needsHumanReview = needsHumanReview
    }

    public var rawText: String { leadingWhitespace + source + trailingWhitespace }
    public var latestAttempt: TranslationAttempt? { attempts.last }
}

public enum JobStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case planning
    case awaitingGuide
    case running
    case paused
    case completed
    case failed
}

public struct MemorySnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var afterChunk: Int
    public var text: String

    public init(id: UUID = UUID(), afterChunk: Int, text: String) {
        self.id = id
        self.afterChunk = afterChunk
        self.text = text
    }
}

public struct TranslationJob: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var series: Bool
    public var status: JobStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date?
    public var sourceFiles: [SourceDocument]
    public var chunks: [TranslationChunk]
    public var guide: TranslationGuide?
    public var memory: String
    public var memoryHistory: [MemorySnapshot]
    public var totalTokens: Int
    public var controllerTokens: Int
    public var translatorTokens: Int
    public var error: String?

    public init(id: UUID = UUID(), name: String, series: Bool, status: JobStatus = .queued, createdAt: Date = .now, updatedAt: Date = .now, startedAt: Date? = nil, sourceFiles: [SourceDocument], chunks: [TranslationChunk], guide: TranslationGuide? = nil, memory: String = "", memoryHistory: [MemorySnapshot] = [], totalTokens: Int = 0, controllerTokens: Int = 0, translatorTokens: Int = 0, error: String? = nil) {
        self.id = id
        self.name = name
        self.series = series
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.sourceFiles = sourceFiles
        self.chunks = chunks
        self.guide = guide
        self.memory = memory
        self.memoryHistory = memoryHistory
        self.totalTokens = totalTokens
        self.controllerTokens = controllerTokens
        self.translatorTokens = translatorTokens
        self.error = error
    }

    public var completedCount: Int { chunks.filter { $0.status == .done || $0.status == .flagged }.count }
    public var averageScore: Int? {
        let values = chunks.compactMap(\.reviewScore)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }
    public var flaggedCount: Int { chunks.filter(\.needsHumanReview).count }

    enum CodingKeys: String, CodingKey {
        case id, name, series, status, createdAt, updatedAt, startedAt, sourceFiles, chunks, guide, memory, memoryHistory, totalTokens, controllerTokens, translatorTokens, error
    }
}

public enum PipelineEvent: Sendable {
    case status(jobID: UUID, message: String)
    case activity(jobID: UUID, role: String, action: String)
    case stream(jobID: UUID, role: String, kind: String, text: String)
    case chunk(jobID: UUID, chunkIndex: Int)
    case log(jobID: UUID, message: String)
}
