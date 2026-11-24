import SwiftUI
import TranslatorCore

@main
struct CrystalTranslatorApp: App {
    @State private var model = TranslatorAppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Crystal Translator", id: "translator-main") {
            TranslatorRootView(model: model)
                .frame(minWidth: 1_050, minHeight: 700)
                .task { await model.load() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建翻译任务…") {
                    model.page = .newJob
                    openWindow(id: "translator-main")
                }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        Window("任务速览", id: "compact-progress") {
            CompactProgressWindow(model: model)
                .task { await model.load() }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 412, height: 252)
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
    case diary = "工作区日记"

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
        case .diary: "clock.arrow.circlepath"
        }
    }
}

@MainActor
@Observable
final class TranslatorAppModel {
    private enum ProviderCredentialState: Equatable {
        case checking
        case available
        case missing
        case unavailable(String)
    }

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
    var modelOutputCache = JobModelOutputCache()
    var logLines: [String] = []
    var diaryEntries: [WorkspaceDiaryEntry] = []
    private var displayedLogJobID: UUID?
    var errorMessage: String?
    var selectedAttemptID: UUID?
    var activityGuard = JobActivityGuard()
    private var providerCredentialState: ProviderCredentialState = .checking

    @ObservationIgnored private let store: JobStore
    @ObservationIgnored private let diaryStore: WorkspaceDiaryStore
    @ObservationIgnored private let credentialStore = KeychainCredentialStore()
    @ObservationIgnored private var worker: Task<Void, Never>?

    init() {
        let store = JobStore()
        self.store = store
        self.diaryStore = WorkspaceDiaryStore(rootURL: store.rootURL)
    }

