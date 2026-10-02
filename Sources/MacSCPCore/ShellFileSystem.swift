import Foundation

/// SCP-only servers are browsed with POSIX sh + GNU/BSD stat. Filenames are
/// NUL-delimited; spaces, quotes, Unicode and shell metacharacters remain literal.
final class ShellFileSystem: RemoteFileSystem {
    private let cancellation: CancellationFlag
    private let channelFactory: (String, CancellationFlag) throws -> ProcessChannel

    init(context: SSHContext, cancellation: CancellationFlag) {
        self.cancellation = cancellation
        self.channelFactory = { script, flag in
            try context.channel(command: "exec /bin/sh -c " + RemotePath.quote(script), cancellation: flag)
        }
    }

    init(cancellation: CancellationFlag, channelFactory: @escaping (String, CancellationFlag) throws -> ProcessChannel) {
        self.cancellation = cancellation
        self.channelFactory = channelFactory
    }

    private var statFunction: String {
        """
        if stat -c '%s' . >/dev/null 2>&1; then
          metadata() { stat -c '%s %Y %a' -- "$1"; }
        elif stat -f '%z' . >/dev/null 2>&1; then
          metadata() { stat -f '%z %m %Lp' "$1"; }
        else
          printf '%s\\n' 'SCP browsing requires GNU or BSD stat.' >&2; exit 1
        fi
        record() {
          f="$1"; name="$2"; kind=other
          if [ -L "$f" ]; then kind=symbolicLink
          elif [ -d "$f" ]; then kind=directory
          elif [ -f "$f" ]; then kind=file; fi
          meta=$(metadata "$f") || exit 1
          printf '%s\\0%s\\0%s\\0' "$name" "$kind" "$meta"
        }
        """
    }

    func canonicalPath(_ path: String) throws -> String {
        let bytes = try run("cd \(RemotePath.quote(path))\npwd -P")
        guard let result = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .newlines), result.hasPrefix("/") else {
            throw MacSCPError.protocolViolation("无法解析远程工作目录")
        }
        try RemotePath.validate(result)
        return result
    }

    func list(_ path: String) throws -> [FileEntry] {
        let script = """
        cd \(RemotePath.quote(path))
        \(statFunction)
        for f in ./* ./.[!.]* ./..?*; do
          if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
          record "$f" "${f#./}"
        done
        """
        return try parse(run(script), directory: path)
    }

    func stat(_ path: String) throws -> FileEntry? {
        let script = """
        \(statFunction)
        f=\(RemotePath.quote(path))
        if [ -e "$f" ] || [ -L "$f" ]; then record "$f" \(RemotePath.quote(NSString(string: path).lastPathComponent)); fi
        """
        return try parse(run(script), directory: RemotePath.parent(path)).first
    }

    func mkdir(_ path: String) throws { _ = try run("mkdir -m 755 -- \(RemotePath.quote(path))") }

    func rename(_ source: String, to destination: String, replace: Bool) throws {
        let target = RemotePath.quote(destination)
        let source = RemotePath.quote(source)
        if replace {
            _ = try run("""
            if [ -L \(target) ] || { [ -e \(target) ] && [ ! -f \(target) ]; }; then
              printf '%s\\n' 'Destination is not a regular file.' >&2; exit 1
            fi
            mv -f -- \(source) \(target)
            """)
        } else {
            _ = try run("""
            if [ -e \(target) ] || [ -L \(target) ]; then
              printf '%s\\n' 'Destination already exists.' >&2; exit 1
            fi
            mv -n -- \(source) \(target)
            if [ -e \(source) ] || [ -L \(source) ]; then
              printf '%s\\n' 'Destination appeared during rename.' >&2; exit 1
            fi
            """)
        }
    }

    func remove(_ path: String, directory: Bool) throws {
        _ = try run("\(directory ? "rmdir" : "rm -f") -- \(RemotePath.quote(path))")
    }

    func upload(_ local: URL, to remote: String, entry: FileEntry, progress: (UInt64) -> Void) throws {
        let parent = RemotePath.parent(remote)
        let name = NSString(string: remote).lastPathComponent
        let channel = try channelFactory("exec scp -p -t -- \(RemotePath.quote(parent))", cancellation)
        try SCPTransfer.upload(channel: channel, local: local, remoteName: name, entry: entry, progress: progress)
    }

    func download(_ remote: String, to local: URL, entry: FileEntry, progress: (UInt64) -> Void) throws {
        try RemotePath.validate(remote)
        let channel = try channelFactory("exec scp -p -f -- \(RemotePath.quote(remote))", cancellation)
        try SCPTransfer.download(channel: channel, local: local, entry: entry, progress: progress)
    }

    private func run(_ script: String) throws -> Data {
        let channel = try channelFactory("set -eu\nLC_ALL=C; export LC_ALL\n" + script, cancellation)
        channel.closeInput()
        return try channel.readToEnd()
    }

    private func parse(_ data: Data, directory: String) throws -> [FileEntry] {
        if data.isEmpty { return [] }
        let parts = data.split(separator: 0, omittingEmptySubsequences: false)
        guard parts.last?.isEmpty == true, (parts.count - 1).isMultiple(of: 3), parts.count <= 300_001 else {
            throw MacSCPError.protocolViolation("SCP 目录响应格式不正确")
        }
        return try stride(from: 0, to: parts.count - 1, by: 3).map { index in
            guard let name = String(data: parts[index], encoding: .utf8), !name.isEmpty,
                  !name.contains("/"), name != ".", name != "..",
                  let kind = FileKind(rawValue: String(decoding: parts[index + 1], as: UTF8.self)) else {
                throw MacSCPError.protocolViolation("SCP 目录包含非法名称")
            }
            let meta = String(decoding: parts[index + 2], as: UTF8.self).split(separator: " ")
            guard meta.count == 3, let size = UInt64(meta[0]), let time = Double(meta[1]),
                  let permissions = UInt32(meta[2], radix: 8) else {
                throw MacSCPError.protocolViolation("SCP 文件属性无法解析")
            }
            return FileEntry(name: name, path: RemotePath.join(directory, name), kind: kind, size: size,
                             modified: Date(timeIntervalSince1970: time), permissions: permissions & 0o777)
        }
    }
}
