import AppKit
import MacSCPCore

@MainActor
func prompt() -> Int32 {
    guard CommandLine.arguments.count > 1 else { return 1 }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let environment = ProcessInfo.processInfo.environment
    let question = CommandLine.arguments.dropFirst().joined(separator: " ")
    let confirmation = environment["SSH_ASKPASS_PROMPT"] == "confirm"
        || question.contains("Are you sure you want to continue connecting")
    let alert = NSAlert()
    alert.messageText = confirmation ? "确认服务器身份" : "连接服务器"
    alert.informativeText = (environment["MACSCP_SITE_LABEL"] ?? "MacSCP") + "\n\n" + question
    alert.alertStyle = confirmation ? .warning : .informational
    alert.addButton(withTitle: confirmation ? "信任并连接" : "继续")
    alert.addButton(withTitle: "取消")
    let secureField = NSSecureTextField(frame: NSRect(x: 0, y: 35, width: 380, height: 26))
    let remember = NSButton(checkboxWithTitle: "保存到此 Mac 的钥匙串", target: nil, action: nil)
    remember.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
    let account = CredentialStore.account(siteID: environment["MACSCP_SITE_ID"] ?? "",
                                          prompt: (environment["MACSCP_SITE_LABEL"] ?? "") + "\n" + question)
    if !confirmation {
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 65))
        secureField.placeholderString = "密码、私钥口令或验证码"
        secureField.setAccessibilityLabel("认证信息")
        if let saved = CredentialStore.read(account: account) {
            secureField.stringValue = saved
            remember.state = .on
        }
        accessory.addSubview(secureField)
        accessory.addSubview(remember)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = secureField
    }
    let parent = getppid()
    let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        if getppid() != parent || kill(parent, 0) != 0 { exit(1) }
    }
    RunLoop.main.add(timer, forMode: .modalPanel)
    defer { timer.invalidate() }
    app.finishLaunching()
    app.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return 1 }
    if confirmation { print("yes"); return 0 }
    let secret = secureField.stringValue
    guard !secret.contains("\n"), !secret.contains("\r") else { return 1 }
    if remember.state == .on {
        do { try CredentialStore.save(secret, account: account) }
        catch {
            let notice = NSAlert()
            notice.messageText = "未能保存认证信息"
            notice.informativeText = error.localizedDescription
            notice.runModal()
        }
    } else { CredentialStore.remove(account: account) }
    // stdout is the private pipe read by OpenSSH; secrets are never command arguments.
    print(secret)
    return 0
}

exit(prompt())
