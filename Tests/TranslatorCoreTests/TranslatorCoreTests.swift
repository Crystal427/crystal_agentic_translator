import Foundation
import Network
import XCTest
@testable import TranslatorCore

final class TextProcessingTests: XCTestCase {
    func testNormalizeLineEndingsTrailingWhitespaceAndBlankRuns() {
        let input = "First  \r\n\r\n\r\n\r\n\r\nSecond\t \r"
        XCTAssertEqual(TextProcessor.normalize(input), "First\n\n\n\nSecond\n")
    }

    func testDecodeHonorsUTF8AndUTF16BOMs() throws {
        let utf8 = Data([0xEF, 0xBB, 0xBF]) + Data("日本語".utf8)
        let utf16 = Data([0xFF, 0xFE]) + "中文".data(using: .utf16LittleEndian)!
        XCTAssertEqual(try TextProcessor.decode(utf8), "日本語")
        XCTAssertEqual(try TextProcessor.decode(utf16), "中文")
    }

    func testDecodeSupportsGBKAndShiftJIS() throws {
        let gbk = String.Encoding(rawValue: 0x80000631)
        XCTAssertEqual(try TextProcessor.decode("中文测试".data(using: gbk)!), "中文测试")
        XCTAssertEqual(try TextProcessor.decode("日本語です".data(using: .shiftJIS)!), "日本語です")
    }

    func testFallbackSubchunkReassemblyPreservesWhitespace() {
        let source = String(repeating: "甲", count: 1_300) + " \n\n " + String(repeating: "乙", count: 1_300)
        let whole = TextChunker.makeChunks(fileIndex: 0, fileName: "story.txt", text: source, maxCharacters: 10_000, contextCharacters: 0)[0]
        let parts = TextChunker.makeChunks(fileIndex: 0, fileName: whole.fileName, text: whole.source, maxCharacters: 2_500, contextCharacters: 0)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(parts.map(\.rawText).joined(), whole.source)
        let translations = parts.indices.map { " 译文\($0) \n" }
        let expected = zip(parts, translations).map { part, translation in
            part.leadingWhitespace + translation.trimmingCharacters(in: .whitespacesAndNewlines) + part.trailingWhitespace
        }.joined()
        XCTAssertEqual(TranslationPipeline.reassembleFallbackTranslations(parts: parts, translations: translations), expected)
        XCTAssertTrue(expected.contains("\n\n "))
    }

    func testChunkingIsLosslessAndRespectsConfiguredMaximum() {
        let source = (0..<80).map { "第\($0 + 1)章\n\(String(repeating: "故事。", count: 90))\n\n" }.joined()
        let chunks = TextChunker.makeChunks(fileIndex: 0, fileName: "book.txt", text: source, maxCharacters: 900, contextCharacters: 40)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.rawText).joined(), source)
        XCTAssertTrue(chunks.allSatisfy { $0.rawText.count <= 900 })
        XCTAssertTrue(chunks[0].previousTail.isEmpty)
        XCTAssertFalse(chunks[1].previousTail.isEmpty)
        XCTAssertFalse(chunks[0].nextHead.isEmpty)
    }

    func testChunkingLongUnbrokenLineKeepsAllCharacters() {
        let source = String(repeating: "abc。", count: 700)
        let chunks = TextChunker.makeChunks(fileIndex: 0, fileName: "line.txt", text: source, maxCharacters: 400, contextCharacters: 20)
        XCTAssertEqual(chunks.map(\.rawText).joined(), source)
        XCTAssertTrue(chunks.allSatisfy { $0.rawText.count <= 400 })
    }

    func testTrailingWhitespaceTailDoesNotCreateEmptyOrOversizedChunk() {
        let source = String(repeating: "a", count: 1_000) + "\n"
        let chunks = TextChunker.makeChunks(fileIndex: 0, fileName: "tail.txt", text: source, maxCharacters: 900, contextCharacters: 20)

        XCTAssertEqual(chunks.map(\.rawText).joined(), source)
        XCTAssertTrue(chunks.allSatisfy { $0.rawText.count <= 900 })
        XCTAssertTrue(chunks.allSatisfy { !$0.source.isEmpty })
    }

    func testZeroChunkContextIsEmptyOnBothSides() {
        let source = String(repeating: "a", count: 600)
        let chunks = TextChunker.makeChunks(fileIndex: 0, fileName: "context.txt", text: source, maxCharacters: 256, contextCharacters: 0)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.previousTail.isEmpty && $0.nextHead.isEmpty })
    }
}

final class QualityAndPromptTests: XCTestCase {
    func testCurrentTranslationPrefersFinalOverAttemptHistory() {
        let attempts = [
            TranslationAttempt(translation: "首次译文"),
            TranslationAttempt(translation: "通过的重译")
        ]
        let completed = TranslationChunk(index: 0, fileIndex: 0, fileName: "story.txt", source: "source", attempts: attempts, finalTranslation: "通过的重译")
        let inProgress = TranslationChunk(index: 1, fileIndex: 0, fileName: "story.txt", source: "source", attempts: attempts)

        XCTAssertEqual(completed.currentTranslation, "通过的重译")
        XCTAssertEqual(inProgress.currentTranslation, "通过的重译")
        XCTAssertEqual(completed.translation(forAttempt: nil), "通过的重译")
        XCTAssertEqual(completed.translation(forAttempt: 0), "首次译文")
        XCTAssertEqual(completed.translation(forAttempt: 20), "通过的重译")
    }

    func testDeterministicChecksFindEmptyLeakTermsAndParagraphMismatch() {
        let glossary = [GlossaryEntry(source: "Fen", target: "老芬", category: "人名")]
        let empty = TranslationQuality.inspect(source: "Fen entered.", translation: "  ", sourceLanguage: "英语", glossary: glossary, previousTranslation: "")
        XCTAssertTrue(empty.hardFailures.contains { $0.message == "译文为空" })

        let leaked = TranslationQuality.inspect(source: "Fen entered.", translation: "【源文】hello\nextra\nmore\nend", sourceLanguage: "英语", glossary: glossary, previousTranslation: "")
        XCTAssertTrue(leaked.hardFailures.contains { $0.message.contains("提示词泄漏") })
        XCTAssertTrue(leaked.findings.contains { $0.message.contains("术语缺失") })
        XCTAssertTrue(leaked.findings.contains { $0.message.contains("段落数不一致") })
    }

