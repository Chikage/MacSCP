import Foundation

public enum AppPaths {
    public static var support: URL {
        #if DEBUG
        if let directory = ProcessInfo.processInfo.environment["MACSCP_TEST_SUPPORT"] {
            return URL(fileURLWithPath: directory, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacSCP", isDirectory: true)
    }

    public static func prepare() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
}

public struct SSHContext: Sendable {
    public let site: Site
    let socketPath: String
    let environment: [String: String]
    let knownHostsPath: String

    func arguments() -> [String] {
        ["-F", "/dev/null", "-T", "-S", socketPath,
         "-o", "ControlMaster=no", "-o", "BatchMode=yes",
         "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\"\(knownHostsPath)\"",
         "-o", "ProxyCommand=/usr/bin/false",
         "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
         "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes",
         "-p", String(site.port), "-l", site.username]
    }

    func channel(command: String, cancellation: CancellationFlag) throws -> ProcessChannel {
        try ProcessChannel(executable: "/usr/bin/ssh", arguments: arguments() + [site.host, command],
                           environment: environment, cancellation: cancellation)
    }

    func sftpChannel(cancellation: CancellationFlag) throws -> ProcessChannel {
        try ProcessChannel(executable: "/usr/bin/ssh", arguments: arguments() + ["-s", site.host, "sftp"],
                           environment: environment, cancellation: cancellation)
    }
}

/// The master channel is accessed only under lock after construction. Each file
/// operation owns a separate multiplexed SSH channel and its own cancellation flag.
public final class SSHSession: @unchecked Sendable {
    public let context: SSHContext
    private let lock = NSLock()
    private var master: ProcessChannel?
    private let socketDirectory: URL

    private init(context: SSHContext, master: ProcessChannel, socketDirectory: URL) {
        self.context = context
        self.master = master
        self.socketDirectory = socketDirectory
    }

    public static func connect(site: Site, askPassPath: String, cancellation: CancellationFlag,
                               knownHostsFile: URL? = nil) async throws -> SSHSession {
        try await Background.run(cancellation: cancellation) {
            let site = try site.validated()
            try AppPaths.prepare()
            guard FileManager.default.isExecutableFile(atPath: askPassPath) else {
                throw MacSCPError.message("找不到认证助手，请使用打包后的 MacSCP.app。")
            }
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mscp-" + UUID().uuidString.prefix(8), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let socket = directory.appendingPathComponent("s").path
            // macOS Unix-domain socket addresses are limited to 104 bytes.
            guard socket.utf8.count < 104 else {
                try? FileManager.default.removeItem(at: directory)
                throw MacSCPError.message("系统临时目录路径过长，无法建立 SSH 控制通道。")
            }
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS"] = askPassPath
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "MacSCP"
            environment["MACSCP_SITE_ID"] = site.id.uuidString
            environment["MACSCP_SITE_LABEL"] = site.address
            let hostsPath = knownHostsFile?.path ?? AppPaths.support.appendingPathComponent("known_hosts").path
            let context = SSHContext(site: site, socketPath: socket, environment: environment, knownHostsPath: hostsPath)
            var arguments = ["-F", "/dev/null", "-M", "-N", "-T", "-S", socket,
                             "-o", "ControlPersist=no", "-o", "StrictHostKeyChecking=ask",
                             "-o", "UserKnownHostsFile=\"\(hostsPath)\"",
                             "-o", "UpdateHostKeys=no", "-o", "ConnectTimeout=15",
                             "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=15",
                             "-o", "ServerAliveCountMax=2", "-o", "NumberOfPasswordPrompts=2",
                             "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes",
                             "-o", "LogLevel=ERROR", "-p", String(site.port), "-l", site.username]
            switch site.authentication {
            case .agent:
                arguments += ["-o", "PreferredAuthentications=publickey"]
            case .password:
                arguments += ["-o", "PreferredAuthentications=keyboard-interactive,password", "-o", "PubkeyAuthentication=no"]
            case .privateKey:
                arguments += ["-i", site.privateKeyPath, "-o", "IdentitiesOnly=yes", "-o", "PreferredAuthentications=publickey"]
            }
            arguments.append(site.host)
            do {
                let master = try ProcessChannel(executable: "/usr/bin/ssh", arguments: arguments,
                                                environment: environment, cancellation: cancellation)
                let deadline = Date().addingTimeInterval(300)
                while !FileManager.default.fileExists(atPath: socket) {
                    try cancellation.check()
                    guard master.isRunning else {
                        try master.finish()
                        throw MacSCPError.message("SSH 连接未能建立。")
                    }
                    guard Date() < deadline else { throw MacSCPError.message("等待认证超时，请重试。") }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                return SSHSession(context: context, master: master, socketDirectory: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
    }

    public var isConnected: Bool { lock.withLock { master?.isRunning == true } }

    public func disconnect() {
        lock.withLock { master?.stop(); master = nil }
        try? FileManager.default.removeItem(at: socketDirectory)
    }

    deinit { disconnect() }
}

enum Background {
    static func run<T: Sendable>(cancellation: CancellationFlag,
                                _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try operation() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.cancel()
            task.cancel()
        }
    }
}
