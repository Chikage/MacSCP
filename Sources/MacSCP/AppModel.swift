import AppKit
import MacSCPCore
import Observation

enum TransferState: String { case waiting = "等待中", running = "传输中", completed = "已完成", failed = "失败", cancelled = "已取消" }

struct TransferItem: Identifiable {
    let request: TransferRequest
    let site: Site
    var state: TransferState = .waiting
    var progress = TransferProgress()
    var error: String?
    var started: Date?
    var id: UUID { request.id }
}

struct Notice: Identifiable { let id = UUID(); let message: String }
struct TransferDraft: Identifiable {
    let id = UUID()
    let direction: TransferDirection
    let entries: [FileEntry]
    let destination: String
    var sessionID: UUID? = nil
}

enum PaneSide { case local, remote }
enum FileActionKind { case createFolder, rename, delete }
struct FileAction: Identifiable {
    let id = UUID()
    let kind: FileActionKind
    let side: PaneSide
    let directory: String
    let entries: [FileEntry]
    var sessionID: UUID? = nil
    var title: String {
        switch kind {
        case .createFolder: "新建文件夹"
        case .rename: "重命名"
        case .delete: side == .local ? "移到废纸篓" : "删除远程项目"
        }
    }
}

@MainActor @Observable
final class AppModel {
    var sites: [Site] = []
    var selectedSiteID: UUID?
    var editor: Site?
    var transferDraft: TransferDraft?
    var fileAction: FileAction?
    var notice: Notice?
    var localPath = FileManager.default.homeDirectoryForCurrentUser.path
    var remotePath = ""
    var localEntries: [FileEntry] = []
    var remoteEntries: [FileEntry] = []
    var localSelection: Set<String> = []
    var remoteSelection: Set<String> = []
    var localFilter = ""
    var remoteFilter = ""
    var showHidden = false
    var localLoading = false
    var remoteLoading = false
    var connecting = false
    var connectedSite: Site?
    var status = "准备就绪"
    var transfers: [TransferItem] = []
    var showQueue = true
    private let siteStore = SiteStore()
    private var session: SSHSession?
    private var connectionFlag: CancellationFlag?
    private var browseFlag: CancellationFlag?
    private var transferFlag: CancellationFlag?
    private var queueTask: Task<Void, Never>?
    private var sessionGeneration = UUID()
    private var localGeneration = UUID()
    private var remoteGeneration = UUID()

    var isConnected: Bool { connectedSite != nil }
    var hasActiveTransfers: Bool { transfers.contains { $0.state == .running || $0.state == .waiting } }
    var canConnect: Bool { !connecting && !isConnected && queueTask == nil }
    var selectedSite: Site? { sites.first { $0.id == selectedSiteID } }
    var selectedLocal: [FileEntry] { localEntries.filter { localSelection.contains($0.id) } }
    var selectedRemote: [FileEntry] { remoteEntries.filter { remoteSelection.contains($0.id) } }

    func start() async {
        do { sites = try await siteStore.load() }
        catch { showError(error) }
        await loadLocal(localPath)
    }

    func saveSite(_ site: Site) {
        if let index = sites.firstIndex(where: { $0.id == site.id }) { sites[index] = site }
        else { sites.append(site) }
        selectedSiteID = site.id
        persistSites()
    }