    func testRepeatedRunIsHardFailure() {
        let repeated = String(repeating: "这是一段不断重复的文本。", count: 6)
        let report = TranslationQuality.inspect(source: "原文", translation: repeated, sourceLanguage: "日语", glossary: [], previousTranslation: "")
        XCTAssertTrue(report.hardFailures.contains { $0.message.contains("连续重复") })
    }

    func testLengthAndResidualScriptChecksAreLimitedToChineseTargets() {
        let source = [
            "The old house stood beside a river.",
            "Anna carried the blue letter upstairs.",
            "Rain covered the narrow road.",
            "Tomorrow the garden would bloom again.",
            "She waited until the clock struck midnight.",
            "Beyond the hill, a train crossed the valley."
        ].joined(separator: " ")
        let translation = [
            "La vieille maison se dressait près d'une rivière.",
            "Anna monta avec la lettre bleue.",
            "La pluie recouvrait la route étroite.",
            "Le jardin fleurirait de nouveau demain.",
            "Elle attendit que l'horloge sonne minuit.",
            "Au-delà de la colline, un train traversa la vallée."
        ].joined(separator: " ")
        let french = TranslationQuality.inspect(source: source, translation: translation, sourceLanguage: "English", targetLanguage: "French", glossary: [], previousTranslation: "")
        XCTAssertFalse(french.hardFailures.contains { $0.message.contains("长度比异常") })
        XCTAssertFalse(french.hardFailures.contains { $0.message.contains("残留原文字符比例") })

        let chinese = TranslationQuality.inspect(source: source, translation: translation, sourceLanguage: "English", targetLanguage: "简体中文", glossary: [], previousTranslation: "")
        XCTAssertTrue(chinese.hardFailures.contains { $0.message.contains("长度比异常") })
        XCTAssertTrue(chinese.hardFailures.contains { $0.message.contains("残留原文字符比例") })

        for alias in ["汉语", "Mandarin", "zh-Hans-CN", "zh_Hant_TW"] {
            let report = TranslationQuality.inspect(source: source, translation: translation, sourceLanguage: "English", targetLanguage: alias, glossary: [], previousTranslation: "")
            XCTAssertTrue(report.hardFailures.contains { $0.message.contains("长度比异常") }, "Chinese length rules should apply to \(alias)")
            XCTAssertTrue(report.hardFailures.contains { $0.message.contains("残留原文字符比例") }, "Chinese script rules should apply to \(alias)")
        }
    }

    func testFallbackReviewUsesDesignScorePolicy() {
        let failed = QualityReport(findings: [.init(message: "截断", hard: true)])
        XCTAssertEqual(TranslationQuality.fallbackReview(for: failed).score, 30)
        let soft = QualityReport(findings: [.init(message: "段落", penalty: 5)])
        XCTAssertEqual(TranslationQuality.fallbackReview(for: soft).score, 80)
    }

    func testGlossaryPenaltyNeverExceedsTwentyPoints() {
        let terms = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta"].map { GlossaryEntry(source: $0, target: "译名") }
        let report = TranslationQuality.inspect(source: "Alpha Beta Gamma Delta Epsilon Zeta", translation: "完全不同", sourceLanguage: "英语", glossary: terms, previousTranslation: "")
        XCTAssertEqual(report.findings.filter { $0.message.contains("术语缺失") }.reduce(0) { $0 + $1.penalty }, 20)
    }

    func testEnglishGlossaryUsesWordBoundaries() {
        let guide = TranslationGuide(terms: [GlossaryEntry(source: "Fen", target: "老芬")])
        XCTAssertTrue(PromptBuilder.relevantGlossary(in: "Fen opened the door.", guide: guide).count == 1)
        XCTAssertTrue(PromptBuilder.relevantGlossary(in: "The fence was high.", guide: guide).isEmpty)
        let cjkGuide = TranslationGuide(terms: [GlossaryEntry(source: "田中", target: "田中")])
        XCTAssertEqual(PromptBuilder.relevantGlossary(in: "田中さんが来た。", guide: cjkGuide).count, 1)
    }

    func testControllerPromptsRetainPlannerAndReviewerRules() {
        let person = CharacterEntry(source: "Alice", target: "爱丽丝", gender: "女", role: "主角", voice: "冷静", aliases: [GlossaryAlias(source: "Al", target: "爱丽")])
        let guide = TranslationGuide(characters: [person], rules: ["保留原意"])
        let chunk = TranslationChunk(index: 0, fileIndex: 0, fileName: "story.txt", source: "Alice spoke.")
        let planner = PromptBuilder.planner(text: chunk.source, windowIndex: 1, windowCount: 1, existing: nil, settings: AppSettings())
        let reviewer = PromptBuilder.reviewer(chunk: chunk, translation: "爱丽丝说。", guide: guide, settings: AppSettings(), qualityFindings: [])
        XCTAssertTrue(planner.user.contains("gender 只能是男、女、未知"))
        XCTAssertTrue(planner.user.contains("category 只能是人名、地名、组织、物品、术语、称谓、其他"))
        XCTAssertTrue(reviewer.user.contains("accuracy忠实度"))
        XCTAssertTrue(reviewer.user.contains("source 逐字引用问题原文"))
        XCTAssertTrue(reviewer.user.contains("revise"))
    }
}

final class JobActivityGuardTests: XCTestCase {
    func testActiveJobCannotBeMutatedOrReplacedUntilRunnerFinishes() {
        var guardState = JobActivityGuard()
        let active = UUID()
        let queued = UUID()
        XCTAssertTrue(guardState.begin(active))
        XCTAssertFalse(guardState.begin(queued))
        XCTAssertFalse(guardState.canMutate(active))
        XCTAssertTrue(guardState.canMutate(queued))
        guardState.finish(queued)
        XCTAssertFalse(guardState.canMutate(active))
        guardState.finish(active)
        XCTAssertTrue(guardState.canMutate(active))
        XCTAssertTrue(guardState.begin(queued))
    }
}

