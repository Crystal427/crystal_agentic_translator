import Foundation

public enum WorkspaceDiaryLevel: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case error
}

public enum WorkspaceDiaryCategory: String, Codable, CaseIterable, Sendable {
    case app
    case connection
    case importing
    case settings
    case queue
    case pipeline
}

public struct WorkspaceDiaryEntry: Codable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var level: WorkspaceDiaryLevel
    public var category: WorkspaceDiaryCategory
    public var jobID: UUID?
    public var message: String

    public init(id: UUID = UUID(), timestamp: Date = .now, level: WorkspaceDiaryLevel, category: WorkspaceDiaryCategory, jobID: UUID? = nil, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.jobID = jobID
        self.message = WorkspaceDiaryStore.redact(message)
    }
}

public actor WorkspaceDiaryStore {
    private let rootURL: URL
    private let byteLimit: Int
    private let rotationCount: Int
    private let fileManager: FileManager

    public init(rootURL: URL, byteLimit: Int = 2_000_000, rotationCount: Int = 3, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.byteLimit = max(4_096, byteLimit)
        self.rotationCount = max(1, rotationCount)
        self.fileManager = fileManager
    }

    public func append(level: WorkspaceDiaryLevel, category: WorkspaceDiaryCategory, jobID: UUID? = nil, message: String) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let url = diaryURL(suffix: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(WorkspaceDiaryEntry(level: level, category: category, jobID: jobID, message: message))
        line.append(0x0A)
        let existingSize = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if existingSize + line.count > byteLimit { try rotate() }
        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    public func load(limit: Int = 2_000) throws -> [WorkspaceDiaryEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [WorkspaceDiaryEntry] = []
        for index in stride(from: rotationCount, through: 1, by: -1) {
            let url = diaryURL(suffix: index)
            guard let data = try? Data(contentsOf: url) else { continue }
            entries.append(contentsOf: decodeLines(data, decoder: decoder))
        }
        if let data = try? Data(contentsOf: diaryURL(suffix: nil)) {
            entries.append(contentsOf: decodeLines(data, decoder: decoder))
        }
        return Array(entries.sorted { $0.timestamp < $1.timestamp }.suffix(max(1, limit)))
    }

    public static func redact(_ message: String) -> String {
        var value = message
        let patterns = [
            ("(?i)(bearer\\s+)[A-Za-z0-9._~+/-]+=*", "$1[REDACTED]"),
            ("(?i)(api[_ -]?key\\s*[:=]\\s*)[^\\s,;]+", "$1[REDACTED]"),
            ("[A-Fa-f0-9]{24,}\\.[A-Za-z0-9_+/=-]{12,}", "[REDACTED]"),
            ("(?i)\\b(?:sk|glm|zhipu)[-_][A-Za-z0-9_-]{16,}\\b", "[REDACTED]")
        ]
        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
        }
        return String(value.prefix(2_000))
    }

    private func rotate() throws {
        for index in stride(from: rotationCount, through: 1, by: -1) {
            let source = diaryURL(suffix: index == 1 ? nil : index - 1)
            let destination = diaryURL(suffix: index)
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            if fileManager.fileExists(atPath: source.path) { try fileManager.moveItem(at: source, to: destination) }
        }
    }

    private func decodeLines(_ data: Data, decoder: JSONDecoder) -> [WorkspaceDiaryEntry] {
        data.split(separator: 0x0A).compactMap { try? decoder.decode(WorkspaceDiaryEntry.self, from: Data($0)) }
    }

    private func diaryURL(suffix: Int?) -> URL {
        rootURL.appendingPathComponent("workspace-diary" + (suffix.map { ".\($0)" } ?? "") + ".jsonl")
    }
}
