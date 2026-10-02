import SwiftUI
import MacSCPCore

struct WorkspaceView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 270)
        } detail: {
            VStack(spacing: 0) {
                connectionBar
                Divider()
                HSplitView {
                    FilePane(model: model, side: .local).frame(minWidth: 360)
                    FilePane(model: model, side: .remote).frame(minWidth: 360)
                }
                if model.showQueue {
                    Divider()
                    TransferQueueView(model: model).frame(height: 190)
                }
                Divider()
                statusBar
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("MacSCP")
        .toolbar {
            ToolbarItemGroup {
                Button { model.editor = Site() } label: { Label("新建连接", systemImage: "plus") }
                    .help("新建连接 ⌘N")
                if model.isConnected || model.connecting {
                    Button { model.disconnect() } label: {
                        Label(model.connecting ? "取消连接" : "断开连接", systemImage: "stop.circle")
                    }
                } else {
                    Button { if let site = model.selectedSite { model.connect(site) } else { model.editor = Site() } } label: {
                        Label("连接", systemImage: "bolt.horizontal")
                    }.disabled(!model.canConnect)
                }
                Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }.help("刷新 ⌘R")
                Button { model.showQueue.toggle() } label: { Label("传输队列", systemImage: "list.bullet.below.rectangle") }
                    .help("显示或隐藏传输队列 ⌘J")
            }
        }
        .sheet(item: $model.editor) { site in
            SiteEditor(site: site, canConnect: model.canConnect) { updated, connect in
                model.saveSite(updated)
                model.editor = nil
                if connect { model.connect(updated) }
            }
        }
        .sheet(item: $model.transferDraft) { draft in
            TransferSheet(draft: draft) { policy in model.enqueue(draft, policy: policy); model.transferDraft = nil }
        }
        .sheet(item: $model.fileAction) { action in
            FileActionSheet(action: action) { name in model.performAction(action, name: name); model.fileAction = nil }
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text("操作未完成"), message: Text(notice.message), dismissButton: .default(Text("好")))
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right.square.fill")
                    .font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacSCP").font(.headline)
                    Text("安全文件传输").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(18)
            List(selection: $model.selectedSiteID) {
                Section("已保存的站点") {
                    if model.sites.isEmpty {
                        Text("添加常用服务器，\n下次一键连接。")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
                    }
                    ForEach(model.sites) { site in
                        HStack(spacing: 8) {
                            Image(systemName: "server.rack").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(site.displayName).lineLimit(1)
                                Text(site.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if model.connectedSite?.id == site.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("已连接")
                            }
                        }.padding(.vertical, 3).tag(site.id)
                    }
                }
                Section("此 Mac") {
                    localShortcut("个人文件夹", symbol: "house", component: "")
                    localShortcut("下载", symbol: "arrow.down.circle", component: "Downloads")
                    localShortcut("文稿", symbol: "doc.on.doc", component: "Documents")
                    Button { model.chooseLocalFolder() } label: { Label("打开文件夹…", systemImage: "folder") }
                        .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: UUID.self) { selection in
                if let id = selection.first, let site = model.sites.first(where: { $0.id == id }) {
                    Button("连接") { model.connect(site) }.disabled(!model.canConnect)
                    Button("编辑站点…") { model.editor = site }
                    Divider()
                    Button("移除站点", role: .destructive) { model.removeSite(site) }
                }
            } primaryAction: { selection in
                if let id = selection.first, let site = model.sites.first(where: { $0.id == id }) { model.connect(site) }
            }
            Divider()
            HStack {
                Image(systemName: "cpu")
                Text("Apple Silicon").font(.caption)
                Spacer()
                Text("0.1").font(.caption.monospacedDigit())
            }.foregroundStyle(.secondary).padding(14)
        }
    }

    private func localShortcut(_ title: String, symbol: String, component: String) -> some View {
        Button {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(component)
            Task { await model.loadLocal(url.path) }
        } label: { Label(title, systemImage: symbol) }.buttonStyle(.plain)
    }

    private var connectionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isConnected ? "lock.shield.fill" : "network")
                .font(.title2).foregroundStyle(model.isConnected ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.connectedSite?.displayName ?? (model.connecting ? "正在建立安全连接" : "连接你的服务器"))
                    .font(.headline)
                Text(model.connectedSite?.address ?? (model.connecting ? "请在认证窗口中完成登录" : "通过 SCP 或 SFTP，在 Mac 与服务器之间传输文件"))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.connecting { ProgressView().controlSize(.small) }
            if let site = model.connectedSite {
                Text(site.transferProtocol.rawValue).font(.caption.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Image(systemName: model.isConnected ? "checkmark.shield" : "circle.dotted")
            Text(model.status).lineLimit(1)
            Spacer()
            Toggle("隐藏文件", isOn: $model.showHidden).toggleStyle(.checkbox)
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
    }
}

#Preview { WorkspaceView(model: AppModel()).frame(width: 1240, height: 800) }