final class SerialJobQueueTests: XCTestCase {
    func testQueueIsFIFORejectsDuplicatesAndSupportsDeletion() {
        var queue = SerialJobQueue()
        let first = UUID()
        let removed = UUID()
        let last = UUID()
        XCTAssertTrue(queue.enqueue(first))
        XCTAssertTrue(queue.enqueue(removed))
        XCTAssertTrue(queue.enqueue(last))
        XCTAssertFalse(queue.enqueue(first))
        XCTAssertTrue(queue.remove(removed))
        XCTAssertEqual(queue.dequeue(), first)
        XCTAssertEqual(queue.dequeue(), last)
        XCTAssertNil(queue.dequeue())
    }

    func testPausedQueueKeepsLaterJobsPendingUntilExplicitResume() {
        var queue = SerialJobQueue()
        let active = UUID()
        let pending = UUID()
        XCTAssertTrue(queue.enqueue(active))
        XCTAssertTrue(queue.enqueue(pending))
        XCTAssertEqual(queue.dequeue(), active)
        XCTAssertEqual(queue.pendingIDs, [pending])
        XCTAssertEqual(queue.dequeue(), pending)
    }
}

final class TranslationTextMetricsTests: XCTestCase {
    func testCJKBudgetsUseRealScriptRangesAndNamesMatchInsideProse() {
        let chinese = String(repeating: "汉", count: 4_000)
        let japanese = String(repeating: "日本語かなカナ", count: 1_000)
        XCTAssertEqual(TranslationTextMetrics.estimatedTokens(chinese), 4_000)
        XCTAssertGreaterThanOrEqual(TranslationTextMetrics.estimatedTokens(japanese), 7_000)
        XCTAssertTrue(TranslationTextMetrics.containsSource("田中", in: "田中さんが歩いた。"))
        XCTAssertTrue(TranslationTextMetrics.containsSource("Alice", in: "Alice spoke."))
        XCTAssertFalse(TranslationTextMetrics.containsSource("Alice", in: "Malice spoke."))
    }
}

