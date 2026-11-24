import SwiftUI
import UniformTypeIdentifiers
import TranslatorCore
import CoreFoundation

struct TranslatorRootView: View {
    @Bindable var model: TranslatorAppModel
    @Environment(\.openWindow) private var openWindow
    @State private var deleteJobID: UUID?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            pageContent
                .navigationTitle(model.page.rawValue)
                .toolbar { toolbar }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("删除此翻译任务及其本地文件？", isPresented: Binding(get: { deleteJobID != nil }, set: { if !$0 { deleteJobID = nil } }), titleVisibility: .visible) {
            Button("删除任务", role: .destructive) {
                if let deleteJobID { model.selectedJobID = deleteJobID; Task { await model.deleteSelectedJob() } }
                deleteJobID = nil
            }
            Button("取消", role: .cancel) { deleteJobID = nil }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: model.selectedJobID) { await model.loadSelectedJobLog() }
    }

    private var sidebar: some View {
        List(selection: $model.page) {
            Section("工作区") {
                ForEach(TranslatorPage.allCases) { page in
                    Label(page.rawValue, systemImage: page.symbol).tag(page)
                }
            }
            Section("翻译任务") {
                if model.jobs.isEmpty {
                    Text("还没有任务").foregroundStyle(.secondary)
                }
                ForEach(model.jobs) { job in
                    Button {
                        model.selectedJobID = job.id
                        model.page = .progress
                    } label: {
                        HStack(spacing: 9) {
                            Circle().fill(statusColor(job.status)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(job.name).lineLimit(1)
                                Text("\(job.completedCount)/\(job.chunks.count) 片段 · 平均分 \(job.averageScore.map(String.init) ?? "—") · \(model.isJobQueued(job.id) ? "队列中" : job.status.rawValue)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                ProgressView(value: Double(job.completedCount), total: Double(max(1, job.chunks.count)))
                                    .controlSize(.mini)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("打开进度") { model.selectedJobID = job.id; model.page = .progress }
                        Button("加入运行队列") { model.enqueueJob(job.id) }
                            .disabled(model.isJobActive(job.id) || model.isJobQueued(job.id) || job.status == .completed)
                        Button("删除任务", role: .destructive) { deleteJobID = job.id }.disabled(model.isJobActive(job.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Circle().fill(model.connectionText.hasPrefix("已连接") ? .green : .orange).frame(width: 8, height: 8)
                Text(model.connectionText).font(.caption).lineLimit(1)
                Spacer(minLength: 0)
                Button { Task { await model.connect() } } label: {
                    if model.isConnecting { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .help("测试 LM Studio 连接")
            }
            .padding(12)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.page {
        case .newJob: NewJobView(model: model)
        case .progress: ProgressDashboard(model: model)
        case .preview: ChunkPreviewView(model: model)
        case .reading: TranslationReaderView(model: model)
        case .guide: GuideEditorView(model: model)
        case .memory: MemoryHistoryView(model: model)
        case .settings: SettingsView(model: model)
        case .diary: WorkspaceDiaryView(model: model)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let job = model.selectedJob ?? model.activeJob {
            ToolbarItem(placement: .principal) {
                Text(model.isWorking ? model.activeJob?.name ?? job.name : job.name)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 260)
            }
        }
        if model.isWorking {
            ToolbarItem(placement: .primaryAction) {
                Button { model.pause() } label: {
                    Label("安全暂停", systemImage: "pause.fill").labelStyle(.iconOnly)
                }
                .help("安全暂停")
            }
            if let job = model.selectedJob, !model.isJobActive(job.id) {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.enqueueJob(job.id) } label: {
                        Label("加入队列", systemImage: "text.badge.plus").labelStyle(.iconOnly)
                    }
                    .disabled(model.isJobQueued(job.id) || job.status == .completed)
                    .help("将所选任务加入队列")
                }
            }
        } else if let job = model.selectedJob, [.queued, .paused, .failed, .awaitingGuide].contains(job.status) {
            ToolbarItem(placement: .primaryAction) {
                Button { model.startSelected() } label: {
                    Label(job.status == .awaitingGuide ? "确认并继续" : "继续翻译", systemImage: "play.fill").labelStyle(.iconOnly)
                }
                .disabled(job.status == .awaitingGuide && job.guide == nil)
                .help(job.status == .awaitingGuide ? "确认大纲并继续翻译" : "继续翻译")
            }
        }
        if model.hasQueuedJobs && !model.isWorking {
            ToolbarItem(placement: .primaryAction) {
                Button { model.runQueue() } label: {
                    Label("运行队列", systemImage: "play.fill").labelStyle(.iconOnly)
                }
                .help("运行队列")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { openWindow(id: "compact-progress") } label: {
                Label("任务速览", systemImage: "chart.bar.xaxis").labelStyle(.iconOnly)
            }
            .help("打开紧凑任务速览")
        }
    }
}

private struct NewJobView: View {
    @Bindable var model: TranslatorAppModel
    @State private var files: [URL] = []
    @State private var sameStory = true
    @State private var jobName = ""
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "创建翻译任务", subtitle: "导入一个或多个 UTF 文本文件，任务将逐片段自动翻译、审校并持续保存。")
            VStack(spacing: 15) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 38)).foregroundStyle(.tint)
                Text("将 .txt 文件拖到这里").font(.title3.weight(.semibold))
                Text("支持 UTF-8、UTF-16、GB18030 与 Shift-JIS 编码")
                    .font(.callout).foregroundStyle(.secondary)
                Button("选择文本文件…") { importing = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [6])))
            .dropDestination(for: URL.self) { urls, _ in
                files.append(contentsOf: urls.filter { $0.pathExtension.lowercased() == "txt" })
                files = unique(files)
                return true
            }
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("待导入文件（\(files.count)）").font(.headline)
                    ForEach(files, id: \.absoluteString) { url in
                        HStack {
                            Image(systemName: "doc.text")
                            Text(url.lastPathComponent).lineLimit(1)
                            Spacer()
                            Button { files.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(9)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                TextField("任务名称（可选）", text: $jobName)
                    .textFieldStyle(.roundedBorder)
                Toggle("这些文件属于同一部作品（共享大纲、术语和剧情记忆）", isOn: $sameStory)
            }
            HStack {
                Text("新任务的片段上限：\(model.settings.maxChunkCharacters) 字符").foregroundStyle(.secondary)
                Spacer()
                Button("创建并查看进度") {
                    Task { await model.importFiles(files, sameStory: sameStory, name: jobName); files = []; jobName = "" }
                }
                .buttonStyle(.borderedProminent)
                .disabled(files.isEmpty)
            }
            Spacer()
        }
        .padding(28)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                files = unique(files + urls.filter { $0.pathExtension.lowercased() == "txt" })
            }
        }
    }

    private func unique(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

private struct ProgressDashboard: View {
    @Bindable var model: TranslatorAppModel
    private var job: TranslationJob? { model.selectedJob }

    var body: some View {
        Group {
            if let job {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PageHeading(title: job.name, subtitle: "\(job.sourceFiles.count) 个文件 · \(job.chunks.count) 个片段 · 创建于 \(job.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        HStack(spacing: 18) {
                            VStack(spacing: 8) {
                                ProgressView(value: Double(job.completedCount), total: Double(max(1, job.chunks.count)))
                                    .progressViewStyle(.circular).controlSize(.extraLarge)
                                Text("\(Int(Double(job.completedCount) / Double(max(1, job.chunks.count)) * 100))%")
                                    .font(.title2.weight(.bold))
                            }
                            .frame(width: 125, height: 130)
                            statCard("片段", value: "\(job.completedCount)/\(job.chunks.count)", symbol: "square.grid.3x3")
                            statCard("平均分", value: job.averageScore.map(String.init) ?? "—", symbol: "star")
                            statCard("待人工复核", value: "\(job.flaggedCount)", symbol: "eye")
                            statCard("模型 Token", value: "主控 \(job.controllerTokens.formatted()) · 翻译 \(job.translatorTokens.formatted())", symbol: "arrow.left.arrow.right")
                        }
                        HStack(spacing: 18) {
                            Label("已用时  \(duration(Date.now.timeIntervalSince(job.startedAt ?? job.createdAt)))", systemImage: "clock")
                            Label("预计剩余  \(remainingTime(job))", systemImage: "hourglass")
                            Label("总计 \(job.totalTokens.formatted()) tokens", systemImage: "sum")
                            Spacer()
                        }
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                        phaseStrip(job)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("片段地图").font(.headline)
                                Spacer()
                                Button("打开对照预览") { model.page = .preview }
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 7)], spacing: 7) {
                                ForEach(job.chunks) { chunk in
                                    Button {
                                        model.selectedChunkIndex = chunk.index
                                        model.page = .preview
                                    } label: {
                                        Text("\(chunk.index + 1)").font(.caption2.weight(.semibold))
                                            .frame(maxWidth: .infinity, minHeight: 34)
                                            .background(chunkMapColor(chunk).opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(chunkMapColor(chunk), lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                    .help("第\(chunk.index + 1)段 · \(chunk.status.rawValue) · \(chunk.reviewScore.map(String.init) ?? "未评分")")
                                }
                            }
                            HStack(spacing: 14) {
                                legend("待处理", .gray); legend("进行中", .blue); legend("高分完成", .green); legend("低分完成", .red); legend("待复核", .orange)
                            }
                            .font(.caption)
                        }
                        .padding(16).cardSurface()
                        HStack(alignment: .top, spacing: 16) {
                            controllerPanel
                            livePanel(title: "翻译模型", symbol: "character.book.closed", text: model.translatorStream, tint: .blue)
                        }
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("当前步骤", systemImage: "waveform.path").font(.headline)
                                Text(model.currentActivity).textSelection(.enabled).foregroundStyle(.secondary)
                                Text("\(job.status == .running ? "执行中" : job.status.rawValue) · 最近更新 \(job.updatedAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16).cardSurface()
                            VStack(alignment: .leading, spacing: 8) {
                                Label("运行日志", systemImage: "text.alignleft").font(.headline)
                                ScrollView { LazyVStack(alignment: .leading, spacing: 4) { ForEach(Array(model.logLines.suffix(20).enumerated()), id: \.offset) { _, line in Text(line).font(.caption.monospaced()).textSelection(.enabled) } } }
                                    .frame(height: 95)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16).cardSurface()
                        }
                    }
                    .padding(26)
                }
            } else {
                ContentUnavailableView("选择一个翻译任务", systemImage: "text.book.closed", description: Text("从侧边栏选择任务，或先导入文本文件。"))
            }
        }
    }

    private func statCard(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14).cardSurface()
    }

    private func phaseStrip(_ job: TranslationJob) -> some View {
        let phases = ["通读大纲", "预读记忆", "翻译", "评审", "合并"]
        return HStack(spacing: 0) {
            ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                HStack(spacing: 7) {
                    Image(systemName: phaseSymbol(index, job: job)).foregroundStyle(phaseColor(index, job: job))
                    Text(phase).font(.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                if index < phases.count - 1 { Rectangle().fill(.quaternary).frame(height: 1).frame(maxWidth: 38).padding(.horizontal, 5) }
            }
        }
        .padding(15).cardSurface()
    }

    private func phaseSymbol(_ index: Int, job: TranslationJob) -> String {
        if job.status == .completed || index < phaseIndex(job) { return "checkmark.circle.fill" }
        return index == phaseIndex(job) ? "circle.inset.filled" : "circle"
    }

    private func phaseColor(_ index: Int, job: TranslationJob) -> Color {
        job.status == .completed || index <= phaseIndex(job) ? .accentColor : .secondary
    }

    private func phaseIndex(_ job: TranslationJob) -> Int {
        if job.status == .queued || job.status == .planning || job.status == .awaitingGuide { return 0 }
        if job.completedCount == 0 { return 1 }
        if job.completedCount < job.chunks.count { return 3 }
        return 4
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        Label(title, systemImage: "square.fill").foregroundStyle(color)
    }

    private func livePanel(title: String, symbol: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(tint)
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    Text(text.isEmpty ? "等待模型输出…" : text)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                        .frame(width: max(0, geometry.size.width - 20), alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 160)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(15).cardSurface()
    }

    private var controllerPanel: some View {
        let snapshots = model.selectedJob?.agentOutputSnapshots ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Label("主控 Agent", systemImage: "brain.head.profile").font(.headline).foregroundStyle(.purple)
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        if snapshots.isEmpty && model.controllerOutput.isEmpty && model.controllerReasoning.isEmpty {
                            Text("等待模型输出…").foregroundStyle(.secondary)
                        }
                        if !model.controllerReasoning.isEmpty {
                            DisclosureGroup("查看思考过程") {
                                Text(model.controllerReasoning).font(.system(.caption, design: .monospaced)).italic().foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        if !model.controllerOutput.isEmpty && (model.controllerOutputInProgress || snapshots.isEmpty) {
                            DisclosureGroup(model.controllerOutputInProgress ? "实时模型输出" : "未解析的模型输出") {
                                Text(model.controllerOutput).font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        ForEach(snapshots) { snapshot in AgentSnapshotView(snapshot: snapshot) }
                    }
                    .frame(width: max(0, geometry.size.width - 20), alignment: .leading)
                    .padding(10)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 160)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(15).cardSurface()
    }

    private func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 秒" }
        let value = Int(seconds)
        return value >= 3_600 ? "\(value / 3_600) 小时 \((value % 3_600) / 60) 分" : value >= 60 ? "\(value / 60) 分 \(value % 60) 秒" : "\(value) 秒"
    }

    private func chunkMapColor(_ chunk: TranslationChunk) -> Color {
        guard chunk.status == .done, let score = chunk.reviewScore else { return statusColor(chunk.status) }
        return score < 60 ? .red : score < 80 ? .orange : .green
    }

    private func remainingTime(_ job: TranslationJob) -> String {
        guard job.completedCount > 0, job.completedCount < job.chunks.count else { return job.status == .completed ? "0 秒" : "计算中" }
        let elapsed = Date.now.timeIntervalSince(job.startedAt ?? job.createdAt)
        let estimate = elapsed / Double(job.completedCount) * Double(job.chunks.count - job.completedCount)
        return duration(estimate)
    }
}

private struct AgentSnapshotView: View {
    var snapshot: AgentOutputSnapshot

    private var title: String {
        switch snapshot.role {
        case "planner": "主控规划 · 窗口 \(snapshot.windowIndex ?? 0)"
        case "scout": "主控预读 · 片段 \((snapshot.chunkIndex ?? 0) + 1)"
        case "reviewer": "主控评审 · 片段 \((snapshot.chunkIndex ?? 0) + 1)"
        default: snapshot.role
        }
    }

    private var structuredValue: SnapshotJSONValue? {
        guard let data = snapshot.structuredJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return SnapshotJSONValue.parse(object)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.purple)
            if let structuredValue {
                SnapshotStructuredView(label: "", value: structuredValue)
            } else {
                Text("结构化结果暂不可用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("查看原始 JSON") {
                Text(snapshot.rawJSON).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .background(.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

private indirect enum SnapshotJSONValue {
    case scalar(String)
    case object([(String, SnapshotJSONValue)])
    case array([SnapshotJSONValue])

    static func parse(_ value: Any) -> SnapshotJSONValue {
        if let object = value as? [String: Any] {
            return .object(object.keys.filter { $0 != "id" }.sorted().map { ($0, parse(object[$0] ?? NSNull())) })
        }
        if let array = value as? [Any] { return .array(array.map(parse)) }
        if value is NSNull { return .scalar("—") }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .scalar(number.boolValue ? "是" : "否") }
            return .scalar(number.stringValue)
        }
        return .scalar(String(describing: value))
    }
}

private struct SnapshotStructuredView: View {
    var label: String
    var value: SnapshotJSONValue

    var body: some View { render(value, label: label, depth: 0) }

    private func render(_ value: SnapshotJSONValue, label: String, depth: Int) -> AnyView {
        switch value {
        case .scalar(let text):
            return AnyView(
                HStack(alignment: .top, spacing: 8) {
                    if !label.isEmpty { Text(localizedLabel(label)).font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(width: 92, alignment: .leading) }
                    Text(text).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            )
        case .object(let fields):
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    if !label.isEmpty { Text(localizedLabel(label)).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                        render(field.1, label: field.0, depth: depth + 1)
                    }
                }
                .padding(depth == 0 ? 0 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(depth == 0 ? Color.clear : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
            )
        case .array(let values):
            return AnyView(
                VStack(alignment: .leading, spacing: 5) {
                    if !label.isEmpty { Text(localizedLabel(label)).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    ForEach(Array(values.enumerated()), id: \.offset) { index, item in
                        render(item, label: "第\(index + 1)项", depth: depth + 1)
                            .padding(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            )
        }
    }
}

private func localizedLabel(_ key: String) -> String {
    let labels = [
        "title_zh": "中文标题", "source_language": "原文语言", "genre": "体裁", "synopsis": "故事梗概",
        "style": "文风", "narration": "叙述方式", "tone": "基调", "diction": "措辞", "dialogue": "对话",
        "punctuation": "标点", "characters": "人物", "source": "原文名称", "target": "锁定译名", "gender": "性别",
        "role": "身份", "voice": "口吻", "aliases": "别名与称呼", "terms": "专名与术语", "category": "类别",
        "note": "说明", "rules": "翻译守则", "sections": "小节分析", "section_id": "小节标识", "source_title": "原文标题",
        "section_type": "小节类型", "summary": "摘要", "evidence": "原文证据",
        "new_terms": "新术语", "translation_notes": "翻译提示", "memory": "剧情记忆", "scores": "分项评分",
        "accuracy": "准确性", "completeness": "完整性", "terminology": "术语", "fluency": "流畅度", "score": "总评分",
        "issues": "发现的问题", "type": "问题类型", "severity": "严重程度", "translation": "当前译文",
        "suggestion": "修改建议", "revision_instructions": "修订指令", "verdict": "评审结论", "comment": "评审意见",
        "hard": "硬性问题", "penalty": "扣分", "automatic_checks": "自动检查", "model_reviewed": "模型评审"
    ]
    return labels[key] ?? key.replacingOccurrences(of: "_", with: " ")
}

struct CompactProgressWindow: View {
    @Bindable var model: TranslatorAppModel
    @Environment(\.openWindow) private var openWindow
    @State private var isHovered = false

    private var job: TranslationJob? { model.activeJob ?? model.selectedJob }
    private var gridColumns: [GridItem] { Array(repeating: GridItem(.flexible(minimum: 8), spacing: 4), count: 16) }

    var body: some View {
        ZStack {
            if let job {
                progressCard(job)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(.secondary)
                    Text("选择一个翻译任务查看进度").font(.callout).foregroundStyle(.secondary)
                }
                .frame(width: 360, height: 210)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary.opacity(0.55), lineWidth: 1))
                .scaleEffect(isHovered ? 1.1 : 1)
            }
        }
        .frame(width: 412, height: 252)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.18), value: isHovered)
    }

    private func progressCard(_ job: TranslationJob) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.name).font(.headline).lineLimit(1)
                    Text("\(activityLabel(for: job)) · \(job.completedCount)/\(job.chunks.count) 段")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("\(completionPercentage(job))%")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }

            if job.chunks.isEmpty {
                Text("尚无片段").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 62)
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 4) {
                        ForEach(job.chunks) { chunk in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(chunkColor(chunk))
                                .frame(height: 12)
                                .help("第 \(chunk.index + 1) 段 · \(chunk.status.rawValue) · \(chunk.reviewScore.map(String.init) ?? "未评分")")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .frame(height: 62)
            }

            HStack(spacing: 8) {
                if model.isJobActive(job.id) {
                    Button { model.pause() } label: { Label("暂停", systemImage: "pause.fill") }
                        .help("安全暂停当前任务")
                } else {
                    Button {
                        model.selectedJobID = job.id
                        model.enqueueJob(job.id)
                    } label: {
                        Label(model.isJobQueued(job.id) ? "排队中" : "继续", systemImage: model.isJobQueued(job.id) ? "checkmark" : "play.fill")
                    }
                    .disabled(model.isJobQueued(job.id) || job.status == .completed || (job.status == .awaitingGuide && job.guide == nil))
                }
                if model.hasQueuedJobs && !model.isWorking {
                    Button { model.runQueue() } label: { Label("运行队列", systemImage: "play.fill") }
                }
                Spacer(minLength: 0)
                Button {
                    model.selectedJobID = job.id
                    model.page = .progress
                    openWindow(id: "translator-main")
                } label: {
                    Label("查看任务", systemImage: "arrow.up.right.square")
                }
                .help("在主窗口打开任务进度")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 360, height: 210, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary.opacity(0.55), lineWidth: 1))
        .scaleEffect(isHovered ? 1.1 : 1)
    }

    private func activityLabel(for job: TranslationJob) -> String {
        let activity = model.activityText(for: job.id, fallback: job.status.rawValue)
        if model.isJobActive(job.id), !activity.isEmpty { return activity }
        if model.isJobQueued(job.id) { return "队列中" }
        return activity
    }

    private func completionPercentage(_ job: TranslationJob) -> Int {
        guard !job.chunks.isEmpty else { return 0 }
        return Int(Double(job.completedCount) / Double(job.chunks.count) * 100)
    }

    private func chunkColor(_ chunk: TranslationChunk) -> Color {
        guard chunk.status == .done, let score = chunk.reviewScore else { return statusColor(chunk.status) }
        return score < 60 ? .red : score < 80 ? .orange : .green
    }
}

