import AppKit
import SwiftUI
import MacSCPCore

struct SiteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var site: Site
    @State private var port: String
    @State private var error: String?
    let canConnect: Bool
    let save: (Site, Bool) -> Void

    init(site: Site, canConnect: Bool, save: @escaping (Site, Bool) -> Void) {
        _site = State(initialValue: site)
        _port = State(initialValue: String(site.port))
        self.canConnect = canConnect
        self.save = save
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("服务器连接").font(.title2.weight(.semibold))
                    Text("保存你的站点，安全连接每一次。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Form {
                Section {
                    TextField("站点名称", text: $site.name, prompt: Text("例如：开发服务器"))
                    Picker("传输协议", selection: $site.transferProtocol) {
                        ForEach(TransferProtocol.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    TextField("主机", text: $site.host, prompt: Text("192.168.1.10 或 example.com"))
                        .autocorrectionDisabled()
                    TextField("端口", text: $port).frame(maxWidth: 200, alignment: .leading)
                    TextField("用户名", text: $site.username).autocorrectionDisabled()
                }
                Section("认证") {
                    Picker("登录方式", selection: $site.authentication) {
                        ForEach(Authentication.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if site.authentication == .privateKey {
                        HStack {
                            TextField("私钥路径", text: $site.privateKeyPath)
                            Button("选择…") { chooseKey() }
                        }
                    }
                    Text(site.authentication == .password
                         ? "连接时输入密码或验证码，可选择保存到系统钥匙串。"
                         : "支持 OpenSSH 私钥。加密私钥的口令会在连接时询问。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("初始文件夹") {
                    TextField("本地", text: $site.localPath)
                    TextField("远程", text: $site.remotePath, prompt: Text(". 表示服务器主目录"))
                    if site.transferProtocol == .scp {
                        Text("SCP 模式适用于提供 SSH Shell 的服务器，需要远程系统支持 scp、sh 和 stat。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存站点") { submit(connect: false) }
                Button("保存并连接") { submit(connect: true) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canConnect)
            }.padding(20)
        }.frame(width: 560, height: 690)
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.prompt = "选择私钥"
        if panel.runModal() == .OK, let url = panel.url { site.privateKeyPath = url.path }
    }

    private func submit(connect: Bool) {
        do {
            guard let value = Int(port) else { throw MacSCPError.message("请输入有效的端口数字。") }
            site.port = value
            let validated = try site.validated()
            save(validated, connect)
        } catch { self.error = error.localizedDescription }
    }
}

#Preview { SiteEditor(site: Site(), canConnect: true) { _, _ in } }