final class PersistenceAndPipelineTests: XCTestCase {
    func testJobStoreReloadsPersistedLogs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let jobID = UUID()
        let otherJobID = UUID()
        try await store.appendLog(jobID: jobID, message: "已完成第一个片段")
        let logURL = root.appendingPathComponent("jobs/\(jobID.uuidString)/events.log")
        let legacy = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-01-01T00:00:00Z", "message": "旧格式活动"], options: [.prettyPrinted])
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: legacy)
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()
        try await store.appendLog(jobID: otherJobID, message: "另一任务的活动")
        let lines = try await store.loadLog(jobID: jobID)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("已完成第一个片段"))
        XCTAssertTrue(lines[1].contains("旧格式活动"))
        XCTAssertFalse(lines[0].contains("另一任务的活动"))
    }

    func testLargeCJKPromptsAreRejectedByClientBudgetBeforeRequest() async {
        let transport = MockLMStudioTransport()
        let client = LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport)
        for text in [String(repeating: "汉", count: 4_000), String(repeating: "日本語かなカナ", count: 600)] {
            do {
                _ = try await client.chat(model: "translator", prompt: ChatPrompt(system: "", user: text), temperature: 0.5, maxTokens: 1_000, contextLength: 4_096)
                XCTFail("Expected the CJK-heavy prompt to exceed the available context")
            } catch is LMStudioError {
                XCTAssertTrue(transport.recordedRequests.isEmpty)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testJobStoreRoundTripAndPartialOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let chunk = TranslationChunk(index: 0, fileIndex: 0, fileName: "story.txt", source: "hello", leadingWhitespace: "\n", trailingWhitespace: "\n", status: .pending)
        let job = TranslationJob(name: "Story", series: false, sourceFiles: [SourceDocument(name: "story.txt", text: "hello")], chunks: [chunk])
        try await store.save(job)
        let loaded = try await store.loadJob(id: job.id)
        XCTAssertEqual(loaded?.id, job.id)
        XCTAssertEqual(loaded?.status, job.status)
        XCTAssertEqual(loaded?.chunks, job.chunks)
        XCTAssertEqual(loaded?.sourceFiles, job.sourceFiles)
        let output = await store.output(for: job, fileIndex: 0)
        XCTAssertEqual(output, "\n【待翻译：片段 1】\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("jobs/\(job.id.uuidString)/chunks/00001.json").path))
    }

    func testOutputByJobIDReloadsTheLatestPersistedTranslation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let chunk = TranslationChunk(index: 0, fileIndex: 0, fileName: "story.txt", source: "hello", status: .done, finalTranslation: "初稿")
        var job = TranslationJob(name: "Fresh output", series: false, sourceFiles: [SourceDocument(name: "story.txt", text: "hello")], chunks: [chunk])
        try await store.save(job)
        let first = try await store.output(jobID: job.id, fileIndex: 0)
        XCTAssertEqual(first, "初稿")

        job.chunks[0].finalTranslation = "最新译文"
        try await store.save(job)
        let latest = try await store.output(jobID: job.id, fileIndex: 0)
        XCTAssertEqual(latest, "最新译文")
    }

    func testSameBasenameSourcesKeepSeparateOutputArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let first = TranslationChunk(index: 0, fileIndex: 0, fileName: "chapter.txt", source: "first", status: .done, finalTranslation: "第一份译文")
        let second = TranslationChunk(index: 1, fileIndex: 1, fileName: "chapter.txt", source: "second", status: .done, finalTranslation: "第二份译文")
        let job = TranslationJob(name: "Duplicate basenames", series: true, sourceFiles: [
            SourceDocument(name: "chapter.txt", text: "first source"),
            SourceDocument(name: "chapter.txt", text: "second source")
        ], chunks: [first, second])

        try await store.save(job)

        let outputDirectory = root.appendingPathComponent("jobs/\(job.id.uuidString)/output", isDirectory: true)
        let outputFiles = try FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(outputFiles.count, 2)
        XCTAssertEqual(outputFiles.map(\.lastPathComponent), ["01-chapter.zh.txt", "02-chapter.zh.txt"])
        let contents = try outputFiles.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(contents, ["第一份译文", "第二份译文"])
    }

    func testPipelineRunsPlannerScoutTranslatorReviewerAndPersistsCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let transport = MockLMStudioTransport()
        let settings = AppSettings(controllerModel: "controller", translatorModel: "translator", maxChunkCharacters: 2_000, pauseAfterOverview: false)
        let client = LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport)
        let pipeline = TranslationPipeline(store: store, client: client)
        let job = try await pipeline.createJob(name: "Smoke", sources: [SourceDocument(name: "story.txt", text: "Hello there.")], series: false, settings: settings)
        let finished = try await pipeline.run(jobID: job.id, settings: settings)

        XCTAssertEqual(finished.status, .completed)
        XCTAssertEqual(finished.completedCount, 1)
        XCTAssertEqual(finished.chunks[0].finalTranslation, "你好。")
        XCTAssertEqual(finished.chunks[0].attempts.first?.review?.score, 100)
        let output = await store.output(for: finished, fileIndex: 0)
        XCTAssertEqual(output, "你好。")
        let routes = transport.recordedRequests.map { $0.url?.path ?? "" }
        XCTAssertTrue(routes.contains("/api/v1/models"))
        XCTAssertTrue(routes.contains("/api/v1/models/load"))
        XCTAssertTrue(routes.contains("/api/v1/models/unload"))
        XCTAssertTrue(routes.contains("/v1/chat/completions"))
        let chatBodies = transport.recordedRequests.filter { $0.url?.path == "/v1/chat/completions" }.compactMap { request in
            try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        }
        let translatorBody = try XCTUnwrap(chatBodies.first { $0["model"] as? String == "translator" })
        XCTAssertEqual(translatorBody["reasoning_effort"] as? String, "none")
        XCTAssertNotNil(chatBodies.first { $0["response_format"] != nil })
    }

    func testPlannerRetriesMalformedStructuredResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let transport = MockLMStudioTransport(chatResponses: ["not JSON"])
        let settings = AppSettings(controllerModel: "controller", translatorModel: "translator", maxChunkCharacters: 2_000, pauseAfterOverview: true)
        let pipeline = TranslationPipeline(store: store, client: LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport))
        let job = try await pipeline.createJob(name: "Retry", sources: [SourceDocument(name: "story.txt", text: "Hello there.")], series: false, settings: settings)
        let awaiting = try await pipeline.run(jobID: job.id, settings: settings)
        XCTAssertEqual(awaiting.status, .awaitingGuide)
        let plannerCalls = transport.recordedRequests.filter { request in
            guard request.url?.path == "/v1/chat/completions",
                  let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any],
                  let messages = body["messages"] as? [[String: String]] else { return false }
            return messages.last?["content"]?.contains("通读原文") == true
        }
        XCTAssertEqual(plannerCalls.count, 2)
    }

    func testResumedTranslatedChunkIsReviewedWithoutRetranslating() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let transport = MockLMStudioTransport()
        let settings = AppSettings(controllerModel: "controller", translatorModel: "translator", maxChunkCharacters: 2_000, pauseAfterOverview: false)
        let chunk = TranslationChunk(index: 0, fileIndex: 0, fileName: "story.txt", source: "Hello there.", status: .reviewing, attempts: [TranslationAttempt(translation: "你好。", temperature: 0.5)])
        var job = TranslationJob(name: "Resume", series: false, sourceFiles: [SourceDocument(name: "story.txt", text: "Hello there.")], chunks: [chunk])
        job.guide = TranslationGuide(titleZh: "测试作品", sourceLanguage: "英语")
        try await store.save(job)

        let finished = try await TranslationPipeline(store: store, client: LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport)).run(jobID: job.id, settings: settings)
        XCTAssertEqual(finished.status, .completed)
        XCTAssertEqual(finished.chunks[0].attempts.count, 1)
        XCTAssertEqual(finished.chunks[0].attempts[0].review?.verdict, "pass")
        let chatBodies = transport.recordedRequests.filter { $0.url?.path == "/v1/chat/completions" }.compactMap { request in
            try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        }
        XCTAssertEqual(chatBodies.count, 1)
        XCTAssertEqual(chatBodies[0]["model"] as? String, "controller")
    }

    func testReviewerRevisionTriggersBoundedRetryAndKeepsBestOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let responses = [
            #"{"title_zh":"测试作品","source_language":"英语","genre":"小说","synopsis":"测试。","style":{"narration":"第三人称","tone":"平实","diction":"自然","dialogue":"口语","punctuation":"中文标点"},"characters":[],"terms":[],"rules":["忠实原文","术语一致","保留段落"]}"#,
            #"{"summary":"人物问候。","new_terms":[],"translation_notes":[],"memory":"人物见面并相互问候，故事刚刚开始。"}"#,
            "Hello.",
            #"{"scores":{"accuracy":4,"completeness":4,"terminology":4,"fluency":4,"style":4},"issues":[],"revision_instructions":["使用中文自然表达"],"verdict":"revise","comment":"需要润色。"}"#,
            "你好。",
            #"{"scores":{"accuracy":10,"completeness":10,"terminology":10,"fluency":10,"style":10},"issues":[],"revision_instructions":[],"verdict":"pass","comment":"通过。"}"#
        ]
        let store = JobStore(rootURL: root)
        let transport = MockLMStudioTransport(chatResponses: responses)
        let settings = AppSettings(controllerModel: "controller", translatorModel: "translator", maxChunkCharacters: 2_000, maxRetries: 1, pauseAfterOverview: false)
        let pipeline = TranslationPipeline(store: store, client: LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport))
        let job = try await pipeline.createJob(name: "Revision", sources: [SourceDocument(name: "story.txt", text: "Hello there.")], series: false, settings: settings)
        let finished = try await pipeline.run(jobID: job.id, settings: settings)
        XCTAssertEqual(finished.status, .completed)
        XCTAssertEqual(finished.chunks[0].attempts.count, 2)
        XCTAssertEqual(finished.chunks[0].attempts[0].review?.verdict, "revise")
        XCTAssertEqual(finished.chunks[0].attempts[1].review?.verdict, "pass")
        XCTAssertEqual(finished.chunks[0].finalTranslation, "你好。")
        XCTAssertGreaterThan(finished.controllerTokens, 0)
        XCTAssertGreaterThan(finished.translatorTokens, 0)
    }

    func testPassingRetryBecomesFinalEvenWhenRejectedDraftScoredHigher() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let pass80 = #"{"scores":{"accuracy":8,"completeness":8,"terminology":8,"fluency":8,"style":8},"issues":[],"revision_instructions":[],"verdict":"pass","comment":"通过。"}"#
        let transport = MockLMStudioTransport(chatResponses: ["通过后的译文。", pass80])
        let settings = AppSettings(controllerModel: "controller", translatorModel: "translator", passScore: 70, maxRetries: 1, pauseAfterOverview: false)
        var rejectedAttempt = TranslationAttempt(translation: "高分但驳回的旧稿。", temperature: 0.5)
        rejectedAttempt.review = TranslationReview(verdict: "revise", comment: "尚未通过", score: 90)
        let chunk = TranslationChunk(index: 0, fileIndex: 0, fileName: "story.txt", source: "Hello there.", status: .scouted, attempts: [rejectedAttempt])
        var job = TranslationJob(name: "Accepted retry", series: false, sourceFiles: [SourceDocument(name: "story.txt", text: "Hello there.")], chunks: [chunk])
        job.guide = TranslationGuide(titleZh: "测试作品", sourceLanguage: "英语")
        job.status = .paused
        try await store.save(job)
        let pipeline = TranslationPipeline(store: store, client: LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport))

        let finished = try await pipeline.run(jobID: job.id, settings: settings)

        XCTAssertEqual(finished.chunks[0].status, .done)
        XCTAssertEqual(finished.chunks[0].finalTranslation, "通过后的译文。")
        XCTAssertEqual(finished.chunks[0].reviewScore, 80)
    }

    func testFallbackRetainsLengthFinishReasonFromEarlierPart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alphabet = Array("甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥春夏秋冬山川江河天地风云星月日夜雨雪草木花鸟鱼虫")
        func variedText(_ count: Int, seed: Int) -> String {
            String((0..<count).map { alphabet[($0 * 7 + $0 / 11 + seed) % alphabet.count] })
        }
        let source = String(repeating: "Original passage. ", count: 180)
        let store = JobStore(rootURL: root)
        let priorReview = TranslationReview(verdict: "revise", automaticChecks: [QualityFinding(message: "先前截断", hard: true)], score: 30)
        let attempts = (0..<2).map { _ -> TranslationAttempt in
            var attempt = TranslationAttempt(translation: "旧译文。", temperature: 0.5)
            attempt.review = priorReview
            return attempt
        }
        let partOne = variedText(1_700, seed: 1)
        let partTwo = variedText(600, seed: 5)
        let transport = MockLMStudioTransport(chatResponses: [partOne, partTwo], chatFinishReasons: ["length", "stop"])
        let settings = AppSettings(controllerModel: "controller", translatorModel: "translator", maxRetries: 0, pauseAfterOverview: false)
        let chunk = TranslationChunk(index: 0, fileIndex: 0, fileName: "story.txt", source: source, status: .scouted, attempts: attempts)
        var job = TranslationJob(name: "Fallback finish reason", series: false, sourceFiles: [SourceDocument(name: "story.txt", text: source)], chunks: [chunk])
        job.guide = TranslationGuide(titleZh: "测试作品", sourceLanguage: "英语")
        job.status = .paused
        try await store.save(job)
        let pipeline = TranslationPipeline(store: store, client: LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport))

        let finished = try await pipeline.run(jobID: job.id, settings: settings)

        let latest = try XCTUnwrap(finished.chunks[0].latestAttempt)
        XCTAssertEqual(latest.finishReason, "length")
        XCTAssertTrue(latest.review?.automaticChecks.contains { $0.message.contains("输出达到token上限") } == true)
        XCTAssertEqual(finished.chunks[0].status, .flagged)
    }

    func testBatchScoutsUseUpdatedGuideAndLaterTranslationUsesPriorDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "龙王" + String(repeating: "甲", count: 130) + "。\n\n" + "龙王" + String(repeating: "乙", count: 130) + "。"
        let store = JobStore(rootURL: root)
        let transport = MockLMStudioTransport()
        let settings = AppSettings(controllerModel: "controller", translatorModel: "translator", maxChunkCharacters: 256, batchSize: 2, passScore: 50, maxRetries: 0, pauseAfterOverview: false)
        let pipeline = TranslationPipeline(store: store, client: LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport))
        let job = try await pipeline.createJob(name: "Batch context", sources: [SourceDocument(name: "story.txt", text: source)], series: false, settings: settings)
        XCTAssertEqual(job.chunks.count, 2)
        _ = try await pipeline.run(jobID: job.id, settings: settings)

        let chatBodies = transport.recordedRequests.filter { $0.url?.path == "/v1/chat/completions" }.compactMap { request in
            try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        }
        let messages: (Any?) -> [[String: String]] = { $0 as? [[String: String]] ?? [] }
        let secondScout = try XCTUnwrap(chatBodies.first { body in
            messages(body["messages"]).last?["content"]?.contains("预读第 2/") == true
        })
        XCTAssertTrue(messages(secondScout["messages"]).last?["content"]?.contains("龙王→龙王") == true)
        let secondTranslation = try XCTUnwrap(chatBodies.first { body in
            body["model"] as? String == "translator" && messages(body["messages"]).last?["content"]?.contains(String(repeating: "乙", count: 20)) == true
        })
        XCTAssertTrue(messages(secondTranslation["messages"]).first?["content"]?.contains("译王") == true)
    }

    func testExplicitRetryGetsFreshInferenceAndRetryBudgetAfterOldHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let revise = #"{"scores":{"accuracy":6,"completeness":6,"terminology":6,"fluency":6,"style":6},"issues":[],"revision_instructions":["重译"],"verdict":"revise","comment":"继续修订。"}"#
        let pass = #"{"scores":{"accuracy":8,"completeness":8,"terminology":8,"fluency":8,"style":8},"issues":[],"revision_instructions":[],"verdict":"pass","comment":"通过。"}"#
        let transport = MockLMStudioTransport(chatResponses: ["新译文1。", revise, "新译文2。", pass])
        let settings = AppSettings(controllerModel: "controller", translatorModel: "translator", passScore: 70, maxRetries: 1, pauseAfterOverview: false)
        let attempts = (0..<3).map { _ -> TranslationAttempt in
            var attempt = TranslationAttempt(translation: "历史译文", temperature: 0.3)
            attempt.review = TranslationReview(verdict: "pass", comment: "旧评审", score: 100)
            return attempt
        }
        var chunk = TranslationChunk(index: 0, fileIndex: 0, fileName: "story.txt", source: "Hello there.", status: .done, attempts: attempts, finalTranslation: "历史译文", reviewScore: 100)
        chunk.explicitRetryPending = nil
        var job = TranslationJob(name: "Retry history", series: false, sourceFiles: [SourceDocument(name: "story.txt", text: "Hello there.")], chunks: [chunk])
        job.guide = TranslationGuide(titleZh: "测试作品", sourceLanguage: "英语")
        job.status = .completed
        try await store.save(job)
        let pipeline = TranslationPipeline(store: store, client: LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport))

        let queued = try await pipeline.retranslate(jobID: job.id, chunkIndex: 0, note: "再次翻译")
        XCTAssertEqual(queued.chunks[0].explicitRetryPending, true)
        XCTAssertEqual(queued.chunks[0].retryCycleStartIndex, 3)
        let finished = try await pipeline.run(jobID: job.id, settings: settings)
        XCTAssertEqual(finished.chunks[0].attempts.count, 5)
        XCTAssertEqual(finished.chunks[0].finalTranslation, "新译文2。")
        XCTAssertNil(finished.chunks[0].explicitRetryPending)
        let translatorCalls = transport.recordedRequests.filter { request in
            guard request.url?.path == "/v1/chat/completions",
                  let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] else { return false }
            return body["model"] as? String == "translator"
        }
        XCTAssertEqual(translatorCalls.count, 2)
    }

    func testOriginalRetryBudgetDoesNotResetAfterResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let revise = #"{"scores":{"accuracy":6,"completeness":6,"terminology":6,"fluency":6,"style":6},"issues":[],"revision_instructions":["修订"],"verdict":"revise","comment":"继续修订。"}"#
        let transport = MockLMStudioTransport(chatResponses: ["新译文。", revise])
        let settings = AppSettings(controllerModel: "controller", translatorModel: "translator", passScore: 70, maxRetries: 2, pauseAfterOverview: false)
        let attempts = (0..<2).map { _ -> TranslationAttempt in
            var attempt = TranslationAttempt(translation: "旧译文。", temperature: 0.5)
            attempt.review = TranslationReview(verdict: "revise", comment: "需修改", score: 60)
            return attempt
        }
        let chunk = TranslationChunk(index: 0, fileIndex: 0, fileName: "story.txt", source: "Hello there.", status: .scouted, attempts: attempts)
        var job = TranslationJob(name: "Resume retry budget", series: false, sourceFiles: [SourceDocument(name: "story.txt", text: "Hello there.")], chunks: [chunk])
        job.guide = TranslationGuide(titleZh: "测试作品", sourceLanguage: "英语")
        job.status = .paused
        try await store.save(job)
        let pipeline = TranslationPipeline(store: store, client: LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport))

        let resumed = try await pipeline.run(jobID: job.id, settings: settings)
        XCTAssertEqual(resumed.chunks[0].retryCycleStartIndex, nil)
        XCTAssertEqual(resumed.chunks[0].attempts.count, 3)
        XCTAssertEqual(resumed.chunks[0].status, .flagged)
        let translatorBodies = transport.recordedRequests.filter { $0.url?.path == "/v1/chat/completions" }.compactMap { request in
            try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        }.filter { $0["model"] as? String == "translator" }
        XCTAssertEqual(translatorBodies.count, 1)
    }

    func testExplicitRetryResumeUsesCycleRelativeTemperatureAndFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let source = String(repeating: "Original passage. ", count: 180)
        var attempts = (0..<3).map { _ -> TranslationAttempt in
            var attempt = TranslationAttempt(translation: "历史译文。", temperature: 0.5)
            attempt.review = TranslationReview(verdict: "pass", comment: "旧周期通过", score: 100)
            return attempt
        }
        var currentCycleAttempt = TranslationAttempt(translation: "待修订译文。", temperature: 0.5)
        currentCycleAttempt.review = TranslationReview(verdict: "revise", comment: "存在硬伤", automaticChecks: [QualityFinding(message: "截断", hard: true)], score: 60)
        attempts.append(currentCycleAttempt)
        let chunk = TranslationChunk(index: 0, fileIndex: 0, fileName: "story.txt", source: source, status: .scouted, attempts: attempts, retryCycleStartIndex: 3)
        var job = TranslationJob(name: "Resume explicit retry", series: false, sourceFiles: [SourceDocument(name: "story.txt", text: source)], chunks: [chunk])
        job.guide = TranslationGuide(titleZh: "测试作品", sourceLanguage: "英语")
        job.status = .paused
        try await store.save(job)
        let transport = MockLMStudioTransport()
        let settings = AppSettings(controllerModel: "controller", translatorModel: "translator", maxRetries: 1, pauseAfterOverview: false)
        let pipeline = TranslationPipeline(store: store, client: LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport))

        let resumed = try await pipeline.run(jobID: job.id, settings: settings)
        let translatorBodies = transport.recordedRequests.filter { $0.url?.path == "/v1/chat/completions" }.compactMap { request in
            try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        }.filter { $0["model"] as? String == "translator" }
        XCTAssertEqual(resumed.chunks[0].retryCycleStartIndex, 3)
        XCTAssertEqual(resumed.chunks[0].attempts.count, 5)
        XCTAssertEqual(resumed.chunks[0].attempts.last?.temperature, settings.translatorTemperature)
        XCTAssertEqual(translatorBodies.count, 1)
        XCTAssertEqual(translatorBodies.first?["temperature"] as? Double, settings.translatorTemperature)
    }

    func testReviewerCancellationPausesWithoutFallbackReviewOrJSONRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let transport = MockLMStudioTransport(cancelChatWhenUserContains: "审校第")
        let settings = AppSettings(controllerModel: "controller", translatorModel: "translator", pauseAfterOverview: false)
        let pipeline = TranslationPipeline(store: store, client: LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport))
        let job = try await pipeline.createJob(name: "Cancel", sources: [SourceDocument(name: "story.txt", text: "Hello there.")], series: false, settings: settings)

        let paused = try await pipeline.run(jobID: job.id, settings: settings)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertNil(paused.chunks[0].latestAttempt?.review)
        XCTAssertEqual(transport.recordedRequests.filter { $0.url?.path == "/v1/chat/completions" }.count, 4)
    }

    func testMemoryCompressionCancellationDoesNotUseTruncatedFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let transport = MockLMStudioTransport(cancelChatWhenUserContains: "以下记忆有", longScoutMemory: true)
        let settings = AppSettings(controllerModel: "controller", translatorModel: "translator", pauseAfterOverview: false)
        let pipeline = TranslationPipeline(store: store, client: LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport))
        let job = try await pipeline.createJob(name: "Cancel compression", sources: [SourceDocument(name: "story.txt", text: "Hello there.")], series: false, settings: settings)

        let paused = try await pipeline.run(jobID: job.id, settings: settings)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertTrue(paused.chunks[0].attempts.isEmpty)
        XCTAssertEqual(transport.recordedRequests.filter { $0.url?.path == "/v1/chat/completions" }.count, 3)
    }

    func testSwapUnloadsOnlyConfiguredCounterpartInstances() async throws {
        let transport = MockLMStudioTransport(initiallyLoaded: [
            "controller": ("instance-controller", 32_768),
            "translator": ("instance-translator", 32_768),
            "unrelated-model": ("instance-unrelated", 32_768)
        ])
        let settings = AppSettings(controllerModel: "controller", translatorModel: "translator", modelStrategy: .swap)
        try await ModelScheduler.prepare(role: "controller", settings: settings, client: LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport))
        let unloadIDs = transport.recordedRequests.filter { $0.url?.path == "/api/v1/models/unload" }.compactMap { request in
            (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String]
        }.compactMap { $0["instance_id"] }
        XCTAssertEqual(unloadIDs, ["instance-translator"])
    }

    func testSwapKeepsLoadedModelWhenControllerAndTranslatorAreSame() async throws {
        let transport = MockLMStudioTransport(initiallyLoaded: ["controller": ("instance-controller", 65_536)])
        let settings = AppSettings(controllerModel: "controller", translatorModel: "controller", modelStrategy: .swap)
        try await ModelScheduler.prepare(role: "controller", settings: settings, client: LMStudioClient(baseURL: "http://127.0.0.1:1234", transport: transport))
        XCTAssertEqual(transport.recordedRequests.map { $0.url?.path }, ["/api/v1/models"])
    }
}

