import Foundation

public enum TransferDirection: String, Sendable { case upload, download }
public enum ConflictPolicy: String, CaseIterable, Sendable {
    case skip, replace
    public var title: String { self == .skip ? "跳过同名文件" : "替换同名文件" }
}

public struct TransferRequest: Identifiable, Sendable {
    public let id: UUID
    public let direction: TransferDirection
    public let entries: [FileEntry]
    public let destination: String
    public let conflictPolicy: ConflictPolicy
    public init(id: UUID = UUID(), direction: TransferDirection, entries: [FileEntry],
                destination: String, conflictPolicy: ConflictPolicy) {
        self.id = id; self.direction = direction; self.entries = entries
        self.destination = destination; self.conflictPolicy = conflictPolicy
    }
    public var title: String {
        entries.count == 1 ? (entries.first?.name ?? "传输") : "\(entries.count) 个项目"
    }
}

public struct TransferProgress: Sendable {
    public var bytes: UInt64 = 0
    public var totalBytes: UInt64 = 0
    public var completedFiles = 0
    public var totalFiles = 0
    public var skipped = 0
    public var currentFile = "正在统计文件…"
    public var fraction: Double { totalBytes == 0 ? 0 : min(1, Double(bytes) / Double(totalBytes)) }
    public init() {}
}

public enum TransferEngine {
    public static func run(_ request: TransferRequest, context: SSHContext, cancellation: CancellationFlag,
                           progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferProgress {
        try await Background.run(cancellation: cancellation) {
            let client = try RemoteFactory.open(context, cancellation: cancellation)
            return try TransferWorker(client: client, cancellation: cancellation, report: progress).run(request)
        }
    }
}

/// Synchronous worker, confined to the background task that owns its client.
final class TransferWorker {
    private let client: any RemoteFileSystem
    private let cancellation: CancellationFlag
    private let report: @Sendable (TransferProgress) -> Void
    private var progress = TransferProgress()
    private var lastReport = Date.distantPast
    private var plan: [(FileEntry, String)] = []

    init(client: any RemoteFileSystem, cancellation: CancellationFlag,
         report: @escaping @Sendable (TransferProgress) -> Void) {
        self.client = client; self.cancellation = cancellation; self.report = report
    }

    func run(_ request: TransferRequest) throws -> TransferProgress {
        guard !request.entries.isEmpty else { throw MacSCPError.message("请选择要传输的文件。") }
        for entry in request.entries {
            try collect(entry.path, relative: entry.name, direction: request.direction, depth: 0)
        }
        let destination: String
        if request.direction == .upload {
            destination = try client.canonicalPath(request.destination)
        } else {
            destination = URL(fileURLWithPath: request.destination).resolvingSymlinksInPath().path
            guard try LocalFiles.entry(URL(fileURLWithPath: destination)).isDirectory else {
                throw MacSCPError.message("下载目标不是文件夹。")
            }
        }
        emit(force: true)
        for (entry, relative) in plan {
            try cancellation.check()
            let target = RemotePath.join(destination, relative)
            progress.currentFile = relative
            if entry.isDirectory {
                try ensureDirectory(target, direction: request.direction)
                continue
            }
            let existing = try destinationEntry(target, direction: request.direction)
            if let existing {
                if request.conflictPolicy == .skip {
                    progress.skipped += 1
                    progress.bytes += entry.size
                    progress.completedFiles += 1
                    emit(force: true)
                    continue
                }
                guard existing.kind == .file else {
                    throw MacSCPError.message("目标是文件夹或符号链接，不能替换：\(target)")
                }
            }
            let temporary = RemotePath.join(RemotePath.parent(target), ".macscp-\(UUID().uuidString).part")
            if request.direction == .upload {
                do {
                    try client.upload(URL(fileURLWithPath: entry.path), to: temporary, entry: entry) { self.advance($0) }
                    try cancellation.check()
                    try client.rename(temporary, to: target, replace: request.conflictPolicy == .replace)
                } catch {
                    // Best effort. Cancellation/network loss can leave a hidden .part file;
                    // the original destination is preserved until a successful commit.
                    try? client.remove(temporary, directory: false)
                    throw error
                }
            } else {
                let temporaryURL = URL(fileURLWithPath: temporary)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                try client.download(entry.path, to: temporaryURL, entry: entry) { self.advance($0) }
                try cancellation.check()
                var attributes: [FileAttributeKey: Any] = [.posixPermissions: entry.permissions & 0o777]
                if let date = entry.modified { attributes[.modificationDate] = date }
                try FileManager.default.setAttributes(attributes, ofItemAtPath: temporary)
                try LocalFiles.commit(temporaryURL, to: URL(fileURLWithPath: target), replace: request.conflictPolicy == .replace)
            }
            progress.completedFiles += 1
            emit(force: true)
        }
        progress.currentFile = "传输完成"
        emit(force: true)
        return progress
    }

    private func collect(_ path: String, relative: String, direction: TransferDirection, depth: Int) throws {
        try cancellation.check()
        try RemotePath.validate(path)
        try RemotePath.validateName(NSString(string: relative).lastPathComponent)
        guard depth < 128, plan.count < 100_000 else { throw MacSCPError.message("目录层级或文件数量超过上限。") }
        let entry: FileEntry
        if direction == .upload { entry = try LocalFiles.entry(URL(fileURLWithPath: path)) }
        else {
            guard let remote = try client.stat(path) else { throw MacSCPError.message("远程文件已不存在：\(path)") }
            entry = remote
        }
        guard entry.kind == .file || entry.kind == .directory else {
            progress.skipped += 1
            return
        }
        plan.append((entry, relative))
        if entry.isDirectory {
            let children: [FileEntry]
            if direction == .upload {
                children = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
                    .map { try LocalFiles.entry($0) }
            } else { children = try client.list(path) }
            for child in FileEntry.sorted(children) {
                try RemotePath.validateName(child.name)
                try collect(child.path, relative: relative + "/" + child.name, direction: direction, depth: depth + 1)
            }
        } else {
            let (total, overflow) = progress.totalBytes.addingReportingOverflow(entry.size)
            guard !overflow else { throw MacSCPError.message("传输总大小超出支持范围。") }
            progress.totalBytes = total
            progress.totalFiles += 1
        }
    }

    private func destinationEntry(_ path: String, direction: TransferDirection) throws -> FileEntry? {
        if direction == .upload { return try client.stat(path) }
        do { return try LocalFiles.entry(URL(fileURLWithPath: path)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }

    private func ensureDirectory(_ path: String, direction: TransferDirection) throws {
        if let existing = try destinationEntry(path, direction: direction) {
            guard existing.isDirectory else { throw MacSCPError.message("目标路径不是普通文件夹：\(path)") }
        } else if direction == .upload { try client.mkdir(path) }
        else { try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: false) }
    }

    private func advance(_ bytes: UInt64) { progress.bytes += bytes; emit(force: false) }
    private func emit(force: Bool) {
        if force || Date().timeIntervalSince(lastReport) >= 0.1 {
            lastReport = Date()
            report(progress)
        }
    }
}
