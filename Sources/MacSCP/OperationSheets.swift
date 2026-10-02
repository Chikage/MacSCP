import SwiftUI
import MacSCPCore

struct TransferSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var policy: ConflictPolicy = .skip
    let draft: TransferDraft
    let confirm: (ConflictPolicy) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(draft.direction == .upload ? "上传到服务器" : "下载到此 Mac",
                  systemImage: draft.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text("\(draft.entries.count) 个项目").font(.headline)
                ForEach(draft.entries.prefix(4)) { entry in
                    Label(entry.name, systemImage: entry.symbol).lineLimit(1)
                }
                if draft.entries.count > 4 { Text("以及另外 \(draft.entries.count - 4) 项").foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("目标文件夹").font(.caption).foregroundStyle(.secondary)
                Text(draft.destination).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            Picker("遇到同名文件", selection: $policy) {
                ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.radioGroup)
            Text("文件夹会合并；符号链接和特殊文件会跳过。已有文件只在传输成功后替换。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("加入传输队列") { confirm(policy) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480)
    }
}

struct FileActionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    let action: FileAction
    let confirm: (String) -> Void

    init(action: FileAction, confirm: @escaping (String) -> Void) {
        self.action = action
        self.confirm = confirm
        _name = State(initialValue: action.kind == .rename ? action.entries.first?.name ?? "" : "未命名文件夹")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(action.title).font(.title2.weight(.semibold))
            if action.kind == .delete {
                Text(action.side == .remote
                     ? "将永久删除选中的 \(action.entries.count) 个远程项目及其内容。此操作无法撤销。"
                     : "将选中的 \(action.entries.count) 个本地项目移到废纸篓。")
                Text(action.entries.prefix(5).map(\.name).joined(separator: "\n"))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(5)
            } else {
                TextField("名称", text: $name).textFieldStyle(.roundedBorder)
                Text(action.directory).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(action.kind == .delete ? action.title : "确定", role: action.kind == .delete ? .destructive : nil) {
                    do {
                        if action.kind != .delete { try RemotePath.validateName(name) }
                        confirm(name)
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 450)
    }
}

#Preview { TransferSheet(draft: TransferDraft(direction: .upload, entries: [], destination: "/home/user")) { _ in } }
