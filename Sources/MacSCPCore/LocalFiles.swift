import Darwin
import Foundation

public enum LocalFiles {
    public static func list(_ path: String) async throws -> DirectoryListing {
        try await Background.run(cancellation: CancellationFlag()) {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).resolvingSymlinksInPath()
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            let entries = try children.map { try entry($0) }
            return DirectoryListing(path: url.path, entries: FileEntry.sorted(entries))
        }
    }

    static func entry(_ url: URL) throws -> FileEntry {
        // FileManager.attributesOfItem also reads extended attributes, which can
        // wait on a File Provider for minutes. lstat needs only directory metadata
        // and never follows a symlink or hydrates a cloud placeholder.
        var attributes = Darwin.stat()
        guard Darwin.lstat(url.path, &attributes) == 0 else {
            if errno == ENOENT { throw CocoaError(.fileReadNoSuchFile) }
            throw posixError(url.path)
        }
        let kind: FileKind = switch attributes.st_mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFREG: .file
        case S_IFLNK: .symbolicLink
        default: .other
        }
        return FileEntry(name: url.lastPathComponent, path: url.path, kind: kind,
                         size: UInt64(max(0, attributes.st_size)),
                         modified: Date(timeIntervalSince1970: Double(attributes.st_mtimespec.tv_sec)
                                        + Double(attributes.st_mtimespec.tv_nsec) / 1_000_000_000),
                         permissions: UInt32(attributes.st_mode & 0o777))
    }

    static func readHandle(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw posixError(url.path) }
        var attributes = Darwin.stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw MacSCPError.message("只支持传输普通文件：\(url.lastPathComponent)")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func createExclusive(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError(url.path) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func commit(_ temporary: URL, to destination: URL, replace: Bool) throws {
        if replace {
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try entry(destination).kind == .file else { throw MacSCPError.message("不能替换文件夹或符号链接。") }
            }
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw posixError(destination.path) }
        } else {
            // renamex_np makes the no-overwrite decision atomically on macOS.
            guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError(destination.path) }
        }
    }

    static func posixError(_ path: String) -> MacSCPError {
        .message("\(path)：\(String(cString: strerror(errno)))")
    }
}
