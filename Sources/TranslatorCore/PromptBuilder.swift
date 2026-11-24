import Foundation

public struct ScoutResult: Codable, Equatable, Sendable {
    public var summary: String
    public var newTerms: [GlossaryEntry]
    public var translationNotes: [String]
    public var memory: String

    enum CodingKeys: String, CodingKey {
        case summary, memory
        case newTerms = "new_terms"
        case translationNotes = "translation_notes"
    }
}

public struct ReviewerResponse: Codable, Equatable, Sendable {
    public var scores: ReviewScores
    public var issues: [ReviewIssue]
    public var revisionInstructions: [String]
    public var verdict: String
    public var comment: String

    enum CodingKeys: String, CodingKey {
        case scores, issues, verdict, comment
        case revisionInstructions = "revision_instructions"
    }
}

public struct ChatPrompt: Sendable {
    public var system: String
    public var user: String

    public init(system: String, user: String) {
        self.system = system
        self.user = user
    }
}

public enum PromptBuilder {
    public static func planner(text: String, windowIndex: Int, windowCount: Int, existing: TranslationGuide?, settings: AppSettings) -> ChatPrompt {
        let system = """
        你是一个长篇文学翻译项目的「主编 Agent」。你不亲自翻译正文，你的职责是：通读原文、制定翻译规范、锁定专名译名、维护剧情记忆、审校译文质量。
        工作原则：一切判断以原文为准，不臆测原文没有的情节，不续写故事；专名译名一旦确定就永久沿用，不得擅自更换；除逐字引用原文的字段外，所有输出一律使用目标语言；只输出符合要求的 JSON，不要输出多余文字。
        译名原则：日语人名的汉字照搬并转为简体，纯假名人名音译并选用常见人名用字；西文人名按通行译名音译，名与姓用“·”连接，头衔和绰号意译；地名、组织、物品、招式有明确含义则意译，无明确含义则音译；同一人物的全名、名、姓、昵称和头衔分别列出并保持一致；source 必须逐字照抄原文（含大小写），不得改写或补全。
        """
        let existingText: String
        if let existing {
            let characterNames = existing.characters.flatMap { character in
                ["\(character.source)→\(character.target)"] + character.aliases.map { "\($0.source)→\($0.target)" }
            }
            let names = (characterNames + existing.terms.map { "\($0.source)→\($0.target)" }).joined(separator: "、")
            existingText = """

            【已有大纲】（根据前面的窗口写成，已有译名已经锁定，不得更改）\(json(existing))
            已锁定专名：\(names)
            更新 title_zh、genre、synopsis、style 和 rules；characters 与 terms 只返回已有大纲中没有的新条目。不得更改已锁定的译名。
            """
        } else {
            existingText = ""
        }
        let user = """
        【任务】通读原文，为作品制定具体、可执行的翻译指导大纲。
        目标语言：\(settings.targetLanguage)
        额外要求：\(settings.extraInstructions)
        \(existingText)
        【原文节选 \(windowIndex)/\(windowCount)】
        <<<
        \(text)
        >>>
        输出 title_zh、source_language、genre、synopsis（300字内）、style（narration/tone/diction/dialogue/punctuation）、characters（所有有名字的出场人物，含 source/target/gender/role/voice/aliases；gender 只能是男、女、未知；全名和每个别称都要列出并保持译名一致）、terms（地名、组织、物品、技能招式、特殊称谓等专名，含 source/target/category/note；category 只能是人名、地名、组织、物品、术语、称谓、其他，不收录普通词汇）、rules（3至8条具体可执行的翻译守则）。角色译名和其他专名先到先得。source 必须逐字照抄原文（含大小写），不得收录当前窗口原文中不存在的专名。
        """
        return ChatPrompt(system: system, user: user)
    }