final class URLSessionTransportIntegrationTests: XCTestCase {
    func testChatParsesIncrementalMultilineSSEOverLocalHTTP() async throws {
        let body = Data("data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}],\r\ndata: \"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3}}\r\n\r\ndata: [DONE]\n\n".utf8)
        let server = try LocalSSEHTTPServer(body: body)
        let port = try server.start()
        defer { server.stop() }
        let client = LMStudioClient(baseURL: "http://127.0.0.1:\(port)", transport: URLSessionTransport())

        let response = try await client.chat(
            model: "translator",
            prompt: ChatPrompt(system: "Translate.", user: "Hello."),
            temperature: 0.5,
            maxTokens: 64,
            contextLength: 2_048
        )

        XCTAssertEqual(response.content, "你好")
        XCTAssertEqual(response.promptTokens, 7)
        XCTAssertEqual(response.completionTokens, 3)
    }

    func testChatParsesBareCRAndSplitCRLFSSEOverLocalHTTP() async throws {
        let body = Data("data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}],\r\ndata: \"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3}}\r\rdata: [DONE]\r\r".utf8)
        guard let crlf = body.range(of: Data("\r\n".utf8)) else { return XCTFail("Expected CRLF in test event") }
        let server = try LocalSSEHTTPServer(body: body, splitOffsets: [crlf.lowerBound + 1])
        let port = try server.start()
        defer { server.stop() }
        let client = LMStudioClient(baseURL: "http://127.0.0.1:\(port)", transport: URLSessionTransport())

        let response = try await client.chat(
            model: "translator",
            prompt: ChatPrompt(system: "Translate.", user: "Hello."),
            temperature: 0.5,
            maxTokens: 64,
            contextLength: 2_048
        )

        XCTAssertEqual(response.content, "你")
        XCTAssertEqual(response.promptTokens, 7)
        XCTAssertEqual(response.completionTokens, 3)
    }
}

