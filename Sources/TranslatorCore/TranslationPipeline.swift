import Foundation
import CryptoKit

public enum TranslationPipelineError: Error, LocalizedError {
    case missingJob
    case noSourceText
    case missingGuide
    case plannerContextExceeded

    public var errorDescription: String? {
        switch self {
        case .missingJob: return "The translation task could not be found."
        case .noSourceText: return "Add at least one non-empty text file."
        case .missingGuide: return "The outline could not be generated. Check the controller model and try again."
        case .plannerContextExceeded: return "The accumulated translation guide leaves no safe context for the next planning window. Reduce the guide or increase the controller context."
        }
    }
}

enum TranslationOutputBudget {
        static func maxTokens(source: String, provider: ModelProvider) -> Int {
            let contentTokens = max(1_024, TranslationTextMetrics.estimatedTokens(source) * 2 + 512)
            guard provider == .glmCodingPlan else { return contentTokens }
            return contentTokens + max(12_288, contentTokens)
        }
}

public struct TranslationPipeline: Sendable {
    private struct PlannerWindow {
        var text: String
        var fileIndex: Int
        var fileName: String
        var startOffset: Int
        var endOffset: Int
        var sections: [DocumentSection]
        var outputReservation: Int
    }

    private let store: JobStore
    private let client: LMStudioClient

    public init(store: JobStore, client: LMStudioClient) {
        self.store = store
        self.client = client
    }

    public func createJob(name: String, sources: [SourceDocument], series: Bool, settings: AppSettings) async throws -> TranslationJob {
        var normalizedSources: [SourceDocument] = []
        var chunks: [TranslationChunk] = []
        var documentSections: [DocumentSection] = []
        for source in sources {
            let normalized = TextProcessor.normalize(source.text)
            guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let document = SourceDocument(id: source.id, name: source.name, text: normalized)
            normalizedSources.append(document)
            let fileIndex = normalizedSources.count - 1
            let sections = TextChunker.detectSections(fileIndex: fileIndex, fileName: source.name, text: normalized)
            documentSections.append(contentsOf: sections)
            let fileChunks = TextChunker.makeChunks(
                fileIndex: fileIndex,
                fileName: source.name,
                text: normalized,
                maxCharacters: settings.maxChunkCharacters,
                contextCharacters: settings.contextCharacters
            )
            var sourceOffset = 0
            for var chunk in fileChunks {
                let chunkStart = sourceOffset
                let chunkEnd = chunkStart + chunk.rawText.count
                if let section = sections.first(where: { $0.startOffset < chunkEnd && $0.endOffset > chunkStart }) {
                    chunk.sectionID = section.id
                    chunk.sectionTitle = section.title
                }
                sourceOffset = chunkEnd
                chunk.index = chunks.count
                chunks.append(chunk)
            }
        }
        guard !normalizedSources.isEmpty, !chunks.isEmpty else { throw TranslationPipelineError.noSourceText }
        var job = TranslationJob(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? normalizedSources[0].name : name, series: series, sourceFiles: normalizedSources, chunks: chunks, sections: documentSections)
        job.updatedAt = .now
        try await store.save(job)
        return job
    }

    public func run(jobID: UUID, settings: AppSettings, onEvent: @escaping @Sendable (PipelineEvent) -> Void = { _ in }) async throws -> TranslationJob {
        guard var job = try await store.loadJob(id: jobID) else { throw TranslationPipelineError.missingJob }
        do {
            try Task.checkCancellation()
            for index in job.chunks.indices {
                if job.chunks[index].status == .translating { job.chunks[index].status = .scouted }
                if job.chunks[index].status == .reviewing { job.chunks[index].status = .translated }
            }
            if job.startedAt == nil { job.startedAt = .now }
            if job.guide == nil {
                job.status = .planning
                try await persist(job, event: "开始通读并生成翻译大纲", onEvent: onEvent)
                try await generateGuide(for: &job, settings: settings, onEvent: onEvent)
                if settings.pauseAfterOverview {
                    job.status = .awaitingGuide
                    try await persist(job, event: "大纲已生成，等待确认", onEvent: onEvent)
                    return job
                }
            }
            guard job.guide != nil else { throw TranslationPipelineError.missingGuide }
            job.status = .running
            try await persist(job, event: "开始分批翻译", onEvent: onEvent)

            while true {
                try Task.checkCancellation()
                let pending = job.chunks.indices.filter { ![.done, .flagged].contains(job.chunks[$0].status) }
                guard !pending.isEmpty else { break }
                let batch = Array(pending.prefix(settings.batchSize))
                try await scout(batch: batch, job: &job, settings: settings, onEvent: onEvent)
                try await translateAndReview(batch: batch, job: &job, settings: settings, onEvent: onEvent)
                job.updatedAt = .now
                try await store.save(job)
            }
            job.status = .completed
            job.error = nil
            try await persist(job, event: "翻译任务完成", onEvent: onEvent)
            return job
        } catch is CancellationError {
            for index in job.chunks.indices {
                if job.chunks[index].status == .translating { job.chunks[index].status = .scouted }
                if job.chunks[index].status == .reviewing { job.chunks[index].status = .translated }
            }
            job.status = .paused
            job.updatedAt = .now
            try await store.save(job)
            onEvent(.status(jobID: jobID, message: "任务已暂停，可从断点继续"))
            return job
        } catch {
            job.status = .failed
            let safeError = WorkspaceDiaryStore.redact(error.localizedDescription)
            job.error = safeError
            job.updatedAt = .now
            try await store.save(job)
            onEvent(.log(jobID: jobID, message: safeError))
            throw error
        }
    }

