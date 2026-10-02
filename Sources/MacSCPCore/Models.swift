import Foundation

public enum TransferProtocol: String, Codable, CaseIterable, Sendable {
    case sftp = "SFTP"
    case scp = "SCP"
}

public enum Authentication: String, Codable, CaseIterable, Sendable {
    case agent, password, privateKey

    public var title: String {
        switch self {
        case .agent: "SSH Agent / 默认密钥"
        case .password: "密码"
        case .privateKey: "私钥文件"
        }
    }
}

public struct Site: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name = ""
    public var host = ""
    public var port = 22
    public var username = NSUserName()
    public var transferProtocol: TransferProtocol = .sftp
    public var authentication: Authentication = .agent
    public var privateKeyPath = ""
    public var remotePath = "."
    public var localPath = FileManager.default.homeDirectoryForCurrentUser.path

    public init() {}
    public var displayName: String { name.isEmpty ? host : name }
    public var address: String { "\(username)@\(host):\(port)" }

    public func validated() throws -> Site {
        var site = self
        site.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if site.host.hasPrefix("["), site.host.hasSuffix("]") {
            site.host = String(site.host.dropFirst().dropLast())
        }
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%")
        let userCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !site.host.isEmpty, !site.host.hasPrefix("-"),
              site.host.unicodeScalars.allSatisfy(hostCharacters.contains) else {
            throw MacSCPError.message("请输入有效的主机名或 IP 地址，不要包含协议或路径。")
        }
        guard !username.isEmpty, !username.hasPrefix("-"),
              username.unicodeScalars.allSatisfy(userCharacters.contains) else {
            throw MacSCPError.message("用户名只能包含字母、数字、点、下划线和连字符。")
        }
        guard (1...65535).contains(port) else { throw MacSCPError.message("端口必须在 1–65535 之间。") }
        if authentication == .privateKey {
            site.privateKeyPath = NSString(string: privateKeyPath).expandingTildeInPath
            guard FileManager.default.isReadableFile(atPath: site.privateKeyPath) else {
                throw MacSCPError.message("无法读取私钥文件，请重新选择。")
            }
        }
        try RemotePath.validate(site.remotePath)
        return site
    }
}

public enum FileKind: String, Sendable { case file, directory, symbolicLink, other }

public struct FileEntry: Identifiable, Sendable, Equatable {
    public let name: String
    public let path: String
    public let kind: FileKind
    public let size: UInt64
    public let modified: Date?
    public let permissions: UInt32
    public var id: String { path }
    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }
    public var sizeLabel: String {
        isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
    }
    public var symbol: String {
        switch kind {
        case .directory: "folder.fill"
        case .symbolicLink: "link"
        case .other: "questionmark.square"
        case .file:
            switch URL(fileURLWithPath: name).pathExtension.lowercased() {
            case "png", "jpg", "jpeg", "heic", "gif", "svg": "photo"
            case "zip", "gz", "tar", "dmg": "doc.zipper"
            case "swift", "py", "js", "ts", "json", "sh", "html", "css": "chevron.left.forwardslash.chevron.right"
            default: "doc"
            }
        }
    }

    public init(name: String, path: String, kind: FileKind, size: UInt64 = 0, modified: Date? = nil, permissions: UInt32 = 0o644) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }

    public static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

public struct DirectoryListing: Sendable {
    public let path: String
    public let entries: [FileEntry]
    public init(path: String, entries: [FileEntry]) { self.path = path; self.entries = entries }
}

public enum MacSCPError: Error, LocalizedError, Sendable {
    case message(String)
    case protocolViolation(String)
    case remoteStatus(UInt32, String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .protocolViolation(let text): "服务器响应无效：\(text)"
        case .remoteStatus(let code, let text): "服务器返回错误 \(code)：\(text)"
        case .cancelled: "操作已取消"
        }
    }
}

public enum RemotePath {
    public static func validate(_ path: String) throws {
        guard !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw MacSCPError.message("路径不能包含换行或空字符。")
        }
    }

    public static func validateName(_ name: String) throws {
        try validate(name)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw MacSCPError.message("文件名不能为空，也不能包含 / 或使用 .、..。")
        }
    }

    public static func join(_ directory: String, _ name: String) -> String {
        (directory == "/" ? "/" : directory + "/") + name
    }

    public static func parent(_ path: String) -> String {
        let result = NSString(string: path).deletingLastPathComponent
        return result.isEmpty ? "/" : result
    }

    /// POSIX single-quote escaping. Only used inside a remote /bin/sh command.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// A cancellation flag can be set while a worker is blocked in transport I/O.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func check() throws { if isCancelled { throw MacSCPError.cancelled } }
}
