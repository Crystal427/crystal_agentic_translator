import SwiftUI
import TranslatorCore

@main
struct CrystalTranslatorApp: App {
    @State private var model = TranslatorAppModel()

    var body: some Scene {
        WindowGroup {
            TranslatorRootView(model: model)
                .frame(minWidth: 1_050, minHeight: 700)
                .task { await model.load() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建翻译任务…") { model.page = .newJob }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        Settings {
            SettingsView(model: model)
        }
    }
}

enum TranslatorPage: String, CaseIterable, Identifiable {
    case newJob = "新建与任务"
    case progress = "进度"
    case preview = "对照预览"
    case reading = "译文阅读"
    case guide = "大纲与术语"
    case memory = "剧情记忆"
    case settings = "设置"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .newJob: "plus.square.on.square"
        case .progress: "chart.bar.xaxis"
        case .preview: "rectangle.split.2x1"
        case .reading: "text.book.closed"
        case .guide: "character.book.closed"
        case .memory: "brain.head.profile"
        case .settings: "slider.horizontal.3"
        }
    }
}

@MainActor
@Observable
final class TranslatorAppModel {
    var settings = AppSettings()
    var jobs: [TranslationJob] = []
    var selectedJobID: UUID?
    var selectedChunkIndex = 0
    var page: TranslatorPage = .newJob
    var availableModels: [LMStudioModel] = []
    var connectionText = "未连接"
    var isConnecting = false
    var isWorking = false
    var jobQueue = SerialJobQueue()
    private(set) var hasLoaded = false
    var currentActivity = "等待操作"
    var controllerReasoning = ""
    var controllerOutput = ""
    var translatorStream = ""
    var logLines: [String] = []
    private var displayedLogJobID: UUID?
    var errorMessage: String?
    var selectedAttemptID: UUID?
    var activityGuard = JobActivityGuard()

    @ObservationIgnored private let store = JobStore()
    @ObservationIgnored private var worker: Task<Void, Never>?