private struct ChunkPreviewView: View {
    @Bindable var model: TranslatorAppModel
    @State private var showingEditor = false
    @State private var showingRetranslate = false
    @State private var editedText = ""
    @State private var revisionNote = ""
    @State private var attemptNumber: Int?

    private var job: TranslationJob? { model.selectedJob }
    private var chunk: TranslationChunk? { job?.chunks.first { $0.index == model.selectedChunkIndex } }

    var body: some View {
        Group {
            if let job, let chunk {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("片段").font(.headline).padding(.horizontal, 12).padding(.top, 15)
                        List(selection: Binding(get: { model.selectedChunkIndex }, set: { model.selectedChunkIndex = $0 })) {
                            ForEach(job.chunks) { item in
                                HStack(spacing: 7) {
                                    Circle().fill(statusColor(item.status)).frame(width: 7, height: 7)
                                    Text(String(format: "%03d", item.index + 1)).font(.caption.monospaced())
                                    Text(item.summary.isEmpty ? item.source.prefix(26).description : item.summary).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if let score = item.reviewScore { Text("\(score)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                                }
                                .tag(item.index)
                            }
                        }
                        .listStyle(.sidebar)
                        .frame(minWidth: 220, idealWidth: 260)
                    }
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("片段 \(chunk.index + 1) / \(job.chunks.count)").font(.title2.weight(.semibold))
                                    Text("\(chunk.fileName) · \(chunk.status.rawValue)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !chunk.attempts.isEmpty {
                                    Picker("译文", selection: $attemptNumber) {
                                        Text("最终译文").tag(nil as Int?)
                                        ForEach(chunk.attempts.indices, id: \.self) { index in Text("第\(index + 1)次").tag(Optional(index)) }
                                    }
                                    .frame(width: 130)
                                }
                                Button("重译") { revisionNote = ""; showingRetranslate = true }.disabled(model.isJobActive(job.id))
                                Button("手动编辑") { editedText = selectedTranslation(chunk); showingEditor = true }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.isJobActive(job.id))
                            }
                            comparison(source: chunk.source, translation: selectedTranslation(chunk))
                            if !chunk.summary.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("片段概述", systemImage: "text.quote").font(.headline)
                                    Text(chunk.summary).textSelection(.enabled)
                                }.padding(14).cardSurface()
                            }
                            reviewPanel(chunk)
                        }
                        .padding(22)
                    }
                }
                .onChange(of: model.selectedChunkIndex) { _, _ in attemptNumber = nil }
                .sheet(isPresented: $showingEditor) {
                    EditTranslationSheet(text: $editedText) { Task { await model.editTranslation(chunkIndex: chunk.index, text: editedText) } }
                        .frame(minWidth: 650, minHeight: 520)
                }
                .sheet(isPresented: $showingRetranslate) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("重译片段 \(chunk.index + 1)").font(.title2.weight(.semibold))
                        Text("可为翻译模型追加一句具体修改要求。已有尝试会保留。").foregroundStyle(.secondary)
                        TextEditor(text: $revisionNote).font(.body).frame(minHeight: 140).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                        HStack { Spacer(); Button("取消") { showingRetranslate = false }; Button("开始重译") { showingRetranslate = false; Task { await model.retranslate(chunkIndex: chunk.index, note: revisionNote) } }.buttonStyle(.borderedProminent) }
                    }.padding(24).frame(width: 480)
                }
            } else {
                ContentUnavailableView("暂无片段", systemImage: "rectangle.split.2x1", description: Text("先选择或创建一个翻译任务。"))
            }
        }
    }

    private func comparison(source: String, translation: String) -> some View {
        let left = source.components(separatedBy: "\n")
        let right = translation.components(separatedBy: "\n")
        return VStack(alignment: .leading, spacing: 9) {
            HStack { Label("原文", systemImage: "text.alignleft").font(.headline); Spacer(); Label("译文", systemImage: "character.book.closed").font(.headline) }
            if left.count == right.count {
                VStack(spacing: 0) {
                    ForEach(left.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 0) {
                            Text(left[index].isEmpty ? " " : left[index]).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            Rectangle().fill(.quaternary).frame(width: 1)
                            Text(right[index].isEmpty ? " " : right[index]).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }
                        .font(.system(.body, design: .serif))
                        if index < left.count - 1 { Divider() }
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
            } else {
                HStack(alignment: .top, spacing: 12) {
                    textColumn(left.joined(separator: "\n"), label: "源文")
                    textColumn(translation, label: "译文")
                }
            }
        }
        .padding(14).cardSurface()
    }

    private func textColumn(_ text: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(text).font(.system(.body, design: .serif)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(minHeight: 250).padding(12).background(.background, in: RoundedRectangle(cornerRadius: 8))
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func reviewPanel(_ chunk: TranslationChunk) -> some View {
        if let attempt = selectedAttempt(chunk) {
            if attempt.isManualEdit {
                qualityOnlyPanel(
                    title: "手动编辑 · 未经模型评审",
                    findings: attempt.automaticChecks ?? [],
                    findingsWereRecorded: attempt.automaticChecks != nil
                )
            } else if let review = attempt.review, review.modelReviewed {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Label("模型评审结果", systemImage: "checkmark.seal").font(.headline); Spacer(); Text("\(review.score)/100").font(.title3.weight(.semibold)); Text(review.verdict == "pass" ? "通过" : "需修改").font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4).background(review.verdict == "pass" ? Color.green.opacity(0.14) : Color.orange.opacity(0.16), in: Capsule()) }
                    HStack(spacing: 16) {
                        score("忠实度", review.scores.accuracy); score("完整度", review.scores.completeness); score("术语", review.scores.terminology); score("流畅度", review.scores.fluency); score("风格", review.scores.style)
                    }
                    Text(review.comment).foregroundStyle(.secondary)
                    ForEach(review.issues) { issue in
                        HStack(alignment: .top, spacing: 8) {
                            Text(issue.severity).font(.caption2.weight(.bold)).foregroundStyle(issue.severity == "严重" ? .red : .orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(issue.type)：\(issue.source)").font(.callout.weight(.medium))
                                if !issue.translation.isEmpty { Text(issue.translation).foregroundStyle(.secondary) }
                                Text(issue.suggestion).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(8).background(.background, in: RoundedRectangle(cornerRadius: 7))
                    }
                    qualityFindings(review.automaticChecks)
                }.padding(14).cardSurface()
            } else if let review = attempt.review {
                qualityOnlyPanel(title: "仅自动质检 · 未经模型评审", findings: review.automaticChecks)
            }
        }
    }

    private func qualityOnlyPanel(title: String, findings: [QualityFinding], findingsWereRecorded: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "checkmark.shield").font(.headline)
            if findingsWereRecorded {
                qualityFindings(findings, showEmptyState: true)
            } else {
                Label("该历史手动编辑未记录自动质检结果", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).cardSurface()
    }

    @ViewBuilder
    private func qualityFindings(_ findings: [QualityFinding], showEmptyState: Bool = false) -> some View {
        if findings.isEmpty {
            if showEmptyState {
                Label("自动质检未发现问题", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Divider()
            ForEach(findings) { finding in
                Label(finding.message, systemImage: finding.hard ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.caption).foregroundStyle(finding.hard ? .red : .secondary)
            }
        }
    }

    private func score(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption2).foregroundStyle(.secondary); ProgressView(value: Double(value), total: 10); Text("\(value)/10").font(.caption2.monospacedDigit()) }.frame(maxWidth: .infinity)
    }

    private func selectedTranslation(_ chunk: TranslationChunk) -> String {
        chunk.translation(forAttempt: attemptNumber)
    }

    private func selectedAttempt(_ chunk: TranslationChunk) -> TranslationAttempt? {
        if let attemptNumber, chunk.attempts.indices.contains(attemptNumber) {
            return chunk.attempts[attemptNumber]
        }
        return chunk.attempts.last { $0.translation == chunk.currentTranslation }
    }
}

private struct EditTranslationSheet: View {
    @Binding var text: String
    var save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("手动编辑译文").font(.title2.weight(.semibold))
            TextEditor(text: $text).font(.system(.body, design: .serif)).padding(8).background(.background, in: RoundedRectangle(cornerRadius: 8))
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存并标记完成") { save(); dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(20)
    }
}