final class LMStudioTransportSecurityTests: XCTestCase {
    func testPlainHTTPIsRejectedForNonLoopbackHosts() async throws {
        let transport = MockLMStudioTransport()
        let client = LMStudioClient(baseURL: "http://api.example.com:1234", transport: transport)

        do {
            _ = try await client.models()
            XCTFail("Remote plaintext HTTP must be rejected")
        } catch LMStudioError.insecureBaseURL {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(transport.recordedRequests.isEmpty)
    }

    func testLoopbackHTTPAndRemoteHTTPSAreAllowed() async throws {
        for baseURL in ["http://127.0.0.1:1234", "http://127.4.5.6:1234", "http://[::1]:1234", "http://localhost:1234", "https://api.example.com"] {
            let transport = MockLMStudioTransport()
            let client = LMStudioClient(baseURL: baseURL, transport: transport)
            _ = try await client.models()
            XCTAssertEqual(transport.recordedRequests.first?.url?.scheme, URL(string: baseURL)?.scheme)
        }
    }

    func testInvalidURLAndUnsupportedSchemeAreRejected() async throws {
        for baseURL in ["not a url", "ftp://localhost:1234"] {
            let transport = MockLMStudioTransport()
            let client = LMStudioClient(baseURL: baseURL, transport: transport)
            do {
                _ = try await client.models()
                XCTFail("Invalid LM Studio URL must be rejected: \(baseURL)")
            } catch LMStudioError.invalidBaseURL {
            } catch {
                XCTFail("Unexpected error for \(baseURL): \(error)")
            }
            XCTAssertTrue(transport.recordedRequests.isEmpty)
        }
    }
}

private final class MockLMStudioTransport: LMStudioTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: [String: (id: String, context: Int)] = [:]
    private var requests: [URLRequest] = []
    private var chatResponses: [String]
    private var chatFinishReasons: [String]
    private var scoutRequests = 0
    private let cancelChatWhenUserContains: String?
    private let longScoutMemory: Bool