    public static func scout(chunk: TranslationChunk, index: Int, total: Int, guide: TranslationGuide, memory: String, settings: AppSettings) -> ChatPrompt {
        let system = """
        你是长篇翻译项目的预读与剧情记忆 Agent。准确依照原文，不臆测或续写故事，只输出合法 JSON，不要解释。译名原则：专名使用已锁定译名；source 必须逐字引用原文（含大小写），不得改写或补全。
        """
        let user = """
        【任务】预读第 \(index)/\(total) 个片段，为翻译做准备并更新剧情记忆。
        【作品】\(guide.titleZh)｜\(guide.genre)
        【已锁定专名】\(relevantGlossary(in: chunk.source, guide: guide).map { "\($0.source)→\($0.target)" }.joined(separator: "、"))
        【当前剧情记忆】（上个片段为止）
        \(memory.isEmpty ? "# 剧情记忆\n## 主线进展\n- 暂无\n## 人物状态\n- 暂无\n## 伏笔与悬念\n- 暂无\n## 最新进展\n暂无" : memory)
        【上文末尾】\(chunk.previousTail)
        【本片段原文】
        <<<
        \(chunk.source)
        >>>
        summary 不超过 \(settings.summaryMaxCharacters) 字，说明人物、地点、事件和结尾停在哪里，人名使用已锁定的中文译名；new_terms 只列本片段出现但已锁定列表没有的新人物、地名、组织、物品和专有术语，category 只能是人名、地名、组织、物品、术语、称谓、其他，不收录普通词汇或重复条目；translation_notes 最多3条、每条不超过60字，提醒指代、双关、语气变化或需要前文才能理解之处；memory 是截至本片段结束的完整剧情记忆，不是本片段摘要，固定保留“# 剧情记忆 / ## 主线进展 / ## 人物状态 / ## 伏笔与悬念 / ## 最新进展”结构（主线按时间顺序，人物状态逐人记录，保留未解伏笔，最新进展两三句话），严格不超过 \(settings.memoryMaxCharacters) 字，先压缩早期情节。没有新专名或翻译提示时分别输出空数组。
        """
        return ChatPrompt(system: system, user: user)
    }

    public static func memoryCompression(_ memory: String, limit: Int) -> ChatPrompt {
        ChatPrompt(
            system: "你是剧情记忆压缩助手。保留重要事实，不添加内容，输出完整压缩后的记忆，不要解释。",
            user: "以下记忆有\(memory.count)字，压缩到\(limit)字以内并保留四个小节“主线进展、人物状态、伏笔与悬念、最新进展”；按时间顺序记录主线，优先合并删减较早细节，不得添加内容，输出压缩后的完整 memory：\n\(memory)"
        )
    }

    public static func translator(chunk: TranslationChunk, previousTranslation: String, guide: TranslationGuide, settings: AppSettings, revisionInstructions: [String]) -> ChatPrompt {
        let style = guide.style
        let related = relevantGlossary(in: chunk.source, guide: guide)
        let people = guide.characters.filter { person in
            ([person.source] + person.aliases.map(\.source)).contains { occurrenceCount($0, in: chunk.source) > 0 }
        }.prefix(8)
        let terms = related.prefix(80).map { "\($0.source)→\($0.target)" }.joined(separator: "、")
        let voices = people.map { "\($0.source)→\($0.target)（\($0.gender)）——\($0.role)；\($0.voice)" }.joined(separator: "\n")
        let rules = guide.rules.map { "【注意】\($0)" }.joined(separator: "\n")
        let notes = chunk.translationNotes.map { "【注意】\($0)" }.joined(separator: "\n")
        let revisions = revisionInstructions.map { "【注意】修订要求：\($0)" }.joined(separator: "\n")
        let system = """
        你是文学翻译引擎。下面是背景资料，只用来理解语境、保持前后一致，严禁翻译或输出其中任何内容。
        【作品】\(guide.titleZh)｜\(guide.genre)
        【前情】
        \(chunk.memoryBefore)
        【本片段概述】
        \(chunk.summary)
        【上文末尾】（已翻译，不要重复翻译）
        \(chunk.previousTail)
        【上文译文末尾】
        \(String(previousTranslation.suffix(300)))
        【下文开头】（属于下一片段，不要翻译）
        \(chunk.nextHead)
        """
        let user = """
        请将以下\(settings.sourceLanguage == "auto" ? guide.sourceLanguage : settings.sourceLanguage)\(settings.genre)翻译成\(settings.targetLanguage)，并且严格遵循所有约束要求。

        【源文】
        \(chunk.source)

        【约束要求】
        1. 【硬性要求】专名/术语对照: \(terms.isEmpty ? "无" : terms)
        2. 【硬性要求】保留源文的分段与换行，逐段翻译，不得合并、遗漏或增添段落
        3. 【硬性要求】只翻译【源文】中的内容，不得翻译或输出背景资料、上文、下文中的内容
        4. 【注意】文风：\(style.tone)；\(style.narration)；\(style.diction)
        5. 【注意】对话：\(style.dialogue)
        6. 【注意】标点：\(style.punctuation)
        7. 【注意】人物口吻：\(voices)
        \(rules)
        \(notes)
        【注意】\(settings.extraInstructions)
        \(revisions)
        只输出译文，不要有任何额外说明。
        """
        return ChatPrompt(system: system, user: user)
    }