    public func updateGuide(jobID: UUID, guide: TranslationGuide) async throws -> TranslationJob {
        guard var job = try await store.loadJob(id: jobID) else { throw TranslationPipelineError.missingJob }
        job.guide = guide
        if job.status == .awaitingGuide { job.status = .paused }
        job.updatedAt = .now
        try await store.save(job)
        return job
    }

    public func editTranslation(jobID: UUID, chunkIndex: Int, translation: String) async throws -> TranslationJob {
        guard var job = try await store.loadJob(id: jobID), let index = job.chunks.firstIndex(where: { $0.index == chunkIndex }) else { throw TranslationPipelineError.missingJob }
        var attempt = TranslationAttempt(translation: translation, temperature: 0)
        attempt.review = TranslationReview(verdict: "pass", comment: "手动编辑", score: 100, modelReviewed: false)
        job.chunks[index].attempts.append(attempt)
        job.chunks[index].explicitRetryPending = nil
        job.chunks[index].finalTranslation = translation
        job.chunks[index].reviewScore = 100
        job.chunks[index].needsHumanReview = false
        job.chunks[index].status = .done
        job.updatedAt = .now
        try await store.save(job)
        return job
    }

    public func retranslate(jobID: UUID, chunkIndex: Int, note: String) async throws -> TranslationJob {
        guard var job = try await store.loadJob(id: jobID), let index = job.chunks.firstIndex(where: { $0.index == chunkIndex }) else { throw TranslationPipelineError.missingJob }
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            job.chunks[index].translationNotes.append("用户重译要求：\(note)")
        }
        job.chunks[index].status = .scouted
        job.chunks[index].explicitRetryPending = true
        job.chunks[index].retryCycleStartIndex = job.chunks[index].attempts.count
        job.chunks[index].needsHumanReview = false
        job.chunks[index].finalTranslation = ""
        job.chunks[index].reviewScore = nil
        job.status = .paused
        job.updatedAt = .now
        try await store.save(job)
        return job
    }

    private func generateGuide(for job: inout TranslationJob, settings: AppSettings, onEvent: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        let allText = job.sourceFiles.map(\.text).joined(separator: "\n\n")
        let sourceDigest = digest(job.sourceFiles.map { "\($0.name)\u{0}\($0.text)" }.joined(separator: "\u{0}"))
        let configurationDigest = digest([
            settings.provider.rawValue, settings.controllerModel, String(settings.controllerContext),
            settings.controllerReasoning, String(settings.controllerTemperature), settings.targetLanguage,
            settings.genre, settings.extraInstructions
        ].joined(separator: "\u{0}"))
        var checkpoint = job.plannerCheckpoint
        if checkpoint?.sourceDigest != sourceDigest || checkpoint?.configurationDigest != configurationDigest {
            checkpoint = nil
        }
        try await ModelScheduler.prepare(role: "controller", settings: settings, client: client)
        var guide = checkpoint?.mergedGuide
        var completedWindows = checkpoint?.completedWindows ?? []
        let firstFile = min(max(0, checkpoint?.nextFileIndex ?? 0), job.sourceFiles.count)
        for fileIndex in firstFile..<job.sourceFiles.count {
            try Task.checkCancellation()
            let file = job.sourceFiles[fileIndex]
            let characters = Array(file.text)
            var offset = fileIndex == firstFile ? min(max(0, checkpoint?.nextOffset ?? 0), characters.count) : 0
            while offset < characters.count {
                try Task.checkCancellation()
                let windowIndex = completedWindows.count + 1
                let window = try plannerWindow(
                    fileIndex: fileIndex,
                    fileName: file.name,
                    characters: characters,
                    startOffset: offset,
                    existing: guide,
                    sections: (job.sections ?? []).filter { $0.fileIndex == fileIndex },
                    windowIndex: windowIndex,
                    settings: settings
                )
                let sectionLabel = window.sections.map(\.title).filter { !$0.isEmpty }.joined(separator: "、")
                onEvent(.activity(jobID: job.id, role: "主控", action: "通读并细化第 \(windowIndex) 个窗口 · \(file.name)\(sectionLabel.isEmpty ? "" : " · \(sectionLabel)" )"))
                let prompt = PromptBuilder.planner(
                    text: window.text,
                    windowIndex: windowIndex,
                    existing: guide,
                    settings: settings,
                    fileName: file.name,
                    sections: window.sections
                )
                let parsed = try await requestJSON(
                    TranslationGuide.self,
                    prompt: prompt,
                    model: settings.controllerModel,
                    temperature: settings.controllerTemperature,
                    maxTokens: window.outputReservation,
                    contextLength: settings.controllerContext,
                    reasoningEffort: settings.controllerReasoning,
                    schema: Schemas.guide,
                    jobID: job.id,
                    role: "主控",
                    validate: { Self.plannerValidationError($0) },
                    onEvent: onEvent
                )
                job.totalTokens += parsed.promptTokens + parsed.completionTokens
                job.controllerTokens += parsed.promptTokens + parsed.completionTokens
                let updatedGuide = mergeGuide(existing: guide, update: parsed.value, source: window.text, sectionIDs: Set(window.sections.map(\.id)))
                let evidence = PlannerWindowEvidence(
                    id: "\(fileIndex):\(window.startOffset)-\(window.endOffset)",
                    fileIndex: fileIndex,
                    fileName: file.name,
                    startOffset: window.startOffset,
                    endOffset: window.endOffset,
                    sectionIDs: window.sections.map(\.id),
                    sourceDigest: digest(window.text)
                )
                completedWindows.append(evidence)
                guide = updatedGuide
                let nextFile = window.endOffset == characters.count ? fileIndex + 1 : fileIndex
                let nextOffset = nextFile == fileIndex ? window.endOffset : 0
                checkpoint = PlannerCheckpoint(
                    sourceDigest: sourceDigest,
                    configurationDigest: configurationDigest,
                    nextFileIndex: nextFile,
                    nextOffset: nextOffset,
                    mergedGuide: updatedGuide,
                    completedWindows: completedWindows
                )
                job.plannerCheckpoint = checkpoint
                storeAgentSnapshot(
                    AgentOutputSnapshot(role: "planner", windowIndex: windowIndex, rawJSON: parsed.rawJSON, structuredJSON: parsed.structuredJSON),
                    in: &job
                )
                job.updatedAt = .now
                try await store.save(job)
                onEvent(.snapshot(jobID: job.id, role: "主控"))
                offset = window.endOffset
            }
        }
        guard var finalGuide = guide else { throw TranslationPipelineError.missingGuide }
        if finalGuide.sourceLanguage.isEmpty || finalGuide.sourceLanguage == "auto" { finalGuide.sourceLanguage = detectLanguage(allText) }
        if finalGuide.genre.isEmpty { finalGuide.genre = settings.genre }
        if finalGuide.titleZh.isEmpty { finalGuide.titleZh = job.name }
        job.guide = finalGuide
        job.memory = emptyMemory
        try await store.save(job)
    }

    private func plannerWindow(fileIndex: Int, fileName: String, characters: [Character], startOffset: Int, existing: TranslationGuide?, sections: [DocumentSection], windowIndex: Int, settings: AppSettings) throws -> PlannerWindow {
        let outputReservation = min(8_000, max(1_024, settings.controllerContext / 4))
        var endOffset = min(characters.count, startOffset + max(1, settings.controllerContext / 2))
        var windowSections: [DocumentSection] = []
        for _ in 0..<64 {
            windowSections = sections.filter { $0.isExplicit && $0.startOffset < endOffset && $0.endOffset > startOffset }
            let emptyPrompt = PromptBuilder.planner(text: "", windowIndex: windowIndex, existing: existing, settings: settings, fileName: fileName, sections: windowSections)
            let fixedTokens = estimateTokens(emptyPrompt.system + "\n" + emptyPrompt.user)
            let sourceBudget = settings.controllerContext - fixedTokens - outputReservation - 512
            if sourceBudget <= 0 {
                guard endOffset - startOffset > 1 else { throw TranslationPipelineError.plannerContextExceeded }
                endOffset = startOffset + max(1, (endOffset - startOffset) / 2)
                continue
            }
            let candidateEnd = min(characters.count, startOffset + sourceBudget)
            if candidateEnd >= endOffset { break }
            guard candidateEnd > startOffset else { throw TranslationPipelineError.plannerContextExceeded }
            endOffset = candidateEnd
        }
        guard endOffset > startOffset else { throw TranslationPipelineError.plannerContextExceeded }
        let lowerBoundary = startOffset + max(1, (endOffset - startOffset) * 3 / 4)
        if lowerBoundary < endOffset, let newline = (lowerBoundary..<endOffset).last(where: { characters[$0] == "\n" }) {
            endOffset = newline + 1
        }
        windowSections = sections.filter { $0.isExplicit && $0.startOffset < endOffset && $0.endOffset > startOffset }
        let text = String(characters[startOffset..<endOffset])
        let prompt = PromptBuilder.planner(text: text, windowIndex: windowIndex, existing: existing, settings: settings, fileName: fileName, sections: windowSections)
        let promptTokens = estimateTokens(prompt.system + "\n" + prompt.user)
        guard promptTokens + outputReservation + 256 <= settings.controllerContext else { throw TranslationPipelineError.plannerContextExceeded }
        return PlannerWindow(text: text, fileIndex: fileIndex, fileName: fileName, startOffset: startOffset, endOffset: endOffset, sections: windowSections, outputReservation: outputReservation)
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func storeAgentSnapshot(_ snapshot: AgentOutputSnapshot, in job: inout TranslationJob) {
        var snapshots = job.agentOutputSnapshots ?? []
        snapshots.removeAll { $0.role == snapshot.role }
        snapshots.append(snapshot)
        job.agentOutputSnapshots = snapshots
    }

    private func scout(batch: [Int], job: inout TranslationJob, settings: AppSettings, onEvent: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        guard job.guide != nil else { throw TranslationPipelineError.missingGuide }
        let needsScout = batch.filter { job.chunks[$0].status == .pending }
        guard !needsScout.isEmpty else { return }
        try await ModelScheduler.prepare(role: "controller", settings: settings, client: client)
        for index in needsScout {
            try Task.checkCancellation()
            var chunk = job.chunks[index]
            guard let guide = job.guide else { throw TranslationPipelineError.missingGuide }
            chunk.memoryBefore = job.memory
            onEvent(.activity(jobID: job.id, role: "主控", action: "预读第 \(chunk.index + 1)/\(job.chunks.count) 个片段"))
            let prompt = PromptBuilder.scout(chunk: chunk, index: chunk.index + 1, total: job.chunks.count, guide: guide, memory: job.memory, settings: settings)
            let parsed = try await requestJSON(
                ScoutResult.self,
                prompt: prompt,
                model: settings.controllerModel,
                temperature: settings.controllerTemperature,
                maxTokens: 3_000 + settings.memoryMaxCharacters * 2,
                contextLength: settings.controllerContext,
                reasoningEffort: settings.controllerReasoning,
                schema: Schemas.scout(summaryLimit: settings.summaryMaxCharacters, memoryLimit: settings.memoryMaxCharacters),
                jobID: job.id,
                role: "预读",
                onEvent: onEvent
            )
            job.totalTokens += parsed.promptTokens + parsed.completionTokens
            job.controllerTokens += parsed.promptTokens + parsed.completionTokens
            let result = parsed.value
            chunk.summary = String(result.summary.prefix(settings.summaryMaxCharacters))
            storeAgentSnapshot(AgentOutputSnapshot(role: "scout", chunkIndex: chunk.index, rawJSON: parsed.rawJSON, structuredJSON: parsed.structuredJSON), in: &job)
            chunk.translationNotes = Array(result.translationNotes.prefix(3)).map { String($0.prefix(60)) }
            chunk.status = .scouted
            job.chunks[index] = chunk
            mergeNewTerms(result.newTerms, source: chunk.source, into: &job)
            let memory = result.memory.count >= 40 ? result.memory : job.memory
            let bounded = try await boundedMemory(memory, oldMemory: job.memory, settings: settings, jobID: job.id, onEvent: onEvent)
            job.memory = bounded.text
            job.totalTokens += bounded.promptTokens + bounded.completionTokens
            job.controllerTokens += bounded.promptTokens + bounded.completionTokens
            job.memoryHistory.append(MemorySnapshot(afterChunk: chunk.index, text: job.memory))
            job.updatedAt = .now
            try await store.save(job)
            onEvent(.snapshot(jobID: job.id, role: "预读"))
            onEvent(.chunk(jobID: job.id, chunkIndex: chunk.index))
        }
    }

    private func translateAndReview(batch: [Int], job: inout TranslationJob, settings: AppSettings, onEvent: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        var remaining = batch.filter { job.chunks[$0].status == .scouted || job.chunks[$0].status == .translated || job.chunks[$0].status == .reviewed }
        guard !remaining.isEmpty else { return }
        while !remaining.isEmpty {
            try Task.checkCancellation()
            let requiringTranslation = remaining.filter { job.chunks[$0].explicitRetryPending == true || job.chunks[$0].latestAttempt?.review != nil || job.chunks[$0].attempts.isEmpty }
            if !requiringTranslation.isEmpty {
                try await ModelScheduler.prepare(role: "translator", settings: settings, client: client)
                for index in requiringTranslation {
                    try Task.checkCancellation()
                    let chunk = job.chunks[index]
                    let cycleStart = min(chunk.attempts.count, max(0, chunk.retryCycleStartIndex ?? 0))
                    let attemptNumber = max(1, chunk.attempts.count - cycleStart + 1)
                    let temperature = attemptNumber >= 3 ? 0.3 : settings.translatorTemperature
                    let revisions = chunk.latestAttempt?.review?.revisionInstructions ?? []
                    job.chunks[index].status = .translating
                    try await store.save(job)
                    onEvent(.activity(jobID: job.id, role: "翻译模型", action: "翻译第 \(chunk.index + 1)/\(job.chunks.count) 个片段（第\(attemptNumber)次）"))
                    let priorHardFailure = chunk.latestAttempt?.review?.automaticChecks.contains(where: \.hard) == true
                    let translated: (text: String, finishReason: String?, promptTokens: Int, completionTokens: Int)
                    if attemptNumber >= 3, priorHardFailure, chunk.source.count > 2_500 {
                        onEvent(.log(jobID: job.id, message: "第\(chunk.index + 1)段连续出现硬伤，降级为约2500字分段翻译"))
                        translated = try await translateInParts(chunk, guide: job.guide ?? TranslationGuide(), previousTranslation: previousTranslation(for: chunk, in: job), settings: settings, jobID: job.id, revisionInstructions: revisions, onEvent: onEvent)
                    } else {
                        let prompt = PromptBuilder.translator(
                            chunk: chunk,
                            previousTranslation: previousTranslation(for: chunk, in: job),
                            guide: job.guide ?? TranslationGuide(),
                            settings: settings,
                            revisionInstructions: revisions
                        )
                        let response = try await client.chat(
                            model: settings.translatorModel,
                            prompt: prompt,
                            temperature: temperature,
                            maxTokens: TranslationOutputBudget.maxTokens(source: chunk.source, provider: settings.provider),
                            contextLength: settings.translatorContext,
                            reasoningEffort: "none",
                            onDelta: streamHandler(jobID: job.id, role: "翻译模型", onEvent: onEvent)
                        )
                        translated = (response.content.trimmingCharacters(in: .whitespacesAndNewlines), response.finishReason, response.promptTokens, response.completionTokens)
                    }
                    job.totalTokens += translated.promptTokens + translated.completionTokens
                    job.translatorTokens += translated.promptTokens + translated.completionTokens
                    job.chunks[index].attempts.append(TranslationAttempt(translation: translated.text, temperature: temperature, finishReason: translated.finishReason))
                    job.chunks[index].explicitRetryPending = nil
                    job.chunks[index].status = .translated
                    job.updatedAt = .now
                    try await store.save(job)
                    onEvent(.chunk(jobID: job.id, chunkIndex: chunk.index))
                }
            }

            try await ModelScheduler.prepare(role: "controller", settings: settings, client: client)
            var retry: [Int] = []
            for index in remaining {
                try Task.checkCancellation()
                let chunk = job.chunks[index]
                guard chunk.latestAttempt?.review == nil else { continue }
                guard let attemptIndex = chunk.attempts.indices.last else { continue }
                let attempt = chunk.attempts[attemptIndex]
                job.chunks[index].status = .reviewing
                onEvent(.activity(jobID: job.id, role: "审校", action: "评审第 \(chunk.index + 1)/\(job.chunks.count) 个片段"))
                let previous = previousTranslation(for: chunk, in: job)
                let guide = job.guide ?? TranslationGuide()
                let report = TranslationQuality.inspect(
                    source: chunk.source,
                    translation: attempt.translation,
                    sourceLanguage: guide.sourceLanguage,
                    targetLanguage: settings.targetLanguage,
                    glossary: PromptBuilder.relevantGlossary(in: chunk.source, guide: guide),
                    previousTranslation: previous,
                    finishReason: attempt.finishReason
                )
                let review: TranslationReview
                if !report.hardFailures.isEmpty {
                    review = TranslationQuality.fallbackReview(for: report)
                } else {
                    let prompt = PromptBuilder.reviewer(chunk: chunk, translation: attempt.translation, guide: guide, settings: settings, qualityFindings: report.findings)
                    do {
                        let parsed = try await requestJSON(
                            ReviewerResponse.self,
                            prompt: prompt,
                            model: settings.controllerModel,
                            temperature: settings.controllerTemperature,
                            maxTokens: 5_000,
                            contextLength: settings.controllerContext,
                            reasoningEffort: settings.controllerReasoning,
                            schema: Schemas.reviewer,
                            jobID: job.id,
                            role: "审校",
                            onEvent: onEvent
                        )
                        job.totalTokens += parsed.promptTokens + parsed.completionTokens
                        job.controllerTokens += parsed.promptTokens + parsed.completionTokens
                        let payload = parsed.value
                        storeAgentSnapshot(AgentOutputSnapshot(role: "reviewer", chunkIndex: chunk.index, rawJSON: parsed.rawJSON, structuredJSON: parsed.structuredJSON), in: &job)
                        let score = max(0, min(100, payload.scores.weighted - report.penalty))
                        review = TranslationReview(
                            scores: payload.scores,
                            issues: Array(payload.issues.prefix(8)),
                            revisionInstructions: Array(payload.revisionInstructions.prefix(4)).map { String($0.prefix(60)) },
                            verdict: payload.verdict,
                            comment: payload.comment,
                            automaticChecks: report.findings,
                            score: score,
                            modelReviewed: true
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        review = TranslationQuality.fallbackReview(for: report)
                    }
                }
                job.chunks[index].attempts[attemptIndex].review = review
                let cycleStart = min(job.chunks[index].attempts.count, max(0, job.chunks[index].retryCycleStartIndex ?? 0))
                let passed = report.hardFailures.isEmpty && review.verdict == "pass" && review.score >= settings.passScore
                if passed {
                    job.chunks[index].finalTranslation = attempt.translation
                    job.chunks[index].reviewScore = review.score
                    job.chunks[index].status = .done
                    job.chunks[index].needsHumanReview = false
                } else {
                    if let best = bestAttempt(for: job.chunks[index], startingAt: cycleStart) {
                        job.chunks[index].finalTranslation = best.translation
                        job.chunks[index].reviewScore = best.review?.score
                    }
                    if attemptIndex - cycleStart < settings.maxRetries {
                        job.chunks[index].status = .scouted
                        retry.append(index)
                    } else {
                        job.chunks[index].status = .flagged
                        job.chunks[index].needsHumanReview = true
                    }
                }
                job.updatedAt = .now
                try await store.save(job)
                onEvent(.snapshot(jobID: job.id, role: "审校"))
                onEvent(.chunk(jobID: job.id, chunkIndex: chunk.index))
            }
            remaining = retry
        }
    }

    private func boundedMemory(_ memory: String, oldMemory: String, settings: AppSettings, jobID: UUID, onEvent: @escaping @Sendable (PipelineEvent) -> Void) async throws -> (text: String, promptTokens: Int, completionTokens: Int) {
        guard memory.count > settings.memoryMaxCharacters else { return (memory, 0, 0) }
        onEvent(.activity(jobID: jobID, role: "主控", action: "压缩剧情记忆"))
        let prompt = PromptBuilder.memoryCompression(memory, limit: settings.memoryMaxCharacters)
        let response: ChatResult
        do {
            response = try await client.chat(
                model: settings.controllerModel,
                prompt: prompt,
                temperature: settings.controllerTemperature,
                maxTokens: settings.memoryMaxCharacters * 2,
                contextLength: settings.controllerContext,
                reasoningEffort: settings.controllerReasoning,
                onDelta: streamHandler(jobID: jobID, role: "主控", onEvent: onEvent)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return (truncateMemory(memory, limit: settings.memoryMaxCharacters), 0, 0)
        }
        let compressed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if compressed.count <= settings.memoryMaxCharacters {
            return (compressed, response.promptTokens, response.completionTokens)
        }
        let clipped = truncateMemory(compressed, limit: settings.memoryMaxCharacters)
        onEvent(.log(jobID: jobID, message: "记忆压缩后仍超限，已按行截断"))
        return (clipped.isEmpty ? oldMemory : clipped, response.promptTokens, response.completionTokens)
    }

    private func translateInParts(
        _ chunk: TranslationChunk,
        guide: TranslationGuide,
        previousTranslation: String,
        settings: AppSettings,
        jobID: UUID,
        revisionInstructions: [String],
        onEvent: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws -> (text: String, finishReason: String?, promptTokens: Int, completionTokens: Int) {
        let parts = TextChunker.makeChunks(fileIndex: chunk.fileIndex, fileName: chunk.fileName, text: chunk.source, maxCharacters: 2_500, contextCharacters: settings.contextCharacters)
        var promptTokens = 0
        var completionTokens = 0
        var finishReason: String?
        var translatedParts: [String] = []
        for (index, originalPart) in parts.enumerated() {
            try Task.checkCancellation()
            var part = originalPart
            part.summary = chunk.summary
            part.memoryBefore = chunk.memoryBefore
            part.translationNotes = chunk.translationNotes
            part.previousTail = index == 0 ? chunk.previousTail : String(parts[index - 1].source.suffix(settings.contextCharacters))
            part.nextHead = index + 1 == parts.count ? chunk.nextHead : String(parts[index + 1].source.prefix(settings.contextCharacters))
            let prompt = PromptBuilder.translator(chunk: part, previousTranslation: previousTranslation, guide: guide, settings: settings, revisionInstructions: revisionInstructions)
            let response = try await client.chat(
                model: settings.translatorModel,
                prompt: prompt,
                temperature: 0.3,
                maxTokens: TranslationOutputBudget.maxTokens(source: part.source, provider: settings.provider),
                contextLength: settings.translatorContext,
                reasoningEffort: "none",
                onDelta: streamHandler(jobID: jobID, role: "翻译模型", onEvent: onEvent)
            )
            translatedParts.append(response.content)
            promptTokens += response.promptTokens
            completionTokens += response.completionTokens
            if response.finishReason == "length" {
                finishReason = "length"
            } else if finishReason != "length" {
                finishReason = response.finishReason
            }
        }
        return (Self.reassembleFallbackTranslations(parts: parts, translations: translatedParts), finishReason, promptTokens, completionTokens)
    }

    static func reassembleFallbackTranslations(parts: [TranslationChunk], translations: [String]) -> String {
        zip(parts, translations).map { part, translation in
            part.leadingWhitespace + translation.trimmingCharacters(in: .whitespacesAndNewlines) + part.trailingWhitespace
        }.joined()
    }

    private func persist(_ job: TranslationJob, event: String, onEvent: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        var job = job
        job.updatedAt = .now
        try await store.save(job)
        try await store.appendLog(jobID: job.id, message: event)
        onEvent(.status(jobID: job.id, message: event))
        onEvent(.log(jobID: job.id, message: event))
    }

    private func streamHandler(jobID: UUID, role: String, onEvent: @escaping @Sendable (PipelineEvent) -> Void) -> @Sendable (String, String) -> Void {
        { kind, text in onEvent(.stream(jobID: jobID, role: role, kind: kind, text: text)) }
    }

    private func mergeGuide(existing: TranslationGuide?, update: TranslationGuide, source: String, sectionIDs: Set<String>) -> TranslationGuide {
        var result = existing ?? update
        if existing == nil { result.sections = [] }
        result.titleZh = firstNonempty(result.titleZh, update.titleZh)
        result.sourceLanguage = firstNonempty(result.sourceLanguage, update.sourceLanguage)
        result.genre = update.genre.isEmpty ? result.genre : update.genre
        result.synopsis = mergeDistinctText(result.synopsis, update.synopsis)
        result.style = TranslationStyle(
            narration: mergeDistinctText(result.style.narration, update.style.narration),
            tone: mergeDistinctText(result.style.tone, update.style.tone),
            diction: mergeDistinctText(result.style.diction, update.style.diction),
            dialogue: mergeDistinctText(result.style.dialogue, update.style.dialogue),
            punctuation: mergeDistinctText(result.style.punctuation, update.style.punctuation)
        )
        for rule in update.rules where !rule.isEmpty && !result.rules.contains(rule) { result.rules.append(rule) }
        for character in update.characters where !character.source.isEmpty && containsSource(character.source, in: source) {
            guard let index = result.characters.firstIndex(where: { $0.source.caseInsensitiveCompare(character.source) == .orderedSame }) else {
                var newCharacter = character
                newCharacter.aliases = character.aliases.filter { containsSource($0.source, in: source) }
                result.characters.append(newCharacter)
                continue
            }
            var stored = result.characters[index]
            if stored.target.isEmpty { stored.target = character.target }
            if stored.gender == "未知" && character.gender != "未知" { stored.gender = character.gender }
            stored.role = mergeDistinctText(stored.role, character.role)
            stored.voice = mergeDistinctText(stored.voice, character.voice)
            for alias in character.aliases where containsSource(alias.source, in: source) {
                if let aliasIndex = stored.aliases.firstIndex(where: { $0.source.caseInsensitiveCompare(alias.source) == .orderedSame }) {
                    if stored.aliases[aliasIndex].target.isEmpty { stored.aliases[aliasIndex].target = alias.target }
                } else {
                    stored.aliases.append(alias)
                }
            }
            result.characters[index] = stored
        }
        for term in update.terms where !term.source.isEmpty && containsSource(term.source, in: source) {
            guard let index = result.terms.firstIndex(where: { $0.source.caseInsensitiveCompare(term.source) == .orderedSame }) else {
                result.terms.append(term)
                continue
            }
            if result.terms[index].target.isEmpty { result.terms[index].target = term.target }
            if result.terms[index].category == "其他" && term.category != "其他" { result.terms[index].category = term.category }
            result.terms[index].note = mergeDistinctText(result.terms[index].note, term.note)
        }
        for section in update.sections where sectionIDs.contains(section.sectionID) && !section.evidence.isEmpty && source.contains(section.evidence) {
            guard let index = result.sections.firstIndex(where: { $0.sectionID == section.sectionID }) else {
                result.sections.append(section)
                continue
            }
            result.sections[index].sourceTitle = firstNonempty(result.sections[index].sourceTitle, section.sourceTitle)
            result.sections[index].sectionType = mergeDistinctText(result.sections[index].sectionType, section.sectionType)
            result.sections[index].summary = mergeDistinctText(result.sections[index].summary, section.summary)
            result.sections[index].evidence = mergeDistinctText(result.sections[index].evidence, section.evidence)
        }
        return result
    }

    private func firstNonempty(_ existing: String, _ update: String) -> String {
        existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? update : existing
    }

    private func mergeDistinctText(_ existing: String, _ update: String) -> String {
        let oldValue = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = update.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newValue.isEmpty else { return existing }
        guard !oldValue.isEmpty else { return update }
        if oldValue == newValue || oldValue.contains(newValue) { return existing }
        if newValue.contains(oldValue) { return update }
        return existing + "\n" + update
    }

    private func mergeNewTerms(_ terms: [GlossaryEntry], source: String, into job: inout TranslationJob) {
        guard var guide = job.guide else { return }
        for term in terms where !term.source.isEmpty && containsSource(term.source, in: source) {
            if !guide.terms.contains(where: { $0.source.caseInsensitiveCompare(term.source) == .orderedSame })
                && !guide.characters.contains(where: { $0.source.caseInsensitiveCompare(term.source) == .orderedSame }) {
                guide.terms.append(term)
            }
        }
        job.guide = guide
    }

    private func containsSource(_ term: String, in source: String) -> Bool {
        TranslationTextMetrics.containsSource(term, in: source)
    }

    private func previousTranslation(for chunk: TranslationChunk, in job: TranslationJob) -> String {
        guard let previous = job.chunks.filter({ $0.fileIndex == chunk.fileIndex && $0.index < chunk.index }).max(by: { $0.index < $1.index }) else { return "" }
        return previous.finalTranslation.isEmpty ? (previous.latestAttempt?.translation ?? "") : previous.finalTranslation
    }

    private func bestAttempt(for chunk: TranslationChunk, startingAt index: Int) -> TranslationAttempt? {
        chunk.attempts.dropFirst(index).max { ($0.review?.score ?? -1) < ($1.review?.score ?? -1) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: String) throws -> T {
        var value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```"), let firstNewline = value.firstIndex(of: "\n"), let fence = value.range(of: "```", options: .backwards), fence.lowerBound > firstNewline {
            value = String(value[value.index(after: firstNewline)..<fence.lowerBound])
        }
        guard let data = value.data(using: .utf8) else { throw LMStudioError.invalidResponse }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func plannerValidationError(_ guide: TranslationGuide) -> String? {
        let requiredFields: [(String, String)] = [
            ("title_zh", guide.titleZh),
            ("source_language", guide.sourceLanguage),
            ("genre", guide.genre),
            ("synopsis", guide.synopsis),
            ("style.narration", guide.style.narration),
            ("style.tone", guide.style.tone),
            ("style.diction", guide.style.diction),
            ("style.dialogue", guide.style.dialogue),
            ("style.punctuation", guide.style.punctuation)
        ]
        let missing = requiredFields.filter { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.0)
        if !missing.isEmpty { return "以下必填字段必须有实质内容：\(missing.joined(separator: ", "))。" }
        let ruleCount = guide.rules.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        guard (3...8).contains(ruleCount) else { return "rules 必须包含 3 至 8 条非空翻译守则。" }
        return nil
    }

    private func requestJSON<T: Codable>(
        _ type: T.Type,
        prompt: ChatPrompt,
        model: String,
        temperature: Double,
        maxTokens: Int,
        contextLength: Int,
        reasoningEffort: String,
        schema: [String: Any],
        jobID: UUID,
        role: String,
        validate: ((T) -> String?)? = nil,
        onEvent: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws -> (value: T, promptTokens: Int, completionTokens: Int, rawJSON: String, structuredJSON: String) {
        var retryPrompt = prompt
        var promptTokens = 0
        var completionTokens = 0
        var lastError: Error = LMStudioError.invalidResponse
        for attempt in 0..<3 {
            do {
                let response = try await client.chat(
                    model: model,
                    prompt: retryPrompt,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    contextLength: contextLength,
                    reasoningEffort: reasoningEffort,
                    responseSchema: schema,
                    onDelta: streamHandler(jobID: jobID, role: role, onEvent: onEvent)
                )
                promptTokens += response.promptTokens
                completionTokens += response.completionTokens
                do {
                    let value = try decode(type, response.content)
                    if let validationError = validate?(value) {
                        lastError = LMStudioError.invalidResponse
                        if attempt < 2 {
                            retryPrompt.user += "\n上一次 JSON 虽然语法可解析，但内容不符合规划要求：\(validationError)请修正后重新输出完整 JSON。"
                        }
                        continue
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    let structuredJSON = String(decoding: try encoder.encode(value), as: UTF8.self)
                    return (value, promptTokens, completionTokens, response.content, structuredJSON)
                } catch {
                    lastError = error
                    if attempt < 2 {
                        retryPrompt.user += "\n上一次响应不是符合结构的 JSON，请严格按 JSON Schema 重新输出，不要使用 Markdown 代码块。"
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if case LMStudioError.http(let status, _) = error, status == 401 || status == 403 { throw error }
                if case LMStudioError.emptyCompletion = error { throw error }
                if case LMStudioError.providerStreamError = error { throw error }
                lastError = error
                if attempt < 2 { retryPrompt.user += "\n请重试上一个任务并只输出要求的结果。" }
            }
        }
        throw lastError
    }

    private func estimateTokens(_ text: String) -> Int {
        TranslationTextMetrics.estimatedTokens(text)
    }

    private func detectLanguage(_ text: String) -> String {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { (0x3040...0x30FF).contains(Int($0.value)) }) { return "日语" }
        if scalars.contains(where: { (0xAC00...0xD7AF).contains(Int($0.value)) }) { return "韩语" }
        if scalars.filter({ CharacterSet.letters.contains($0) }).count > scalars.count / 2 { return "英语" }
        return "未知语言"
    }

    private func truncateMemory(_ memory: String, limit: Int) -> String {
        var lines = memory.components(separatedBy: "\n")
        while lines.joined(separator: "\n").count > limit, lines.count > 1 { lines.remove(at: min(2, lines.count - 1)) }
        let remaining = lines.joined(separator: "\n")
        return String(remaining.prefix(limit))
    }

    private var emptyMemory: String {
        "# 剧情记忆\n## 主线进展\n- 暂无\n## 人物状态\n- 暂无\n## 伏笔与悬念\n- 暂无\n## 最新进展\n暂无"
    }
}

private enum Schemas {
    static let guide: [String: Any] = [
        "name": "translation_guide",
        "strict": true,
        "schema": [
            "type": "object",
            "properties": [
                "title_zh": string, "source_language": string, "genre": string, "synopsis": ["type": "string", "maxLength": 300],
                "style": ["type": "object", "properties": ["narration": string, "tone": string, "diction": string, "dialogue": string, "punctuation": string], "required": ["narration", "tone", "diction", "dialogue", "punctuation"], "additionalProperties": false],
                "characters": ["type": "array", "items": ["type": "object", "properties": ["source": string, "target": string, "gender": ["type": "string", "enum": ["男", "女", "未知"]], "role": string, "voice": string, "aliases": ["type": "array", "items": ["type": "object", "properties": ["source": string, "target": string], "required": ["source", "target"], "additionalProperties": false]]], "required": ["source", "target", "gender", "role", "voice", "aliases"], "additionalProperties": false]],
                "terms": termArray,
                "rules": ["type": "array", "items": string, "minItems": 3, "maxItems": 8],
                "sections": ["type": "array", "items": ["type": "object", "properties": [
                    "section_id": string, "source_title": string, "section_type": string, "summary": string, "evidence": string
                ], "required": ["section_id", "source_title", "section_type", "summary", "evidence"], "additionalProperties": false]]
            ],
            "required": ["title_zh", "source_language", "genre", "synopsis", "style", "characters", "terms", "rules", "sections"],
            "additionalProperties": false
        ]
    ]

    static func scout(summaryLimit: Int, memoryLimit: Int) -> [String: Any] {
        ["name": "scout_result", "strict": true,
        "schema": ["type": "object", "properties": [
            "summary": ["type": "string", "maxLength": summaryLimit],
            "new_terms": termArray,
            "translation_notes": ["type": "array", "items": ["type": "string", "maxLength": 60], "maxItems": 3],
            "memory": ["type": "string", "maxLength": memoryLimit]
        ], "required": ["summary", "new_terms", "translation_notes", "memory"], "additionalProperties": false]]
    }

    static let reviewer: [String: Any] = [
        "name": "translation_review", "strict": true,
        "schema": ["type": "object", "properties": [
            "scores": ["type": "object", "properties": ["accuracy": integer, "completeness": integer, "terminology": integer, "fluency": integer, "style": integer], "required": ["accuracy", "completeness", "terminology", "fluency", "style"], "additionalProperties": false],
            "issues": ["type": "array", "maxItems": 8, "items": ["type": "object", "properties": ["type": ["type": "string", "enum": ["误译", "漏译", "增译", "术语", "风格", "语病", "越界"]], "severity": ["type": "string", "enum": ["严重", "一般", "轻微"]], "source": ["type": "string", "maxLength": 60], "translation": ["type": "string", "maxLength": 60], "suggestion": string], "required": ["type", "severity", "source", "translation", "suggestion"], "additionalProperties": false]],
            "revision_instructions": ["type": "array", "items": ["type": "string", "maxLength": 60], "minItems": 0, "maxItems": 4],
            "verdict": ["type": "string", "enum": ["pass", "revise"]],
            "comment": string
        ], "required": ["scores", "issues", "revision_instructions", "verdict", "comment"], "additionalProperties": false]
    ]

    private static let string: [String: Any] = ["type": "string"]
    private static let integer: [String: Any] = ["type": "integer", "minimum": 0, "maximum": 10]
    private static let termArray: [String: Any] = ["type": "array", "items": ["type": "object", "properties": ["source": string, "target": string, "category": ["type": "string", "enum": ["人名", "地名", "组织", "物品", "术语", "称谓", "其他"]], "note": string], "required": ["source", "target", "category", "note"], "additionalProperties": false]]
}