    init(initiallyLoaded: [String: (id: String, context: Int)] = [:], chatResponses: [String] = [], cancelChatWhenUserContains: String? = nil, longScoutMemory: Bool = false, chatFinishReasons: [String] = []) {
        loaded = initiallyLoaded
        self.chatResponses = chatResponses
        self.cancelChatWhenUserContains = cancelChatWhenUserContains
        self.longScoutMemory = longScoutMemory
        self.chatFinishReasons = chatFinishReasons
    }

    func enqueueChatResponses(_ responses: [String]) {
        withLock { chatResponses.append(contentsOf: responses) }
    }

    var recordedRequests: [URLRequest] {
        withLock { requests }
    }

    func send(_ request: URLRequest) async throws -> HTTPPayload {
        try respond(to: request)
    }

    private func respond(to request: URLRequest) throws -> HTTPPayload {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        let path = request.url?.path ?? ""
        if path == "/api/v1/models" {
            let models: [[String: Any]] = Set(["controller", "translator"]).union(loaded.keys).sorted().map { key in
                let instance = loaded[key].map { ["id": $0.id, "config": ["context_length": $0.context]] as [String: Any] }
                return ["key": key, "display_name": key, "type": "llm", "loaded_instances": instance.map { [$0] } ?? []]
            }
            return HTTPPayload(data: try JSONSerialization.data(withJSONObject: ["models": models]), statusCode: 200)
        }
        if path == "/api/v1/models/load" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
            let model = body["model"] as? String ?? "unknown"
            let id = "instance-\(model)"
            loaded[model] = (id, body["context_length"] as? Int ?? 32_768)
            return HTTPPayload(data: try JSONSerialization.data(withJSONObject: ["type": "llm", "instance_id": id, "status": "loaded"]), statusCode: 200)
        }
        if path == "/api/v1/models/unload" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
            let id = body["instance_id"] as? String ?? ""
            loaded = loaded.filter { $0.value.id != id }
            return HTTPPayload(data: try JSONSerialization.data(withJSONObject: ["instance_id": id]), statusCode: 200)
        }
        return HTTPPayload(data: Data(), statusCode: 404)
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        withLock { requests.append(request) }
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let messages = body["messages"] as? [[String: String]] ?? []
        let user = messages.last?["content"] ?? ""
        if let marker = cancelChatWhenUserContains, user.contains(marker) {
            return AsyncThrowingStream { continuation in continuation.finish(throwing: CancellationError()) }
        }
        var response: String
        if user.contains("通读原文") {
            response = #"{"title_zh":"测试作品","source_language":"英语","genre":"小说","synopsis":"一段测试故事。","style":{"narration":"第一人称","tone":"平实","diction":"自然","dialogue":"口语","punctuation":"中文标点"},"characters":[],"terms":[],"rules":["忠实原文","术语一致","保留段落"]}"#
        } else if user.contains("预读第") {
            response = ##"{"summary":"主人公打招呼。","new_terms":[],"translation_notes":[],"memory":"# 剧情记忆\n## 主线进展\n- 主人公与人见面。\n## 人物状态\n- 主人公在场。\n## 伏笔与悬念\n- 暂无。\n## 最新进展\n主人公问候对方。"}"##
        } else if user.contains("审校第") {
            response = #"{"scores":{"accuracy":10,"completeness":10,"terminology":10,"fluency":10,"style":10},"issues":[],"revision_instructions":[],"verdict":"pass","comment":"准确流畅。"}"#
        } else {
            response = user.contains("【源文】") && user.contains("龙王") ? "译王" + String(repeating: "乙", count: 130) + "。" : "你好。"
        }
        if user.contains("预读第") && user.contains("龙王") {
            let scoutNumber = withLock { scoutRequests += 1; return scoutRequests }
            if scoutNumber == 1 {
                response = #"{"summary":"龙王出场。","new_terms":[{"source":"龙王","target":"龙王","category":"人名","note":"角色名"}],"translation_notes":[],"memory":"龙王出现并继续前进，故事仍在展开。"}"#
            }
        }
        if longScoutMemory && user.contains("预读第") {
            let memory = String(repeating: "记", count: 5_000)
            response = #"{"summary":"人物继续前进。","new_terms":[],"translation_notes":[],"memory":"MEMORYPLACEHOLDER"}"#.replacingOccurrences(of: "MEMORYPLACEHOLDER", with: memory)
        }
        response = withLock { chatResponses.isEmpty ? response : chatResponses.removeFirst() }
        let finishReason = withLock { chatFinishReasons.isEmpty ? "stop" : chatFinishReasons.removeFirst() }
        let eventObject: [String: Any] = ["choices": [["delta": ["content": response], "finish_reason": finishReason]], "usage": ["prompt_tokens": 10, "completion_tokens": 10]]
        let event = String(data: (try? JSONSerialization.data(withJSONObject: eventObject)) ?? Data(), encoding: .utf8) ?? "{}"
        return AsyncThrowingStream { continuation in
            continuation.yield(event)
            continuation.finish()
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class LocalSSEHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "translator.tests.local-sse")
    private let ready = DispatchSemaphore(value: 0)
    private let responseFragments: [Data]
    private var listeningPort: UInt16?

    init(body: Data, splitOffsets: [Int] = []) throws {
        listener = try NWListener(using: .tcp, on: .any)
        guard let marker = body.range(of: Data("你".utf8)) else { throw LMStudioError.invalidResponse }
        let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        let offsets = Set([marker.lowerBound + 1] + splitOffsets).filter { $0 > 0 && $0 < body.count }.sorted()
        var fragments: [Data] = []
        var start = 0
        for offset in offsets {
            fragments.append(Data(body[start..<offset]))
            start = offset
        }
        fragments.append(Data(body[start...]))
        responseFragments = [header] + fragments
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.listeningPort = self?.listener.port?.rawValue
                self?.ready.signal()
            case .failed:
                self?.ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, error in
                guard error == nil else { connection.cancel(); return }
                self.sendNext(connection, index: 0)
            }
        }
    }

    func start() throws -> UInt16 {
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let listeningPort else { throw LMStudioError.invalidBaseURL }
        return listeningPort
    }

    func stop() { listener.cancel() }

    deinit { listener.cancel() }

    private func sendNext(_ connection: NWConnection, index: Int) {
        guard responseFragments.indices.contains(index) else { connection.cancel(); return }
        connection.send(content: responseFragments[index], completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { connection.cancel(); return }
            self.sendNext(connection, index: index + 1)
        })
    }
}
