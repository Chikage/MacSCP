import Foundation

protocol RemoteFileSystem: AnyObject {
    func canonicalPath(_ path: String) throws -> String
    func list(_ path: String) throws -> [FileEntry]
    func stat(_ path: String) throws -> FileEntry?
    func mkdir(_ path: String) throws
    func rename(_ source: String, to destination: String, replace: Bool) throws
    func remove(_ path: String, directory: Bool) throws
    func upload(_ local: URL, to remote: String, entry: FileEntry, progress: (UInt64) -> Void) throws
    func download(_ remote: String, to local: URL, entry: FileEntry, progress: (UInt64) -> Void) throws
}

enum RemoteFactory {
    static func open(_ context: SSHContext, cancellation: CancellationFlag) throws -> any RemoteFileSystem {
        switch context.site.transferProtocol {
        case .sftp: try SFTPClient(channel: context.sftpChannel(cancellation: cancellation))
        case .scp: ShellFileSystem(context: context, cancellation: cancellation)
        }
    }
}

public enum RemoteOperations {
    public static func list(_ path: String, context: SSHContext, cancellation: CancellationFlag) async throws -> DirectoryListing {
        try await Background.run(cancellation: cancellation) {
            try RemotePath.validate(path)
            let client = try RemoteFactory.open(context, cancellation: cancellation)
            let canonical = try client.canonicalPath(path.isEmpty ? "." : path)
            return DirectoryListing(path: canonical, entries: FileEntry.sorted(try client.list(canonical)))
        }
    }

    public static func createDirectory(_ path: String, context: SSHContext) async throws {
        let flag = CancellationFlag()
        try await Background.run(cancellation: flag) {
            try RemotePath.validate(path)
            try RemoteFactory.open(context, cancellation: flag).mkdir(path)
        }
    }

    public static func rename(_ path: String, to destination: String, context: SSHContext) async throws {
        let flag = CancellationFlag()
        try await Background.run(cancellation: flag) {
            try RemotePath.validate(path)
            try RemotePath.validate(destination)
            try RemoteFactory.open(context, cancellation: flag).rename(path, to: destination, replace: false)
        }
    }

    public static func delete(_ entries: [FileEntry], context: SSHContext, cancellation: CancellationFlag) async throws {
        try await Background.run(cancellation: cancellation) {
            let client = try RemoteFactory.open(context, cancellation: cancellation)
            for entry in entries { try removeTree(entry, client: client, cancellation: cancellation, depth: 0) }
        }
    }

    private static func removeTree(_ entry: FileEntry, client: any RemoteFileSystem, cancellation: CancellationFlag, depth: Int) throws {
        try cancellation.check()
        try RemotePath.validate(entry.path)
        guard entry.path != "/", depth < 128 else { throw MacSCPError.message("不能删除根目录，或目录层级过深。") }
        // Re-stat: never recurse through a link substituted since the UI listing.
        guard let current = try client.stat(entry.path) else { return }
        if current.isDirectory {
            for child in try client.list(entry.path) {
                try RemotePath.validateName(child.name)
                try removeTree(child, client: client, cancellation: cancellation, depth: depth + 1)
            }
        }
        try client.remove(entry.path, directory: current.isDirectory)
    }
}