    public static func reviewer(chunk: TranslationChunk, translation: String, guide: TranslationGuide, settings: AppSettings, qualityFindings: [QualityFinding]) -> ChatPrompt {
        let style = guide.style
        let related = relevantGlossary(in: chunk.source, guide: guide).map { "\($0.source)→\($0.target)" }.joined(separator: "、")
        let people = guide.characters.filter { character in
            ([character.source] + character.aliases.map(\.source)).contains { occurrenceCount($0, in: chunk.source) > 0 }
        }.prefix(8)
        let voices = people.map { "\($0.source)→\($0.target)（\($0.gender)）：\($0.role)；\($0.voice)" }.joined(separator: "\n")
        let checks = qualityFindings.map { "- \($0.message)" }.joined(separator: "\n")
        let user = """
        【任务】审校第 \(chunk.index + 1) 个片段：逐段比对原文，并按评分表评分。目标语言：\(settings.targetLanguage)。不能因为译文流畅就掩盖误译、漏译或越界。
        【文风规范】叙述：\(style.narration)；基调：\(style.tone)；用词：\(style.diction)；对话：\(style.dialogue)；标点：\(style.punctuation)
        守则：\(guide.rules.joined(separator: "；"))
        【出场人物口吻】\(voices.isEmpty ? "无" : "\n\(voices)")
        【本片段相关专名】\(related)
        【上文末尾】（属于上一片段，译文不应含其翻译）\(chunk.previousTail)
        【下文开头】（属于下一片段，译文不应含其翻译）\(chunk.nextHead)
        【原文】
        <<<
        \(chunk.source)
        >>>
        【译文】
        <<<
        \(translation)
        >>>
        【自动检查发现的问题】\(checks)
        评分表（每项0–10整数）：accuracy忠实度（误译、主语/指代、否定、数字、时间、因果）；completeness完整度（漏译、增译、段落对应、是否越界）；terminology术语（是否严格使用对照表）；fluency流畅度（地道的\(settings.targetLanguage)，无翻译腔、病句或残留外文）；style风格（叙述语气、人物口吻、标点）。10=可直接出版；8=只有不影响理解的小瑕疵；6=有明显问题需要修改；4=问题很多；2及以下=不可用。
        issues 最多8条并按严重程度排序；type 只能是误译、漏译、增译、术语、风格、语病、越界；severity 只能是严重、一般、轻微；source 逐字引用问题原文（不超过60字），translation 引用对应译文（不超过60字，漏译留空），suggestion 给出建议译法或修改方向。
        revision_instructions 若需重译则给1–4条简短、可执行的修改指令，每条不超过60字；不需重译时为空数组。存在严重问题、整段漏译或越界时 verdict 必须是 revise。comment 一句话总评。
        """
        return ChatPrompt(
            system: "你是严谨的文学翻译审校编辑。逐段核对原文，不凭流畅度掩盖误译漏译。只输出合法 JSON。",
            user: user
        )
    }

    public static func relevantGlossary(in text: String, guide: TranslationGuide) -> [GlossaryEntry] {
        let entries = guide.terms + guide.characters.flatMap { character in
            [GlossaryEntry(source: character.source, target: character.target, category: "人名", note: character.voice)]
                + character.aliases.map { GlossaryEntry(source: $0.source, target: $0.target, category: "人名") }
        }
        var counts: [UUID: Int] = [:]
        let relevant = entries.filter { entry in
            let count = occurrenceCount(entry.source, in: text)
            if count > 0 { counts[entry.id] = count }
            return count > 0
        }
        return relevant.sorted { counts[$0.id, default: 0] > counts[$1.id, default: 0] }
    }

    private static func occurrenceCount(_ source: String, in text: String) -> Int {
        guard !source.isEmpty else { return 0 }
        if TranslationTextMetrics.containsWesternLetters(source) {
            let escaped = NSRegularExpression.escapedPattern(for: source)
            guard let expression = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) else { return 0 }
            return expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: source, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
