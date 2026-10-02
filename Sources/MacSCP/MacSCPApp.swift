import AppKit
import SwiftUI

@main
struct MacSCPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        Window("MacSCP", id: "main") {
            WorkspaceView(model: model)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task { delegate.model = model; await model.start(); await model.monitorConnection() }
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建连接…") { model.editor = .init() }.keyboardShortcut("n")
            }
            CommandMenu("传输") {
                Button("上传所选项目…") { model.prepareTransfer(.upload) }
                    .keyboardShortcut("u").disabled(!model.isConnected || model.selectedLocal.isEmpty)
                Button("下载所选项目…") { model.prepareTransfer(.download) }
                    .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(!model.isConnected || model.selectedRemote.isEmpty)
                Divider()
                Button("刷新文件列表") { model.refresh() }.keyboardShortcut("r")
                Toggle("显示隐藏文件", isOn: $model.showHidden).keyboardShortcut(".", modifiers: [.command, .shift])
                Toggle("显示传输队列", isOn: $model.showQueue).keyboardShortcut("j")
            }
        }
        Settings {
            Form {
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                LabeledContent("版本", value: "0.1.0 · Apple Silicon")
                Text("主机指纹和站点保存在此 Mac。认证信息仅在选择保存后写入系统钥匙串。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("打开配置文件夹") {
                    do {
                        try AppPaths.prepare()
                        NSWorkspace.shared.open(AppPaths.support)
                    } catch { model.showError(error) }
                }
            }.formStyle(.grouped).padding().frame(width: 440)
        }
    }
}

import MacSCPCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.hasActiveTransfers == true {
            let alert = NSAlert()
            alert.messageText = "停止传输并退出？"
            alert.informativeText = "未完成的传输将被取消，已存在的目标文件会保留。"
            alert.addButton(withTitle: "停止并退出")
            alert.addButton(withTitle: "继续传输")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        model?.disconnect()
        return .terminateNow
    }
}