private struct TranslationReaderView: View {
    @Bindable var model: TranslatorAppModel
    @State private var fileIndex = 0
    @State private var text = ""
    @State private var exporting = false
    private var job: TranslationJob? { model.selectedJob }

    var body: some View {
        Group {
            if let job, !job.sourceFiles.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Picker("文件", selection: $fileIndex) {
                            ForEach(job.sourceFiles.indices, id: \.self) { index in Text(job.sourceFiles[index].name).tag(index) }
                        }.frame(maxWidth: 300)
                        Spacer()
                        Text("衬线阅读 · 未完成片段以占位符显示").font(.caption).foregroundStyle(.secondary)
                        Button { beginExport(job: job) } label: { Label("导出文本…", systemImage: "square.and.arrow.down") }.buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    Divider()
                    ScrollView {
                        Text(text).font(.system(size: 18, design: .serif)).lineSpacing(8).frame(maxWidth: 720, alignment: .leading).textSelection(.enabled).padding(.vertical, 36)
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                }
                .task(id: "\(job.id)-\(fileIndex)-\(job.updatedAt.timeIntervalSinceReferenceDate)") {
                    let output = await model.output(jobID: job.id, fileIndex: min(fileIndex, job.sourceFiles.count - 1))
                    guard !Task.isCancelled else { return }
                    text = output
                }
                .fileExporter(isPresented: $exporting, document: TextExportDocument(text: text), contentType: .plainText, defaultFilename: exportName(job.sourceFiles[min(fileIndex, job.sourceFiles.count - 1)].name)) { result in if case .failure(let error) = result { model.errorMessage = error.localizedDescription } }
            } else {
                ContentUnavailableView("暂无译文", systemImage: "text.book.closed", description: Text("选择含有源文件的任务以阅读进度中的译文。"))
            }
        }
    }

    private func beginExport(job: TranslationJob) {
        let requestedFileIndex = min(fileIndex, job.sourceFiles.count - 1)
        Task {
            let output = await model.output(jobID: job.id, fileIndex: requestedFileIndex)
            guard model.selectedJobID == job.id else { return }
            text = output
            exporting = true
        }
    }

    private func exportName(_ name: String) -> String { URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + ".zh" }
}