    var selectedJob: TranslationJob? { jobs.first { $0.id == selectedJobID } }
    var activeJob: TranslationJob? { activityGuard.activeJobID.flatMap { id in jobs.first { $0.id == id } } }
    func isJobActive(_ id: UUID) -> Bool { activityGuard.activeJobID == id }
    func isJobQueued(_ id: UUID) -> Bool { jobQueue.contains(id) }
    var hasQueuedJobs: Bool { !jobQueue.isEmpty }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            settings = try await store.loadSettings()
            jobs = try await store.loadJobs()
            for index in jobs.indices where [.planning, .running].contains(jobs[index].status) {
                jobs[index].status = .paused
                for chunkIndex in jobs[index].chunks.indices {
                    if jobs[index].chunks[chunkIndex].status == .translating { jobs[index].chunks[chunkIndex].status = .scouted }
                    if jobs[index].chunks[chunkIndex].status == .reviewing { jobs[index].chunks[chunkIndex].status = .translated }
                }
                try await store.save(jobs[index])
            }
            selectedJobID = jobs.first?.id
        } catch {
            hasLoaded = false
            errorMessage = error.localizedDescription
        }
    }

    func loadSelectedJobLog() async {
        guard let jobID = selectedJobID else {
            logLines = []
            displayedLogJobID = nil
            currentActivity = "等待操作"
            return
        }
        let liveLines = displayedLogJobID == jobID ? logLines : []
        if displayedLogJobID != jobID {
            logLines = []
            currentActivity = selectedJob?.status.rawValue ?? "等待操作"
        }
        displayedLogJobID = jobID
        if activityGuard.activeJobID != jobID {
            controllerReasoning = ""
            controllerOutput = ""
            translatorStream = ""
        }
        do {
            let persisted = try await store.loadLog(jobID: jobID)
            guard selectedJobID == jobID else { return }
            var seen = Set<String>()
            let additionalLiveLines = (liveLines + logLines).filter { line in
                !persisted.contains { $0.hasSuffix(line) }
            }
            logLines = Array((persisted + additionalLiveLines).filter { seen.insert($0).inserted }.suffix(300))
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() async {
        do {
            jobs = try await store.loadJobs()
            if let selectedJobID, !jobs.contains(where: { $0.id == selectedJobID }) { self.selectedJobID = jobs.first?.id }
        } catch { errorMessage = error.localizedDescription }
    }

    func connect() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            availableModels = try await client().testConnection()
            connectionText = "已连接 · \(availableModels.filter { $0.type == "llm" }.count) 个模型"
        } catch {
            connectionText = "连接失败"
            errorMessage = error.localizedDescription
        }
    }

    func saveSettings() async {
        do {
            settings.batchSize = min(4, max(2, settings.batchSize))
            settings.maxChunkCharacters = max(256, settings.maxChunkCharacters)
            settings.contextCharacters = max(0, settings.contextCharacters)
            settings.passScore = min(100, max(0, settings.passScore))
            try await store.saveSettings(settings)
        } catch { errorMessage = error.localizedDescription }
    }

    func importFiles(_ urls: [URL], sameStory: Bool, name: String) async {
        do {
            var sources: [SourceDocument] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let text = try TextProcessor.decode(Data(contentsOf: url))
                sources.append(SourceDocument(name: url.lastPathComponent, text: text))
            }
            guard !sources.isEmpty else { return }
            let pipeline = makePipeline()
            if sameStory {
                let job = try await pipeline.createJob(name: name, sources: sources, series: true, settings: settings)
                selectedJobID = job.id
            } else {
                for source in sources {
                    let job = try await pipeline.createJob(name: URL(fileURLWithPath: source.name).deletingPathExtension().lastPathComponent, sources: [source], series: false, settings: settings)
                    selectedJobID = job.id
                }
            }
            await refresh()
            page = .progress
        } catch { errorMessage = error.localizedDescription }
    }

    func startSelected() {
        guard let selectedJobID else { return }
        enqueueJob(selectedJobID)
    }

    func enqueueJob(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), job.status != .completed else { return }
        if jobQueue.enqueue(jobID) {
            if displayedLogJobID == jobID { logLines.append("已加入队列：\(job.name)") }
        }
        if worker == nil { runQueue() }
    }

    func runQueue() {
        guard worker == nil, !jobQueue.isEmpty else { return }
        isWorking = true
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let jobID = self.jobQueue.dequeue() {
                guard self.activityGuard.begin(jobID) else { continue }
                self.currentActivity = "正在启动…"
                self.controllerReasoning = ""
                self.controllerOutput = ""
                self.translatorStream = ""
                let pipeline = self.makePipeline()
                var shouldStopQueue = false
                do {
                    let result = try await pipeline.run(jobID: jobID, settings: self.settings) { [weak self] event in
                        Task { @MainActor in self?.consume(event) }
                    }
                    shouldStopQueue = result.status == .paused
                } catch {
                    self.errorMessage = error.localizedDescription
                }
                self.activityGuard.finish(jobID)
                await self.refresh()
                if shouldStopQueue { break }
            }
            self.isWorking = false
            self.worker = nil
        }
    }

    func pause() {
        worker?.cancel()
        currentActivity = "正在安全暂停…"
    }

    func resumeAfterGuide() {
        startSelected()
    }

    func deleteSelectedJob() async {
        guard let selectedJobID else { return }
        guard activityGuard.canMutate(selectedJobID) else { errorMessage = "请先暂停并等待当前任务停止，再删除任务。"; return }
        do {
            _ = jobQueue.remove(selectedJobID)
            try await store.deleteJob(id: selectedJobID)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func updateGuide(_ guide: TranslationGuide) async {
        guard let selectedJobID else { return }
        guard activityGuard.canMutate(selectedJobID) else { errorMessage = "当前任务运行中，暂停并等待停止后再修改大纲。"; return }
        do {
            _ = try await makePipeline().updateGuide(jobID: selectedJobID, guide: guide)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func editTranslation(chunkIndex: Int, text: String) async {
        guard let selectedJobID else { return }
        guard activityGuard.canMutate(selectedJobID) else { errorMessage = "当前任务运行中，暂停并等待停止后再编辑译文。"; return }
        do {
            _ = try await makePipeline().editTranslation(jobID: selectedJobID, chunkIndex: chunkIndex, translation: text)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func retranslate(chunkIndex: Int, note: String) async {
        guard let selectedJobID else { return }
        guard activityGuard.canMutate(selectedJobID) else { errorMessage = "当前任务运行中，暂停并等待停止后再发起重译。"; return }
        do {
            _ = try await makePipeline().retranslate(jobID: selectedJobID, chunkIndex: chunkIndex, note: note)
            await refresh()
            page = .progress
            startSelected()
        } catch { errorMessage = error.localizedDescription }
    }

    func output(fileIndex: Int) async -> String {
        guard let selectedJob else { return "" }
        return await store.output(for: selectedJob, fileIndex: fileIndex)
    }

    private func client() -> LMStudioClient {
        LMStudioClient(baseURL: settings.baseURL, apiToken: settings.apiToken)
    }

    private func makePipeline() -> TranslationPipeline {
        TranslationPipeline(store: store, client: client())
    }

    private func consume(_ event: PipelineEvent) {
        switch event {
        case .status(let jobID, let message):
            guard selectedJobID == jobID else { return }
            currentActivity = message
        case .activity(let jobID, let role, let action):
            guard selectedJobID == jobID else { return }
            currentActivity = "\(role)：\(action)"
            if role == "主控" { controllerReasoning = ""; controllerOutput = "" } else { translatorStream = "" }
        case .stream(let jobID, let role, let kind, let text):
            guard selectedJobID == jobID else { return }
            if role == "主控" {
                if kind == "reasoning" { controllerReasoning += text } else { controllerOutput += text }
            } else {
                translatorStream += text
            }
        case .chunk(_, _):
            Task { await refresh() }
        case .log(let jobID, let message):
            guard selectedJobID == jobID else { return }
            if displayedLogJobID != jobID { logLines = []; displayedLogJobID = jobID }
            logLines.append(message)
            if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
        }
    }
}
