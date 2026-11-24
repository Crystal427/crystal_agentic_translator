import Foundation

public actor JobStore {
    public nonisolated let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrystalAgenticTranslator", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func loadSettings() throws -> AppSettings {
        let url = rootURL.appendingPathComponent("settings.json")
        guard fileManager.fileExists(atPath: url.path) else { return AppSettings() }
        return try decoder.decode(AppSettings.self, from: Data(contentsOf: url))
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try write(encoder.encode(settings), to: rootURL.appendingPathComponent("settings.json"))
    }

    public func loadJobs() throws -> [TranslationJob] {
        let jobsURL = rootURL.appendingPathComponent("jobs", isDirectory: true)
        guard fileManager.fileExists(atPath: jobsURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: jobsURL, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.hasDirectoryPath }
            .compactMap { directory in
                let url = directory.appendingPathComponent("job.json")
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                return try decoder.decode(TranslationJob.self, from: Data(contentsOf: url))
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func loadJob(id: UUID) throws -> TranslationJob? {
        let url = jobDirectory(id).appendingPathComponent("job.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(TranslationJob.self, from: Data(contentsOf: url))
    }

    public func save(_ job: TranslationJob) throws {
        let directory = jobDirectory(job.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directory.appendingPathComponent("source", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directory.appendingPathComponent("chunks", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directory.appendingPathComponent("memory", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directory.appendingPathComponent("output", isDirectory: true), withIntermediateDirectories: true)

        try write(encoder.encode(job), to: directory.appendingPathComponent("job.json"))
        for (index, file) in job.sourceFiles.enumerated() {
            let safeName = String(file.name.filter { $0.isLetter || $0.isNumber || " .-_".contains($0) }.prefix(100))
            try write(Data(file.text.utf8), to: directory.appendingPathComponent("source").appendingPathComponent(String(format: "%02d-%@.txt", index + 1, safeName)))
        }
        for chunk in job.chunks {
            try write(encoder.encode(chunk), to: directory.appendingPathComponent("chunks").appendingPathComponent(String(format: "%05d.json", chunk.index + 1)))
        }
        if let guide = job.guide {
            try write(encoder.encode(guide), to: directory.appendingPathComponent("guide.json"))
            try write(Data(guideMarkdown(guide).utf8), to: directory.appendingPathComponent("guide.md"))
        }
        try write(Data(job.memory.utf8), to: directory.appendingPathComponent("memory.md"))
        for snapshot in job.memoryHistory {
            try write(Data(snapshot.text.utf8), to: directory.appendingPathComponent("memory").appendingPathComponent(String(format: "%05d.md", snapshot.afterChunk + 1)))
        }
        for (index, file) in job.sourceFiles.enumerated() {
            let output = mergedOutput(for: job, fileIndex: index)
            let base = URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent
            let safeBase = String(base.filter { $0.isLetter || $0.isNumber || " .-_".contains($0) }.prefix(100))
            let outputName = String(format: "%02d-%@.zh.txt", index + 1, safeBase.isEmpty ? "source" : safeBase)
            try write(Data(output.utf8), to: directory.appendingPathComponent("output").appendingPathComponent(outputName))
        }
    }

    public func deleteJob(id: UUID) throws {
        let directory = jobDirectory(id)
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
    }

    public func appendLog(jobID: UUID, message: String) throws {
        let directory = jobDirectory(jobID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let record: [String: String] = ["timestamp": ISO8601DateFormatter().string(from: .now), "message": message]
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0A)
        let url = directory.appendingPathComponent("events.log")
        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try write(data, to: url)
        }
    }

    public func loadLog(jobID: UUID) throws -> [String] {
        let url = jobDirectory(jobID).appendingPathComponent("events.log")
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        struct LogRecord: Decodable { var timestamp: String; var message: String }
        let data = try Data(contentsOf: url)
        var records: [String] = []
        var buffer = Data()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if buffer.isEmpty && line.isEmpty { continue }
            if !buffer.isEmpty { buffer.append(0x0A) }
            buffer.append(contentsOf: line)
            if let record = try? decoder.decode(LogRecord.self, from: buffer) {
                records.append("\(record.timestamp) \(record.message)")
                buffer.removeAll(keepingCapacity: true)
            }
        }
        return records
    }

    public func output(for job: TranslationJob, fileIndex: Int) -> String {
        mergedOutput(for: job, fileIndex: fileIndex)
    }

    public func output(jobID: UUID, fileIndex: Int) throws -> String? {
        guard let job = try loadJob(id: jobID) else { return nil }
        return mergedOutput(for: job, fileIndex: fileIndex)
    }

    private func mergedOutput(for job: TranslationJob, fileIndex: Int) -> String {
        job.chunks.filter { $0.fileIndex == fileIndex }.sorted { $0.index < $1.index }.map { chunk in
            let body = chunk.finalTranslation.isEmpty ? "【待翻译：片段 \(chunk.index + 1)】" : chunk.finalTranslation
            return chunk.leadingWhitespace + body + chunk.trailingWhitespace
        }.joined()
    }

    private func jobDirectory(_ id: UUID) -> URL {
        rootURL.appendingPathComponent("jobs", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func guideMarkdown(_ guide: TranslationGuide) -> String {
        var lines = ["# \(guide.titleZh)", "", "\(guide.genre)", "", "## 梗概", guide.synopsis, "", "## 文风"]
        lines += ["- 叙述：\(guide.style.narration)", "- 基调：\(guide.style.tone)", "- 用词：\(guide.style.diction)", "- 对话：\(guide.style.dialogue)", "- 标点：\(guide.style.punctuation)", "", "## 人物"]
        lines += guide.characters.map { "- \($0.source) → \($0.target)：\($0.role)；\($0.voice)" }
        lines += ["", "## 专名"] + guide.terms.map { "- \($0.source) → \($0.target)（\($0.category)）" }
        lines += ["", "## 翻译守则"] + guide.rules.enumerated().map { "\($0.offset + 1). \($0.element)" }
        return lines.joined(separator: "\n") + "\n"
    }
}
