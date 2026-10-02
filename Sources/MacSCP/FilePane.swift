import AppKit
import SwiftUI
import MacSCPCore

struct FilePane: View {
    @Bindable var model: AppModel
    let side: PaneSide
    @State private var pathInput = ""
    @State private var sortOrder = [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)]

    private var isLocal: Bool { side == .local }
    private var path: String { isLocal ? model.localPath : model.remotePath }
    private var loading: Bool { isLocal ? model.localLoading : model.remoteLoading }
    private var enabled: Bool { isLocal || (model.isConnected && !model.remotePath.isEmpty) }
    private var selection: Binding<Set<String>> { isLocal ? $model.localSelection : $model.remoteSelection }
    private var filter: Binding<String> { isLocal ? $model.localFilter : $model.remoteFilter }
    private var entries: [FileEntry] {
        let source = isLocal ? model.localEntries : model.remoteEntries
        return source.filter {
            (model.showHidden || !$0.isHidden) && (filter.wrappedValue.isEmpty || $0.name.localizedCaseInsensitiveContains(filter.wrappedValue))
        }.sorted(using: sortOrder).sorted { $0.isDirectory && !$1.isDirectory }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(isLocal ? "本地文件" : "远程文件", systemImage: isLocal ? "laptopcomputer" : "server.rack").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { model.prepareTransfer(isLocal ? .upload : .download) } label: {
                    Label(isLocal ? "上传" : "下载", systemImage: isLocal ? "arrow.up" : "arrow.down")
                }.buttonStyle(.borderedProminent)
                    .disabled(!model.isConnected || selection.wrappedValue.isEmpty || model.remotePath.isEmpty)
            }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)

            HStack(spacing: 7) {
                Button { navigate(RemotePath.parent(path)) } label: { Image(systemName: "arrow.up.to.line") }
                    .help("上一级文件夹").accessibilityLabel("上一级文件夹").disabled(!enabled || path == "/")
                TextField(isLocal ? "本地路径" : "远程路径", text: $pathInput)
                    .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                    .onSubmit { navigate(pathInput) }.disabled(!enabled)
                    .accessibilityLabel(isLocal ? "本地路径，回车打开" : "远程路径，回车打开")
                if isLocal {
                    Button { model.chooseLocalFolder() } label: { Image(systemName: "folder") }
                        .help("选择文件夹").accessibilityLabel("选择本地文件夹")
                } else {
                    Button { navigate(".") } label: { Image(systemName: "house") }
                        .help("服务器主目录").accessibilityLabel("服务器主目录").disabled(!enabled)
                }
            }.padding(.horizontal, 14).padding(.bottom, 10)
            Divider()
            Table(entries, selection: selection, sortOrder: $sortOrder) {
                TableColumn("名称", value: \.name) { entry in
                    HStack(spacing: 7) {
                        Image(systemName: entry.symbol)
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                            .frame(width: 18).accessibilityHidden(true)
                        Text(entry.name).lineLimit(1).help(entry.name)
                    }
                }.width(min: 145, ideal: 230)
                TableColumn("大小", value: \.size) { entry in
                    Text(entry.sizeLabel).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }.width(70)
                TableColumn("修改时间") { entry in
                    if let date = entry.modified {
                        Text(date, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    } else { Text("—").foregroundStyle(.secondary) }
                }.width(112)
            }
            .contextMenu(forSelectionType: String.self) { selected in
                if !selected.isEmpty {
                    Button(isLocal ? "上传…" : "下载…") {
                        selection.wrappedValue = selected
                        model.prepareTransfer(isLocal ? .upload : .download)
                    }.disabled(!model.isConnected)
                    Button("重命名…") {
                        selection.wrappedValue = selected
                        model.prepareAction(.rename, side: side)
                    }.disabled(selected.count != 1)
                    Button(isLocal ? "移到废纸篓…" : "删除…", role: .destructive) {
                        selection.wrappedValue = selected
                        model.prepareAction(.delete, side: side)
                    }
                    Divider()
                    Button("复制路径") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(selected.sorted().joined(separator: "\n"), forType: .string)
                    }
                }
                Button("新建文件夹…") { model.prepareAction(.createFolder, side: side) }.disabled(!enabled)
                Button("刷新") { navigate(path) }.disabled(!enabled)
            } primaryAction: { selected in
                guard let id = selected.first, let entry = entries.first(where: { $0.id == id }) else { return }
                if entry.isDirectory || entry.kind == .symbolicLink { navigate(entry.path) }
                else if isLocal { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
                else { selection.wrappedValue = selected; model.prepareTransfer(.download) }
            }
            .overlay {
                if !enabled && loading {
                    ProgressView("正在读取远程目录…")
                } else if !enabled {
                    ContentUnavailableView {
                        Label("远程文件，近在眼前", systemImage: "externaldrive.connected.to.line.below")
                    } description: {
                        Text("添加服务器连接，开始浏览与传输。")
                    } actions: {
                        Button("新建连接") { model.editor = Site() }.buttonStyle(.borderedProminent)
                    }
                } else if entries.isEmpty && !loading {
                    ContentUnavailableView(filter.wrappedValue.isEmpty ? "文件夹为空" : "没有匹配的文件", systemImage: "folder")
                }
            }
            Divider()
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("筛选文件", text: filter).textFieldStyle(.plain).disabled(!enabled)
                Text(selection.wrappedValue.isEmpty ? "\(entries.count) 项" : "已选 \(selection.wrappedValue.count) 项")
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
                Button { model.prepareAction(.createFolder, side: side) } label: { Image(systemName: "folder.badge.plus") }
                    .help("新建文件夹").accessibilityLabel("新建文件夹").disabled(!enabled)
            }.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { pathInput = path }
        .onChange(of: path) { _, value in pathInput = value }
        .onChange(of: filter.wrappedValue) { _, _ in retainVisibleSelection() }
        .onChange(of: model.showHidden) { _, _ in retainVisibleSelection() }
    }

    private func navigate(_ destination: String) {
        Task {
            if isLocal { await model.loadLocal(destination) }
            else { await model.loadRemote(destination) }
            pathInput = path
        }
    }

    private func retainVisibleSelection() {
        selection.wrappedValue.formIntersection(Set(entries.map(\.id)))
    }
}

#Preview { FilePane(model: AppModel(), side: .local).frame(width: 500, height: 600) }