    var selectedJob: TranslationJob? { jobs.first { $0.id == selectedJobID } }
    var activeJob: TranslationJob? { activityGuard.activeJobID.flatMap { id in jobs.first { $0.id == id } } }
    var controllerReasoning: String { modelOutputCache.output(for: selectedJobID).controllerReasoning }
    var controllerOutput: String { modelOutputCache.output(for: selectedJobID).controllerOutput }
    var controllerOutputInProgress: Bool { modelOutputCache.output(for: selectedJobID).isControllerOutputInProgress }
    var translatorStream: String { modelOutputCache.output(for: selectedJobID).translator }
    func activityText(for jobID: UUID, fallback: String) -> String {
        modelOutputCache.activity(for: jobID, fallback: fallback)
    }
    func isJobActive(_ id: UUID) -> Bool { activityGuard.activeJobID == id }
    func isJobQueued(_ id: UUID) -> Bool { jobQueue.contains(id) }
    var hasQueuedJobs: Bool { !jobQueue.isEmpty }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            settings = try await store.loadSettings()
            if try credentialStore.migrateLegacyCredential(in: &settings) {
                try await store.saveSettings(settings)
            }
            refreshProviderCredentialState()
            jobs = try await store.loadJobs()
            diaryEntries = try await diaryStore.load()
            for index in jobs.indices where [.planning, .running].contains(jobs[index].status) {
                jobs[index].status = .paused
                for chunkIndex in jobs[index].chunks.indices {
                    if jobs[index].chunks[chunkIndex].status == .translating { jobs[index].chunks[chunkIndex].status = .scouted }
                    if jobs[index].chunks[chunkIndex].status == .reviewing { jobs[index].chunks[chunkIndex].status = .translated }
                }
                try await store.save(jobs[index])
            }
            selectedJobID = jobs.first?.id
            await recordDiary(level: .info, category: .app, message: "工作区已加载")
        } catch {
            hasLoaded = false
            let message = WorkspaceDiaryStore.redact(error.localizedDescription)
            if error is CredentialStoreError { providerCredentialState = .unavailable(message) }
            errorMessage = message
            await recordDiary(level: .error, category: .app, message: message)
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
            currentActivity = activityText(for: jobID, fallback: selectedJob?.status.rawValue ?? "等待操作")
        }
        displayedLogJobID = jobID
        do {
            let persisted = try await store.loadLog(jobID: jobID)
            guard selectedJobID == jobID else { return }
            var seen = Set<String>()
            let additionalLiveLines = (liveLines + logLines).filter { line in
                !persisted.contains { $0.hasSuffix(line) }
            }
            logLines = Array((persisted + additionalLiveLines).filter { seen.insert($0).inserted }.suffix(300))
        } catch {
            errorMessage = WorkspaceDiaryStore.redact(error.localizedDescription)
            await recordDiary(level: .error, category: .pipeline, jobID: jobID, message: WorkspaceDiaryStore.redact(error.localizedDescription))
        }
    }

    func refresh() async {
        do {
            jobs = try await store.loadJobs()
            if let selectedJobID, !jobs.contains(where: { $0.id == selectedJobID }) { self.selectedJobID = jobs.first?.id }
        } catch {
            errorMessage = WorkspaceDiaryStore.redact(error.localizedDescription)
            await recordDiary(level: .error, category: .app, message: WorkspaceDiaryStore.redact(error.localizedDescription))
        }
    }

    private func refreshJob(_ jobID: UUID) async {
        do {
            guard let updated = try await store.loadJob(id: jobID) else { return }
            if let index = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[index] = updated
            } else {
                jobs.insert(updated, at: 0)
            }
        } catch {
            errorMessage = WorkspaceDiaryStore.redact(error.localizedDescription)
            await recordDiary(level: .error, category: .pipeline, jobID: jobID, message: WorkspaceDiaryStore.redact(error.localizedDescription))
        }
    }

    func connect() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            availableModels = try await client().testConnection()
            connectionText = "已连接 · \(availableModels.filter { $0.type == "llm" }.count) 个模型"
            await recordDiary(level: .info, category: .connection, message: "\(settings.provider.rawValue) 连接成功")
        } catch {
            connectionText = "连接失败"
            errorMessage = WorkspaceDiaryStore.redact(error.localizedDescription)
            await recordDiary(level: .error, category: .connection, message: WorkspaceDiaryStore.redact(error.localizedDescription))
        }
    }

    func saveSettings() async {
        do {
            settings.batchSize = min(4, max(2, settings.batchSize))
            settings.maxChunkCharacters = max(256, settings.maxChunkCharacters)
            settings.contextCharacters = max(0, settings.contextCharacters)
            settings.passScore = min(100, max(0, settings.passScore))
            settings.apiToken = ""
            try await store.saveSettings(settings)
            await recordDiary(level: .info, category: .settings, message: "设置已保存")
        } catch {
            errorMessage = WorkspaceDiaryStore.redact(error.localizedDescription)
            await recordDiary(level: .error, category: .settings, message: WorkspaceDiaryStore.redact(error.localizedDescription))
        }
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
            let pipeline = try makePipeline(requiringCredentials: false)
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
            await recordDiary(level: .info, category: .importing, message: "导入完成（\(sources.count) 个文件）")
        } catch {
            errorMessage = WorkspaceDiaryStore.redact(error.localizedDescription)
            await recordDiary(level: .error, category: .importing, message: WorkspaceDiaryStore.redact(error.localizedDescription))
        }
    }

    func startSelected() {
        guard let selectedJobID else { return }
        enqueueJob(selectedJobID)
    }

    func enqueueJob(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), job.status != .completed else { return }
        if jobQueue.enqueue(jobID) {
            if displayedLogJobID == jobID { logLines.append("已加入队列：\(job.name)") }
            Task { await recordDiary(level: .info, category: .queue, jobID: jobID, message: "任务已加入队列") }
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
                self.updateActivity(jobID: jobID, message: "正在启动…")
                await self.recordDiary(level: .info, category: .queue, jobID: jobID, message: "任务开始运行")
                var shouldStopQueue = false
                do {
                    let pipeline = try self.makePipeline()
                    let result = try await pipeline.run(jobID: jobID, settings: self.settings) { [weak self] event in
                        Task { @MainActor in self?.consume(event) }
                    }
                    shouldStopQueue = result.status == .paused
                    await self.recordDiary(level: result.status == .failed ? .error : .info, category: .queue, jobID: jobID, message: "任务状态：\(result.status.rawValue)")
                } catch {
                    self.errorMessage = WorkspaceDiaryStore.redact(error.localizedDescription)
                    await self.recordDiary(level: .error, category: .queue, jobID: jobID, message: WorkspaceDiaryStore.redact(error.localizedDescription))
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
        if let jobID = activityGuard.activeJobID {
            updateActivity(jobID: jobID, message: "正在安全暂停…")
        } else {
            currentActivity = "正在安全暂停…"
        }
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
            modelOutputCache.remove(jobID: selectedJobID)
            await refresh()
        } catch {
            errorMessage = WorkspaceDiaryStore.redact(error.localizedDescription)
            await recordDiary(level: .error, category: .pipeline, jobID: selectedJobID, message: WorkspaceDiaryStore.redact(error.localizedDescription))
        }
    }

    func updateGuide(_ guide: TranslationGuide) async {
        guard let selectedJobID else { return }
        guard activityGuard.canMutate(selectedJobID) else { errorMessage = "当前任务运行中，暂停并等待停止后再修改大纲。"; return }
        do {
            _ = try await makePipeline(requiringCredentials: false).updateGuide(jobID: selectedJobID, guide: guide)
            await refresh()
        } catch {
            errorMessage = WorkspaceDiaryStore.redact(error.localizedDescription)
            await recordDiary(level: .error, category: .pipeline, jobID: selectedJobID, message: WorkspaceDiaryStore.redact(error.localizedDescription))
        }
    }

    func editTranslation(chunkIndex: Int, text: String) async {
        guard let selectedJobID else { return }
        guard activityGuard.canMutate(selectedJobID) else { errorMessage = "当前任务运行中，暂停并等待停止后再编辑译文。"; return }
        do {
            _ = try await makePipeline(requiringCredentials: false).editTranslation(jobID: selectedJobID, chunkIndex: chunkIndex, translation: text, settings: settings)
            await refresh()
        } catch {
            errorMessage = WorkspaceDiaryStore.redact(error.localizedDescription)
            await recordDiary(level: .error, category: .pipeline, jobID: selectedJobID, message: WorkspaceDiaryStore.redact(error.localizedDescription))
        }
    }

    func retranslate(chunkIndex: Int, note: String) async {
        guard let selectedJobID else { return }
        guard activityGuard.canMutate(selectedJobID) else { errorMessage = "当前任务运行中，暂停并等待停止后再发起重译。"; return }
        do {
            _ = try await makePipeline().retranslate(jobID: selectedJobID, chunkIndex: chunkIndex, note: note)
            await refresh()
            page = .progress
            startSelected()
        } catch {
            errorMessage = WorkspaceDiaryStore.redact(error.localizedDescription)
            await recordDiary(level: .error, category: .pipeline, jobID: selectedJobID, message: WorkspaceDiaryStore.redact(error.localizedDescription))
        }
    }

    func output(jobID: UUID, fileIndex: Int) async -> String {
        (try? await store.output(jobID: jobID, fileIndex: fileIndex)) ?? ""
    }

    func selectProvider(_ provider: ModelProvider) {
        guard settings.provider != provider else { return }
        let oldProvider = settings.provider
        settings.provider = provider
        settings.apiToken = ""
        if provider == .glmCodingPlan {
            if settings.baseURL == "http://127.0.0.1:1234" || oldProvider == .lmStudio {
                settings.baseURL = "https://open.bigmodel.cn/api/coding/paas/v4"
            }
            settings.controllerModel = "glm-5.3-flash"
            settings.translatorModel = "glm-5.3-flash"
            settings.controllerTemperature = 1
            settings.translatorTemperature = 1
            settings.controllerReasoning = "max"
        } else {
            if settings.baseURL == "https://open.bigmodel.cn/api/coding/paas/v4" {
                settings.baseURL = "http://127.0.0.1:1234"
            }
            settings.controllerModel = "hemmingway-1.5-i1"
            settings.translatorModel = "index-translate-9b"
            settings.controllerTemperature = 0.3
            settings.translatorTemperature = 0
            settings.controllerReasoning = "low"
        }
        availableModels = []
        connectionText = "未连接"
        refreshProviderCredentialState()
    }

    var hasProviderCredential: Bool {
        providerCredentialState == .available
    }

    var providerCredentialStatus: String {
        switch providerCredentialState {
        case .checking: "正在检查 Keychain…"
        case .available: "Keychain 中已有凭据"
        case .missing: "尚未保存凭据"
        case .unavailable(let message): "Keychain 访问失败：\(message)"
        }
    }

    private func refreshProviderCredentialState() {
        do {
            providerCredentialState = try credentialStore.credential(for: settings.provider)?.isEmpty == false ? .available : .missing
        } catch {
            let message = WorkspaceDiaryStore.redact(error.localizedDescription)
            providerCredentialState = .unavailable(message)
            errorMessage = message
            Task { await recordDiary(level: .error, category: .settings, message: message) }
        }
    }

    func saveProviderCredential(_ credential: String) async {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try credentialStore.save(value, for: settings.provider)
            providerCredentialState = .available
            await recordDiary(level: .info, category: .settings, message: "模型凭据已保存至 Keychain")
        } catch {
            let message = WorkspaceDiaryStore.redact(error.localizedDescription)
            providerCredentialState = .unavailable(message)
            errorMessage = message
            await recordDiary(level: .error, category: .settings, message: message)
        }
    }

    func clearProviderCredential() async {
        do {
            try credentialStore.delete(for: settings.provider)
            providerCredentialState = .missing
            await recordDiary(level: .info, category: .settings, message: "模型凭据已从 Keychain 移除")
        } catch {
            let message = WorkspaceDiaryStore.redact(error.localizedDescription)
            providerCredentialState = .unavailable(message)
            errorMessage = message
            await recordDiary(level: .error, category: .settings, message: message)
        }
    }

    func reloadDiary() async {
        do { diaryEntries = try await diaryStore.load() }
        catch {
            errorMessage = WorkspaceDiaryStore.redact(error.localizedDescription)
            await recordDiary(level: .error, category: .app, message: WorkspaceDiaryStore.redact(error.localizedDescription))
        }
    }

    func recordDiary(level: WorkspaceDiaryLevel, category: WorkspaceDiaryCategory, jobID: UUID? = nil, message: String) async {
        do {
            try await diaryStore.append(level: level, category: category, jobID: jobID, message: message)
            diaryEntries = try await diaryStore.load()
        } catch {
            if errorMessage == nil { errorMessage = WorkspaceDiaryStore.redact(error.localizedDescription) }
        }
    }

    private func client() throws -> LMStudioClient {
        let token = try credentialStore.credential(for: settings.provider) ?? ""
        if settings.provider == .glmCodingPlan && token.isEmpty {
            throw CredentialStoreError.missingCredential(.glmCodingPlan)
        }
        return LMStudioClient(baseURL: settings.baseURL, apiToken: token, provider: settings.provider)
    }

    private func updateActivity(jobID: UUID, message: String) {
        modelOutputCache.setActivity(jobID: jobID, text: message)
        if selectedJobID == jobID { currentActivity = message }
    }

    private func makePipeline(requiringCredentials: Bool = true) throws -> TranslationPipeline {
        let modelClient: LMStudioClient
        if requiringCredentials {
            modelClient = try client()
        } else {
            modelClient = LMStudioClient(baseURL: settings.baseURL, provider: settings.provider)
        }
        return TranslationPipeline(store: store, client: modelClient)
    }

    private func consume(_ event: PipelineEvent) {
        switch event {
        case .status(let jobID, let message):
            updateActivity(jobID: jobID, message: message)
            Task { await recordDiary(level: .info, category: .pipeline, jobID: jobID, message: message) }
        case .activity(let jobID, let role, let action):
            updateActivity(jobID: jobID, message: "\(role)：\(action)")
            modelOutputCache.begin(jobID: jobID, role: role)
            Task { await recordDiary(level: .info, category: .pipeline, jobID: jobID, message: "\(role)：\(action)") }
        case .stream(let jobID, let role, let kind, let text):
            modelOutputCache.append(jobID: jobID, role: role, kind: kind, text: text)
        case .snapshot(let jobID, let role):
            if ["主控", "预读", "审校"].contains(role) { modelOutputCache.completeController(jobID: jobID) }
            Task { await refreshJob(jobID) }
        case .chunk(_, _):
            Task { await refresh() }
        case .log(let jobID, let message):
            Task { await recordDiary(level: .warning, category: .pipeline, jobID: jobID, message: message) }
            guard selectedJobID == jobID else { return }
            if displayedLogJobID != jobID { logLines = []; displayedLogJobID = jobID }
            logLines.append(message)
            if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
        }
    }
}