    func monitorConnection() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if let session, !session.isConnected {
                disconnect()
                status = "连接已中断，请重新连接"
            }
        }
    }

    func removeSite(_ site: Site) {
        sites.removeAll { $0.id == site.id }
        if selectedSiteID == site.id { selectedSiteID = nil }
        persistSites()
    }

    private func persistSites() {
        let snapshot = sites
        Task { do { try await siteStore.save(snapshot) } catch { showError(error) } }
    }

    func connect(_ site: Site) {
        guard canConnect else { return }
        connecting = true
        status = "正在连接 \(site.host)…"
        let flag = CancellationFlag()
        connectionFlag = flag
        let generation = UUID()
        sessionGeneration = generation
        Task {
            do {
                let helper = Bundle.main.bundleURL
                    .appendingPathComponent("Contents/Helpers/MacSCPAskPass.app/Contents/MacOS/MacSCPAskPass").path
                let connected = try await SSHSession.connect(site: site, askPassPath: helper, cancellation: flag)
                guard sessionGeneration == generation, !flag.isCancelled else { connected.disconnect(); return }
                session = connected
                connectedSite = site
                selectedSiteID = site.id
                connecting = false
                status = "已连接到 \(site.address)"
                async let local: Void = loadLocal(site.localPath)
                async let remote: Void = loadRemote(site.remotePath)
                _ = await (local, remote)
            } catch {
                guard sessionGeneration == generation else { return }
                connecting = false
                status = flag.isCancelled ? "连接已取消" : "连接失败"
                if !flag.isCancelled { showError(error) }
            }
        }
    }

    func disconnect() {
        sessionGeneration = UUID()
        remoteGeneration = UUID()
        connectionFlag?.cancel()
        browseFlag?.cancel()
        transferFlag?.cancel()
        queueTask?.cancel()
        for index in transfers.indices where transfers[index].state == .waiting { transfers[index].state = .cancelled }
        session?.disconnect()
        session = nil
        connectedSite = nil
        connecting = false
        remoteLoading = false
        remoteEntries = []
        remoteSelection = []
        remotePath = ""
        status = "已断开连接"
    }

    func loadLocal(_ path: String) async {
        let generation = UUID()
        localGeneration = generation
        localLoading = true
        defer { if localGeneration == generation { localLoading = false } }
        do {
            let listing = try await LocalFiles.list(path)
            guard localGeneration == generation else { return }
            localPath = listing.path
            localEntries = listing.entries
            localSelection = localSelection.intersection(Set(listing.entries.map(\.id)))
        } catch { if localGeneration == generation { showError(error) } }
    }

    func loadRemote(_ path: String) async {
        guard let session else { return }
        browseFlag?.cancel()
        let flag = CancellationFlag()
        browseFlag = flag
        let generation = UUID()
        remoteGeneration = generation
        remoteLoading = true
        defer { if remoteGeneration == generation { remoteLoading = false } }
        do {
            var requested = path
            if requested == "~" { requested = "." }
            else if requested.hasPrefix("~/") { requested = String(requested.dropFirst(2)) }
            let listing = try await RemoteOperations.list(requested, context: session.context, cancellation: flag)
            guard generation == remoteGeneration, !flag.isCancelled else { return }
            remotePath = listing.path
            remoteEntries = listing.entries
            remoteSelection = remoteSelection.intersection(Set(listing.entries.map(\.id)))
            status = "已连接到 \(session.context.site.address)"
        } catch {
            guard generation == remoteGeneration, !flag.isCancelled else { return }
            if !session.isConnected { disconnect(); status = "连接已中断，请重新连接" }
            showError(error)
        }
    }

    func refresh() {
        Task {
            async let local: Void = loadLocal(localPath)
            async let remote: Void = loadRemote(remotePath)
            _ = await (local, remote)
        }
    }

    func prepareTransfer(_ direction: TransferDirection) {
        let entries = direction == .upload ? selectedLocal : selectedRemote
        guard isConnected, !entries.isEmpty, !remotePath.isEmpty else { return }
        transferDraft = TransferDraft(direction: direction, entries: entries,
                                      destination: direction == .upload ? remotePath : localPath, sessionID: sessionGeneration)
    }

    func enqueue(_ draft: TransferDraft, policy: ConflictPolicy) {
        guard let connectedSite, draft.sessionID == sessionGeneration else {
            notice = Notice(message: "连接已改变，请重新选择传输项目。")
            return
        }
        transfers.append(TransferItem(request: TransferRequest(direction: draft.direction, entries: draft.entries,
                                                              destination: draft.destination, conflictPolicy: policy), site: connectedSite))
        showQueue = true
        runQueue()
    }

    private func runQueue() {
        guard queueTask == nil, let session else { return }
        let generation = sessionGeneration
        queueTask = Task { [self] in
            while !Task.isCancelled, generation == sessionGeneration,
                  let index = transfers.firstIndex(where: { $0.state == .waiting }) {
                let request = transfers[index].request
                transfers[index].state = .running
                transfers[index].started = Date()
                let flag = CancellationFlag()
                transferFlag = flag
                do {
                    let result = try await TransferEngine.run(request, context: session.context, cancellation: flag) { [weak self] progress in
                        Task { @MainActor in
                            guard let self, let i = self.transfers.firstIndex(where: { $0.id == request.id }),
                                  self.transfers[i].state == .running else { return }
                            self.transfers[i].progress = progress
                        }
                    }
                    if let i = transfers.firstIndex(where: { $0.id == request.id }) {
                        transfers[i].progress = result
                        transfers[i].state = flag.isCancelled ? .cancelled : .completed
                    }
                } catch {
                    if let i = transfers.firstIndex(where: { $0.id == request.id }) {
                        transfers[i].state = flag.isCancelled ? .cancelled : .failed
                        transfers[i].error = error.localizedDescription
                    }
                }
            }
            queueTask = nil
            transferFlag = nil
            if generation == sessionGeneration { refresh() }
        }
    }

    func cancelTransfer(_ item: TransferItem) {
        if item.state == .running { transferFlag?.cancel() }
        else if let index = transfers.firstIndex(where: { $0.id == item.id }), item.state == .waiting {
            transfers[index].state = .cancelled
        }
    }

    func retryTransfer(_ item: TransferItem) {
        guard let connectedSite, connectedSite == item.site else { return }
        let request = item.request
        transfers.append(TransferItem(request: TransferRequest(direction: request.direction, entries: request.entries,
                                                              destination: request.destination, conflictPolicy: request.conflictPolicy), site: connectedSite))
        runQueue()
    }

    func clearCompleted() { transfers.removeAll { $0.state != .running && $0.state != .waiting } }

    func prepareAction(_ kind: FileActionKind, side: PaneSide) {
        let entries = side == .local ? selectedLocal : selectedRemote
        if side == .remote && (!isConnected || remotePath.isEmpty || remoteLoading) { return }
        if kind != .createFolder && entries.isEmpty { return }
        fileAction = FileAction(kind: kind, side: side, directory: side == .local ? localPath : remotePath,
                                entries: entries, sessionID: sessionGeneration)
    }

    func performAction(_ action: FileAction, name: String) {
        guard action.side == .local || action.sessionID == sessionGeneration else {
            notice = Notice(message: "连接已改变，请重新选择文件操作。")
            return
        }
        let context = session?.context
        Task {
            do {
                if action.kind != .delete { try RemotePath.validateName(name) }
                let target = RemotePath.join(action.directory, name)
                if action.side == .remote {
                    guard let context else { throw MacSCPError.message("请先连接服务器。") }
                    switch action.kind {
                    case .createFolder: try await RemoteOperations.createDirectory(target, context: context)
                    case .rename:
                        if let entry = action.entries.first { try await RemoteOperations.rename(entry.path, to: target, context: context) }
                    case .delete: try await RemoteOperations.delete(action.entries, context: context, cancellation: CancellationFlag())
                    }
                } else {
                    try await Task.detached {
                        switch action.kind {
                        case .createFolder:
                            try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
                        case .rename:
                            if let entry = action.entries.first { try FileManager.default.moveItem(atPath: entry.path, toPath: target) }
                        case .delete:
                            for entry in action.entries { try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil) }
                        }
                    }.value
                }
                refresh()
            } catch { showError(error) }
        }
    }

    func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: localPath)
        panel.prompt = "打开文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await loadLocal(url.path) }
    }

    func showError(_ error: Error) { notice = Notice(message: error.localizedDescription) }
}
