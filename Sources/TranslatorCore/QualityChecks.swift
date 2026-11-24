import Foundation

public struct QualityReport: Sendable {
    public var findings: [QualityFinding]
    public var hardFailures: [QualityFinding]
    public var penalty: Int

    public init(findings: [QualityFinding]) {
        self.findings = findings
        self.hardFailures = findings.filter(\.hard)
        self.penalty = min(35, findings.reduce(0) { $0 + $1.penalty })
    }
}

public enum TranslationQuality {
    public static func inspect(
        source: String,
        translation: String,
        sourceLanguage: String,
        glossary: [GlossaryEntry],
        previousTranslation: String,
        finishReason: String? = nil
    ) -> QualityReport {
        var findings: [QualityFinding] = []
        if translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(.init(message: "译文为空", hard: true))
        }
        if finishReason == "length" {
            findings.append(.init(message: "输出达到token上限，译文可能截断", hard: true))
        }
        let leaks = ["【源文】", "【约束要求】", "【硬性要求】", "【注意】"]
        if leaks.contains(where: translation.contains) {
            findings.append(.init(message: "译文含有提示词泄漏", hard: true))
        }
        if hasRepeatedRun(translation) {
            findings.append(.init(message: "译文含有连续重复文本", hard: true))
        }
        let language = inferLanguage(source: source, requested: sourceLanguage)
        if source.count >= 200 {
            let ratio = Double(translation.count) / Double(max(1, source.count))
            let bounds: ClosedRange<Double> = switch language {
            case .japanese: 0.4...1.4
            case .korean: 0.35...1.4
            case .english: 0.18...0.8
            case .other: 0.18...1.4
            }
            if !bounds.contains(ratio) {
                findings.append(.init(message: String(format: "译文长度比异常（%.2f，期望 %.2f–%.2f）", ratio, bounds.lowerBound, bounds.upperBound), hard: true))
            }
            let foreignRatio = residualScriptRatio(translation, language: language)
            if foreignRatio > (language == .japanese || language == .korean ? 0.02 : 0.20) {
                findings.append(.init(message: String(format: "残留原文字符比例过高（%.1f%%）", foreignRatio * 100), hard: true))
            }
        }
        let sourceParagraphs = paragraphCount(source)
        let translatedParagraphs = paragraphCount(translation)
        if abs(sourceParagraphs - translatedParagraphs) > max(2, Int(Double(sourceParagraphs) * 0.15)) {
            findings.append(.init(message: "段落数不一致：原文\(sourceParagraphs)段，译文\(translatedParagraphs)段", penalty: 5))
        }
        var missingTerms = 0
        for entry in glossary where containsTerm(entry.source, in: source) && !translation.localizedCaseInsensitiveContains(entry.target) {
            missingTerms += 1
            if missingTerms <= 4 {
                findings.append(.init(message: "术语缺失：\(entry.source) 应译为 \(entry.target)", penalty: 5))
            }
        }
        if missingTerms > 4 {
            let penalty = max(0, min(20, missingTerms * 5) - min(20, 4 * 5))
            findings.append(.init(message: "另有\(missingTerms - 4)条术语未命中", penalty: penalty))
        }
        if longestCommonSubstring(String(translation.prefix(300)), String(previousTranslation.suffix(300))) >= 25 {
            findings.append(.init(message: "译文开头与上一片段译文末尾重复，可能越界", penalty: 10))
        }
        return QualityReport(findings: findings)
    }

    public static func fallbackReview(for report: QualityReport) -> TranslationReview {
        let instructions = report.hardFailures.prefix(4).map { "修复硬伤：\($0.message)" }
        return TranslationReview(
            scores: ReviewScores(accuracy: 6, completeness: 6, terminology: 6, fluency: 6, style: 6),
            issues: report.findings.map { ReviewIssue(type: "质检", severity: $0.hard ? "严重" : "一般", suggestion: $0.message) },
            revisionInstructions: instructions,
            verdict: report.hardFailures.isEmpty ? "pass" : "revise",
            comment: "模型评审不可用，采用自动质检降级评分。",
            automaticChecks: report.findings,
            score: report.hardFailures.isEmpty ? max(0, 85 - report.penalty) : 30,
            modelReviewed: false
        )
    }

    private enum SourceLanguage {
        case japanese, korean, english, other
    }

    private static func inferLanguage(source: String, requested: String) -> SourceLanguage {
        let normalized = requested.lowercased()
        if normalized.contains("日") || normalized == "ja" { return .japanese }
        if normalized.contains("韩") || normalized == "ko" { return .korean }
        if normalized.contains("英") || normalized == "en" { return .english }
        let scalars = source.unicodeScalars
        let japanese = scalars.filter { (0x3040...0x30FF).contains(Int($0.value)) }.count
        let korean = scalars.filter { (0xAC00...0xD7AF).contains(Int($0.value)) }.count
        if japanese > 0 { return .japanese }
        if korean > 0 { return .korean }
        if scalars.filter({ CharacterSet.letters.contains($0) }).count > scalars.count / 2 { return .english }
        return .other
    }

    private static func residualScriptRatio(_ translation: String, language: SourceLanguage) -> Double {
        let scalars = Array(translation.unicodeScalars)
        guard !scalars.isEmpty else { return 0 }
        let residue = scalars.filter { scalar in
            switch language {
            case .japanese: (0x3040...0x30FF).contains(Int(scalar.value))
            case .korean: (0xAC00...0xD7AF).contains(Int(scalar.value))
            case .english, .other: CharacterSet.letters.contains(scalar) && (0x0000...0x024F).contains(Int(scalar.value))
            }
        }.count
        return Double(residue) / Double(scalars.count)
    }

    private static func paragraphCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    private static func containsTerm(_ term: String, in text: String) -> Bool {
        guard !term.isEmpty else { return false }
        if term.unicodeScalars.contains(where: CharacterSet.letters.contains) {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: term))\\b"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
            return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        return text.localizedCaseInsensitiveContains(term)
    }

    private static func hasRepeatedRun(_ text: String) -> Bool {
        let pattern = "(?s)(.{12,80})\\1{4,}"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func longestCommonSubstring(_ left: String, _ right: String) -> Int {
        let a = Array(left)
        let b = Array(right)
        var previous = Array(repeating: 0, count: b.count + 1)
        var longest = 0
        for character in a {
            var current = Array(repeating: 0, count: b.count + 1)
            for index in b.indices where character == b[index] {
                current[index + 1] = previous[index] + 1
                longest = max(longest, current[index + 1])
            }
            previous = current
        }
        return longest
    }
}
