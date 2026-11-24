import Foundation

public enum TranslationTextMetrics {
    public static func estimatedTokens(_ text: String) -> Int {
        let scalars = Array(text.unicodeScalars)
        let cjkCount = scalars.filter(isCJKScript).count
        let otherCount = scalars.count - cjkCount
        return max(1, cjkCount + Int(Double(otherCount) * 0.3))
    }

    public static func containsSource(_ term: String, in text: String) -> Bool {
        guard !term.isEmpty else { return false }
        guard containsWesternLetters(term) else { return text.localizedCaseInsensitiveContains(term) }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: term))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func containsWesternLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x0041...0x005A).contains(value)
                || (0x0061...0x007A).contains(value)
                || (0x00C0...0x024F).contains(value)
                || (0x1E00...0x1EFF).contains(value)
        }
    }

    private static func isCJKScript(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x3000...0x303F).contains(value)
            || (0x3040...0x30FF).contains(value)
            || (0x3100...0x312F).contains(value)
            || (0x31F0...0x31FF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFF66...0xFF9D).contains(value)
            || (0x1100...0x11FF).contains(value)
            || (0xA960...0xA97F).contains(value)
            || (0xD7B0...0xD7FF).contains(value)
            || (0x20000...0x323AF).contains(value)
    }
}