private struct TextExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

private struct GuideEditorView: View {
    @Bindable var model: TranslatorAppModel
    @State private var guide = TranslationGuide()
    @State private var glossaryQuery = ""
    private var job: TranslationJob? { model.selectedJob }

    var body: some View {
        Group {
            if let job {
                Form {
                    Section("作品大纲") {
                        TextField("中文标题", text: $guide.titleZh)
                        TextField("原文语言", text: $guide.sourceLanguage)
                        TextField("体裁", text: $guide.genre)
                        TextField("梗概", text: $guide.synopsis, axis: .vertical).lineLimit(3...7)
                    }
                    Section("原文小节结构（\(job.sections?.filter(\.isExplicit).count ?? 0)）") {
                        let explicitSections = (job.sections ?? []).filter(\.isExplicit)
                        if explicitSections.isEmpty {
                            Text("未检测到显式小节标记。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(explicitSections) { section in
                            HStack {
                                Text(section.title.isEmpty ? "（前置内容）" : section.title)
                                Spacer()
                                Text(section.marker.isEmpty ? "未标记" : section.marker).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("主控小节分析（\(guide.sections.count)）") {
                        if guide.sections.isEmpty {
                            Text("完成大纲阅读后，主控会依据原文证据说明小节关系。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(guide.sections) { section in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(section.sourceTitle).font(.headline)
                                Text(section.sectionType).font(.caption).foregroundStyle(.secondary)
                                Text(section.summary)
                                Text("原文证据：\(section.evidence)").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section("文风") {
                        styleField("叙述", text: $guide.style.narration)
                        styleField("基调", text: $guide.style.tone)
                        styleField("用词", text: $guide.style.diction)
                        styleField("对话", text: $guide.style.dialogue)
                        styleField("标点", text: $guide.style.punctuation)
                    }
                    Section("翻译守则") {
                        ForEach(guide.rules.indices, id: \.self) { index in
                            HStack { TextField("守则", text: $guide.rules[index]); Button(role: .destructive) { guide.rules.remove(at: index) } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }
                        }
                        Button("添加守则") { guide.rules.append("") }
                    }
                    Section("人物与口吻（\(guide.characters.count)）") {
                        ForEach($guide.characters) { $person in
                            VStack(alignment: .leading) {
                                HStack {
                                    TextField("原名", text: $person.source)
                                    TextField("译名", text: $person.target)
                                    Picker("性别", selection: $person.gender) { ForEach(["男", "女", "未知"], id: \.self) { Text($0).tag($0) } }.frame(width: 90)
                                    TextField("身份/关系", text: $person.role)
                                    TextField("口吻", text: $person.voice)
                                    Button(role: .destructive) { guide.characters.removeAll { $0.id == person.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                                }
                                ForEach($person.aliases) { $alias in
                                    HStack { TextField("别称原文", text: $alias.source); TextField("别称译名", text: $alias.target) }
                                }
                                Button("添加别称") { person.aliases.append(GlossaryAlias(source: "", target: "")) }.buttonStyle(.borderless)
                            }
                        }
                        Button("添加人物") { guide.characters.append(CharacterEntry(source: "", target: "")) }
                    }
                    Section("专名表（\(guide.terms.count)）") {
                        TextField("搜索原文或译名", text: $glossaryQuery).textFieldStyle(.roundedBorder)
                        ForEach(guide.terms.indices.filter { index in
                            glossaryQuery.isEmpty || guide.terms[index].source.localizedCaseInsensitiveContains(glossaryQuery) || guide.terms[index].target.localizedCaseInsensitiveContains(glossaryQuery)
                        }, id: \.self) { index in
                            HStack {
                                TextField("原文", text: $guide.terms[index].source).frame(maxWidth: 220)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                TextField("译名", text: $guide.terms[index].target).frame(maxWidth: 220)
                                Picker("类别", selection: $guide.terms[index].category) { ForEach(["人名", "地名", "组织", "物品", "术语", "称谓", "其他"], id: \.self) { Text($0) } }.frame(width: 100)
                                TextField("备注", text: $guide.terms[index].note)
                                Button(role: .destructive) { guide.terms.remove(at: index) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                        }
                        Button("添加专名") { guide.terms.append(GlossaryEntry(source: "", target: "")) }
                    }
                    HStack {
                        Text("修改后的专名会用于后续片段。").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("保存大纲与术语") { Task { await model.updateGuide(guide) } }.buttonStyle(.borderedProminent).disabled(model.isJobActive(job.id))
                    }
                }
                .formStyle(.grouped)
                .padding(.horizontal, 22)
                .task(id: job.id) { guide = job.guide ?? TranslationGuide() }
            } else {
                ContentUnavailableView("还没有大纲", systemImage: "character.book.closed", description: Text("先运行一个任务以生成大纲和专名表。"))
            }
        }
    }

    private func styleField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text, axis: .vertical).lineLimit(1...3)
    }
}

private struct MemoryHistoryView: View {
    @Bindable var model: TranslatorAppModel
    @State private var snapshotIndex = 0.0
    private var job: TranslationJob? { model.selectedJob }

    var body: some View {
        Group {
            if let job {
                let history = job.memoryHistory
                let chosen = history.indices.contains(Int(snapshotIndex)) ? history[Int(snapshotIndex)] : nil
                VStack(alignment: .leading, spacing: 14) {
                    PageHeading(title: "剧情记忆", subtitle: "Scout 每完成一个片段后更新一次。记忆上限：\(model.settings.memoryMaxCharacters) 字。")
                    HStack {
                        Text(chosen.map { "第 \($0.afterChunk + 1) 段之后" } ?? "当前记忆")
                        Spacer()
                        Text("\((chosen?.text ?? job.memory).count) / \(model.settings.memoryMaxCharacters) 字").monospacedDigit().foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double((chosen?.text ?? job.memory).count), total: Double(model.settings.memoryMaxCharacters))
                    if history.count > 1 {
                        Slider(value: $snapshotIndex, in: 0...Double(history.count - 1), step: 1)
                        HStack { Text("初始"); Spacer(); Text("最新") }.font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        Text(chosen?.text ?? (job.memory.isEmpty ? "剧情记忆将在每个片段预读后生成。" : job.memory))
                            .font(.system(.body, design: .serif)).lineSpacing(7).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(22)
                    }.background(.background, in: RoundedRectangle(cornerRadius: 12))
                    Spacer(minLength: 0)
                }.padding(26)
            } else {
                ContentUnavailableView("暂无剧情记忆", systemImage: "brain.head.profile", description: Text("选择一个任务查看剧情记忆及其历史快照。"))
            }
        }
    }
}

private struct WorkspaceDiaryView: View {
    @Bindable var model: TranslatorAppModel
    @State private var searchText = ""
    @State private var levelFilter = "全部"
    @State private var categoryFilter = "全部"

    private var filteredEntries: [WorkspaceDiaryEntry] {
        Array(model.diaryEntries.filter { entry in
            (levelFilter == "全部" || levelFilter == entry.level.rawValue) &&
            (categoryFilter == "全部" || categoryFilter == entry.category.rawValue) &&
            (searchText.isEmpty || entry.message.localizedCaseInsensitiveContains(searchText))
        }.reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PageHeading(title: "工作区日记", subtitle: "记录连接、导入、设置、队列和运行状态；凭据与原文不会写入日记。")
                Spacer()
                Button { Task { await model.reloadDiary() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
            HStack {
                TextField("搜索日记", text: $searchText).textFieldStyle(.roundedBorder)
                Picker("级别", selection: $levelFilter) {
                    Text("全部").tag("全部")
                    ForEach(WorkspaceDiaryLevel.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }.frame(width: 120)
                Picker("类别", selection: $categoryFilter) {
                    Text("全部").tag("全部")
                    ForEach(WorkspaceDiaryCategory.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }.frame(width: 140)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredEntries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(entry.level.rawValue.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(diaryLevelColor(entry.level))
                                Text(entry.category.rawValue).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.timestamp.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text(entry.message).font(.callout).textSelection(.enabled)
                            if let jobID = entry.jobID { Text(jobID.uuidString).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.background, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            .overlay {
                if filteredEntries.isEmpty {
                    ContentUnavailableView("没有匹配的日记", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .padding(24)
        .task { await model.reloadDiary() }
    }
}

private func diaryLevelColor(_ level: WorkspaceDiaryLevel) -> Color {
    switch level {
    case .info: .secondary
    case .warning: .orange
    case .error: .red
    }
}

struct SettingsView: View {
    @Bindable var model: TranslatorAppModel
    @State private var credentialDraft = ""

    var body: some View {
        Form {
            Section("模型服务") {
                Picker("服务提供方", selection: Binding(get: { model.settings.provider }, set: { model.selectProvider($0) })) {
                    Text("LM Studio").tag(ModelProvider.lmStudio)
                    Text("GLM Coding Plan").tag(ModelProvider.glmCodingPlan)
                }
                TextField("服务地址", text: $model.settings.baseURL)
                if model.settings.provider == .lmStudio {
                    Picker("主控模型", selection: $model.settings.controllerModel) {
                        if model.availableModels.isEmpty { Text(model.settings.controllerModel).tag(model.settings.controllerModel) }
                        ForEach(model.availableModels.filter { $0.type == "llm" }) { item in Text("\(item.displayName)\(item.loadedInstances.isEmpty ? "" : " · 已加载")").tag(item.key) }
                    }
                    Picker("翻译模型", selection: $model.settings.translatorModel) {
                        if model.availableModels.isEmpty { Text(model.settings.translatorModel).tag(model.settings.translatorModel) }
                        ForEach(model.availableModels.filter { $0.type == "llm" }) { item in Text("\(item.displayName)\(item.loadedInstances.isEmpty ? "" : " · 已加载")").tag(item.key) }
                    }
                } else {
                    LabeledContent("模型", value: "glm-5.3-flash")
                    SecureField("GLM Coding Plan API Key", text: $credentialDraft)
                    HStack {
                        Label(
                            model.providerCredentialStatus,
                            systemImage: model.hasProviderCredential ? "key.fill" : (model.providerCredentialStatus.hasPrefix("Keychain 访问失败") ? "exclamationmark.triangle" : "key")
                        )
                        .foregroundStyle(model.providerCredentialStatus.hasPrefix("Keychain 访问失败") ? .red : .secondary)
                        Spacer()
                        Button("保存到 Keychain") {
                            let value = credentialDraft
                            credentialDraft = ""
                            Task { await model.saveProviderCredential(value) }
                        }.disabled(credentialDraft.isEmpty)
                        if model.hasProviderCredential {
                            Button("移除") { Task { await model.clearProviderCredential() } }
                        }
                    }
                    Text("凭据仅保存在 macOS Keychain，不写入设置文件或运行日记。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Label(model.connectionText, systemImage: model.connectionText.hasPrefix("已连接") ? "checkmark.circle.fill" : "network")
                        .foregroundStyle(model.connectionText.hasPrefix("已连接") ? .green : .secondary)
                    Spacer()
                    Button(model.settings.provider == .glmCodingPlan ? "测试 GLM 连接" : "测试连接并刷新模型") { Task { await model.connect() } }.disabled(model.isConnecting)
                }
            }
            Section("模型参数") {
                if model.settings.provider == .lmStudio {
                    Picker("模型调度", selection: $model.settings.modelStrategy) { Text("交换模型（节省内存）").tag(ModelStrategy.swap); Text("两个模型常驻").tag(ModelStrategy.keep) }
                    Picker("主控思考强度", selection: $model.settings.controllerReasoning) { ForEach(["low", "medium", "high"], id: \.self) { Text($0).tag($0) } }
                }
                let maxContext = model.settings.provider == .glmCodingPlan ? 1_000_000 : 65_536
                LabeledContent("主控上下文") { Stepper("\(model.settings.controllerContext.formatted())", value: $model.settings.controllerContext, in: 32_768...maxContext, step: 8_192) }
                LabeledContent("翻译上下文") { Stepper("\(model.settings.translatorContext.formatted())", value: $model.settings.translatorContext, in: 32_768...maxContext, step: 8_192) }
                LabeledContent("主控温度") { Slider(value: $model.settings.controllerTemperature, in: 0...1, step: 0.1).frame(maxWidth: 260); Text(model.settings.controllerTemperature.formatted(.number.precision(.fractionLength(1)))) }
                LabeledContent("翻译温度") { Slider(value: $model.settings.translatorTemperature, in: 0...(model.settings.provider == .glmCodingPlan ? 1 : 0.5), step: 0.1).frame(maxWidth: 260); Text(model.settings.translatorTemperature.formatted(.number.precision(.fractionLength(1)))) }
            }
            Section("翻译流程") {
                LabeledContent("新任务片段上限") { Stepper("\(model.settings.maxChunkCharacters.formatted()) 字", value: $model.settings.maxChunkCharacters, in: 2_000...16_384, step: 512) }
                LabeledContent("上下文窗口") { Stepper("\(model.settings.contextCharacters) 字", value: $model.settings.contextCharacters, in: 0...2_048, step: 64) }
                LabeledContent("批次大小") { Stepper("\(model.settings.batchSize)", value: $model.settings.batchSize, in: 2...4) }
                LabeledContent("通过分数") { Stepper("\(model.settings.passScore)", value: $model.settings.passScore, in: 0...100, step: 5) }
                LabeledContent("最大重试次数") { Stepper("\(model.settings.maxRetries)", value: $model.settings.maxRetries, in: 0...5) }
                Picker("记忆上限", selection: $model.settings.memoryMaxCharacters) { Text("1024 字").tag(1_024); Text("2048 字").tag(2_048) }
                LabeledContent("概述长度上限") { Stepper("\(model.settings.summaryMaxCharacters) 字", value: $model.settings.summaryMaxCharacters, in: 40...500, step: 20) }
                Toggle("大纲生成后暂停，等待确认", isOn: $model.settings.pauseAfterOverview)
                TextField("源语言（auto 自动识别）", text: $model.settings.sourceLanguage)
                TextField("目标语言", text: $model.settings.targetLanguage)
                TextField("体裁", text: $model.settings.genre)
                TextField("额外翻译要求", text: $model.settings.extraInstructions, axis: .vertical).lineLimit(2...5)
            }
            HStack {
                Text("设置保存在本机 Application Support 目录。任务参数只对新任务部分生效。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("保存设置") { Task { await model.saveSettings() } }.buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 22)
    }
}

private struct PageHeading: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.largeTitle.weight(.bold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func cardSurface() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary.opacity(0.55), lineWidth: 1))
    }
}

private func statusColor(_ status: ChunkStatus) -> Color {
    switch status {
    case .pending: .gray
    case .scouted, .translating, .translated, .reviewing, .reviewed: .blue
    case .done: .green
    case .flagged: .orange
    }
}

private func statusColor(_ status: JobStatus) -> Color {
    switch status {
    case .queued, .paused: .orange
    case .planning, .running, .awaitingGuide: .blue
    case .completed: .green
    case .failed: .red
    }
}
