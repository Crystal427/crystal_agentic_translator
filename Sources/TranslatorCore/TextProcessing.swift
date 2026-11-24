import Foundation

public enum TextProcessingError: Error, LocalizedError {
    case unsupportedEncoding
    case emptyInput

    public var errorDescription: String? {
        switch self {
        case .unsupportedEncoding: return "The file encoding is not supported. Save the file as UTF-8 or UTF-16 and try again."
        case .emptyInput: return "The source file is empty."
        }
    }
}

public enum TextProcessor {
    public static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return text }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        let shiftJIS = String(data: data, encoding: .shiftJIS)
        if let shiftJIS, shiftJIS.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return shiftJIS }
        if let text = String(data: data, encoding: String.Encoding(rawValue: 0x80000632)) { return text }
        if let shiftJIS { return shiftJIS }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        throw TextProcessingError.unsupportedEncoding
    }

    public static func normalize(_ text: String) -> String {
        let newlines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = newlines.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "[\\t ]+$", with: "", options: .regularExpression)
        }
        let trimmed = lines.joined(separator: "\n")
        return trimmed.replacingOccurrences(of: "\n{5,}", with: "\n\n\n\n", options: .regularExpression)
    }
}

public enum TextChunker {
    public static func detectSections(fileIndex: Int, fileName: String, text: String) -> [DocumentSection] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var markers: [(offset: Int, title: String, marker: String)] = []
        var offset = 0
        for (index, substring) in lines.enumerated() {
            let line = String(substring)
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isSectionHeading(value) || isSectionDivider(value) {
                markers.append((offset, isSectionHeading(value) ? value : "", value))
            }
            offset += line.count + (index < lines.count - 1 ? 1 : 0)
        }
        guard !markers.isEmpty else {
            return [DocumentSection(id: "file-\(fileIndex)-section-0", fileIndex: fileIndex, index: 0, title: "", marker: "", startOffset: 0, endOffset: text.count, isExplicit: false)]
        }
        var sections: [DocumentSection] = []
        if markers[0].offset > 0, !text.prefix(markers[0].offset).allSatisfy(\.isWhitespace) {
            sections.append(DocumentSection(id: "file-\(fileIndex)-section-0", fileIndex: fileIndex, index: 0, title: "", marker: "", startOffset: 0, endOffset: markers[0].offset, isExplicit: false))
        }
        for marker in markers {
            let index = sections.count
            let endOffset = markers.first(where: { $0.offset > marker.offset })?.offset ?? text.count
            sections.append(DocumentSection(id: "file-\(fileIndex)-section-\(index)", fileIndex: fileIndex, index: index, title: marker.title, marker: marker.marker, startOffset: marker.offset, endOffset: endOffset))
        }
        return sections
    }

    public static func makeChunks(fileIndex: Int, fileName: String, text: String, maxCharacters: Int, contextCharacters: Int) -> [TranslationChunk] {
        guard !text.isEmpty else { return [] }
        let limit = max(256, maxCharacters)
        let components = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = components.enumerated().map { index, line in
            String(line) + (index < components.count - 1 ? "\n" : "")
        }
        var rawChunks: [String] = []
        var current = ""

        func appendCurrent() {
            if !current.isEmpty {
                rawChunks.append(current)
                current = ""
            }
        }

        for line in lines where !line.isEmpty {
            if isSectionHeading(line.trimmingCharacters(in: .whitespacesAndNewlines)) || isSectionDivider(line.trimmingCharacters(in: .whitespacesAndNewlines)) {
                appendCurrent()
            }
            for fragment in splitLongLine(line, limit: limit) {
                if current.count + fragment.count > limit {
                    if let breakIndex = sceneBreak(in: current, minimumOffset: Int(Double(limit) * 0.75)) {
                        let prefix = String(current[..<breakIndex])
                        let suffix = String(current[breakIndex...])
                        current = suffix
                        if !prefix.isEmpty { rawChunks.append(prefix) }
                        if current.count + fragment.count > limit { appendCurrent() }
                    } else {
                        appendCurrent()
                    }
                }
                current += fragment
            }
        }
        appendCurrent()

        if rawChunks.count > 1, let last = rawChunks.last, last.count < Int(Double(limit) * 0.20),
           let firstLine = last.components(separatedBy: "\n").first,
           !isSectionHeading(firstLine.trimmingCharacters(in: .whitespacesAndNewlines)),
           !isSectionDivider(firstLine.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let previousIndex = rawChunks.count - 2
            let previous = rawChunks[previousIndex]
            let joined = previous + last
            if joined.count <= limit {
                rawChunks[previousIndex] = joined
                rawChunks.removeLast()
            } else {
                let minimumOffset = max(1, joined.count - limit)
                let maximumOffset = min(limit, joined.count - 1)
                let validSplits = joined.indices.filter { split in
                    let offset = joined.distance(from: joined.startIndex, to: split)
                    guard (minimumOffset...maximumOffset).contains(offset) else { return false }
                    return joined[..<split].contains(where: { !$0.isWhitespace })
                        && joined[split...].contains(where: { !$0.isWhitespace })
                }
                let lineSplits = validSplits.filter { joined[$0] == "\n" }
                let candidates = lineSplits.isEmpty ? validSplits : lineSplits
                let target = joined.count / 2
                if let split = candidates.min(by: {
                    abs(joined.distance(from: joined.startIndex, to: $0) - target)
                        < abs(joined.distance(from: joined.startIndex, to: $1) - target)
                }) {
                    rawChunks[previousIndex] = String(joined[..<split])
                    rawChunks[previousIndex + 1] = String(joined[split...])
                }
            }
        }

        return rawChunks.enumerated().map { index, raw in
            let (leading, bodyAndTrailing) = takeLeadingWhitespace(raw)
            let (body, trailing) = takeTrailingWhitespace(bodyAndTrailing)
            return TranslationChunk(
                index: index,
                fileIndex: fileIndex,
                fileName: fileName,
                source: body,
                leadingWhitespace: leading,
                trailingWhitespace: trailing,
                previousTail: index > 0 ? contextTail(rawChunks[index - 1], count: contextCharacters) : "",
                nextHead: index + 1 < rawChunks.count ? contextHead(rawChunks[index + 1], count: contextCharacters) : ""
            )
        }
    }

    private static func splitLongLine(_ line: String, limit: Int) -> [String] {
        guard line.count > limit else { return [line] }
        let characters = Array(line)
        var result: [String] = []
        var start = 0
        while start < characters.count {
            let remaining = characters.count - start
            if remaining <= limit {
                result.append(String(characters[start...]))
                break
            }
            let upper = start + limit
            let boundary = (start..<upper).last(where: { isSentenceEnding(characters[$0]) && $0 - start > limit / 2 }).map { $0 + 1 } ?? upper
            result.append(String(characters[start..<boundary]))
            start = boundary
        }
        return result
    }

    private static func isSectionHeading(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let patterns = [
            #"^第[0-9０-９一二三四五六七八九十百千〇零]+[章节節話回夜幕].*$"#,
            #"^[0-9０-９一二三四五六七八九十百千〇零]+[、.．:：)）].{0,60}$"#,
            #"^(?:序章|終章|序幕|終幕|プロローグ|エピローグ|前書き|後書き)$"#,
            #"^(?:chapter|section|part|episode|prologue|epilogue)\b.*$"#
        ]
        return patterns.contains { value.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private static func isSectionDivider(_ value: String) -> Bool {
        let marks = Array(value.filter { !$0.isWhitespace })
        guard marks.count >= 3 else { return false }
        return marks.allSatisfy { "*＊◇◆※—─━=－ｰー".contains($0) }
    }

    private static func isSentenceEnding(_ character: Character) -> Bool {
        "。！？!?．.」』”’".contains(character)
    }

    private static func sceneBreak(in text: String, minimumOffset: Int) -> String.Index? {
        guard let range = text.range(of: "\n\n", options: .backwards) else { return nil }
        return text.distance(from: text.startIndex, to: range.lowerBound) >= minimumOffset ? range.lowerBound : nil
    }

    private static func takeLeadingWhitespace(_ text: String) -> (String, String) {
        let prefix = String(text.prefix(while: \.isWhitespace))
        return (prefix, String(text.dropFirst(prefix.count)))
    }

    private static func takeTrailingWhitespace(_ text: String) -> (String, String) {
        let suffix = String(text.reversed().prefix(while: { $0.isWhitespace }).reversed())
        guard !suffix.isEmpty else { return (text, "") }
        return (String(text.dropLast(suffix.count)), suffix)
    }

    private static func contextTail(_ text: String, count: Int) -> String {
        guard count > 0 else { return "" }
        guard text.count > count else { return text }
        let suffix = String(text.suffix(count))
        guard let ending = suffix.firstIndex(where: isSentenceEnding) else { return suffix }
        return String(suffix[suffix.index(after: ending)...])
    }

    private static func contextHead(_ text: String, count: Int) -> String {
        guard count > 0 else { return "" }
        let prefix = String(text.prefix(count))
        guard let ending = prefix.firstIndex(where: isSentenceEnding) else { return prefix }
        return String(prefix[...ending])
    }
}
