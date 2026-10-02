import Foundation

final class SFTPClient: RemoteFileSystem {
    private let channel: ProcessChannel
    private var nextID: UInt32 = 0
    private var extensions: Set<String> = []
    private var pending: [UInt32: (UInt8, SFTPPacket)] = [:]

    init(channel: ProcessChannel) throws {
        self.channel = channel
        var packet = SFTPPacket()
        packet.byte(1)
        packet.uint32(3)
        try sendPacket(packet)
        var version = try receivePacket()
        guard try version.readByte() == 2, try version.readUInt32() == 3 else {
            throw MacSCPError.protocolViolation("需要支持 SFTP v3 的服务器")
        }
        while version.remaining > 0 {
            extensions.insert(try version.readString())
            _ = try version.readString()
        }
    }

    func canonicalPath(_ path: String) throws -> String {
        var response = try request(16) { $0.string(path) }
        guard response.0 == 104, try response.1.readUInt32() == 1 else {
            throw MacSCPError.protocolViolation("无法解析远程路径")
        }
        let result = try response.1.readString()
        guard result.hasPrefix("/") else { throw MacSCPError.protocolViolation("服务器未返回绝对路径") }
        return result
    }

    func list(_ path: String) throws -> [FileEntry] {
        let handle = try openHandle(11) { $0.string(path) }
        defer { try? close(handle) }
        var entries: [FileEntry] = []
        while true {
            do {
                var response = try request(12) { $0.bytes(handle) }
                guard response.0 == 104 else { throw MacSCPError.protocolViolation("目录响应类型不正确") }
                let count = try response.1.readUInt32()
                guard count <= 100_000, entries.count + Int(count) <= 100_000 else {
                    throw MacSCPError.message("单个目录超过 100,000 项，请打开更小的子目录。")
                }
                if count == 0 { throw MacSCPError.protocolViolation("空目录响应缺少结束状态") }
                for _ in 0..<count {
                    let name = try response.1.readString()
                    _ = try response.1.readString() // v3 longname is not parsed; attributes are authoritative.
                    let entry = try response.1.attributes(name: name, path: RemotePath.join(path, name))
                    if name != ".", name != ".." {
                        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
                            throw MacSCPError.protocolViolation("目录包含非法文件名")
                        }
                        entries.append(entry)
                    }
                }
            } catch MacSCPError.remoteStatus(1, _) { return entries }
        }
    }

    func stat(_ path: String) throws -> FileEntry? {
        do {
            var response = try request(7) { $0.string(path) } // LSTAT: never follow links implicitly.
            guard response.0 == 105 else { throw MacSCPError.protocolViolation("文件属性响应不正确") }
            return try response.1.attributes(name: NSString(string: path).lastPathComponent, path: path)
        } catch MacSCPError.remoteStatus(2, _) { return nil }
    }

    func mkdir(_ path: String) throws {
        try expectOK(request(14) { $0.string(path); $0.uint32(4); $0.uint32(0o755) })
    }

    func rename(_ source: String, to destination: String, replace: Bool) throws {
        if let existing = try stat(destination) {
            guard replace, existing.kind == .file else { throw MacSCPError.message("目标已存在：\(destination)") }
            guard extensions.contains("posix-rename@openssh.com") else {
                throw MacSCPError.message("服务器不支持安全替换文件，请重命名目标后重试。")
            }
            try expectOK(request(200) {
                $0.string("posix-rename@openssh.com"); $0.string(source); $0.string(destination)
            })
        } else {
            try expectOK(request(18) { $0.string(source); $0.string(destination) })
        }
    }

    func remove(_ path: String, directory: Bool) throws {
        try expectOK(request(directory ? 15 : 13) { $0.string(path) })
    }

    func upload(_ local: URL, to remote: String, entry: FileEntry, progress: (UInt64) -> Void) throws {
        let input = try LocalFiles.readHandle(local)
        defer { try? input.close() }
        let handle = try openHandle(3) {
            $0.string(remote); $0.uint32(2 | 8 | 32) // WRITE | CREAT | EXCL
            $0.uint32(4); $0.uint32(0o600)
        }
        var closed = false
        defer { if !closed { try? close(handle) } }
        var offset: UInt64 = 0
        // Pipeline at most 16 writes (512 KiB) without holding an entire file in memory.
        while offset < entry.size {
            var batch: [(UInt32, UInt64)] = []
            for _ in 0..<16 where offset < entry.size {
                try channel.cancellation.check()
                let count = Int(min(32768, entry.size - offset))
                guard let data = try input.read(upToCount: count), !data.isEmpty else {
                    throw MacSCPError.message("本地文件在传输过程中发生变化。")
                }
                let writeOffset = offset
                let id = try send(6) { $0.bytes(handle); $0.uint64(writeOffset); $0.bytes(data) }
                batch.append((id, UInt64(data.count)))
                offset += UInt64(data.count)
            }
            for (id, count) in batch { try expectOK(reply(id)); progress(count) }
        }
        if let more = try input.read(upToCount: 1), !more.isEmpty {
            throw MacSCPError.message("本地文件在传输过程中变大，请重试。")
        }
        try expectOK(request(10) {
            $0.bytes(handle)
            $0.uint32(entry.modified == nil ? 4 : 12)
            $0.uint32(entry.permissions & 0o777)
            if let date = entry.modified {
                let timestamp = UInt32(clamping: Int64(date.timeIntervalSince1970))
                $0.uint32(timestamp); $0.uint32(timestamp)
            }
        })
        if extensions.contains("fsync@openssh.com") {
            try expectOK(request(200) { $0.string("fsync@openssh.com"); $0.bytes(handle) })
        }
        try close(handle)
        closed = true
    }

    func download(_ remote: String, to local: URL, entry: FileEntry, progress: (UInt64) -> Void) throws {
        let output = try LocalFiles.createExclusive(local)
        defer { try? output.close() }
        let handle = try openHandle(3) { $0.string(remote); $0.uint32(1); $0.uint32(0) }
        var closed = false
        defer { if !closed { try? close(handle) } }
        var offset: UInt64 = 0
        while offset < entry.size {
            var batch: [(UInt32, UInt64, UInt32)] = []
            var requested = offset
            for _ in 0..<16 where requested < entry.size {
                let count = UInt32(min(32768, entry.size - requested))
                let start = requested
                let id = try send(5) { $0.bytes(handle); $0.uint64(start); $0.uint32(count) }
                batch.append((id, start, count))
                requested += UInt64(count)
            }
            for (id, start, count) in batch {
                var response = try reply(id)
                var bytes = try readData(&response, maximum: Int(count))
                // Short reads are valid in SFTP; fetch the remainder at the correct offset.
                while bytes.count < count {
                    let startOffset = start + UInt64(bytes.count)
                    let remaining = count - UInt32(bytes.count)
                    var extra = try request(5) { $0.bytes(handle); $0.uint64(startOffset); $0.uint32(remaining) }
                    bytes.append(try readData(&extra, maximum: Int(remaining)))
                }
                try output.write(contentsOf: bytes)
                offset += UInt64(bytes.count)
                progress(UInt64(bytes.count))
            }
        }
        try output.synchronize()
        try close(handle)
        closed = true
    }

    private func readData(_ response: inout (UInt8, SFTPPacket), maximum: Int) throws -> Data {
        guard response.0 == 103 else { throw MacSCPError.protocolViolation("文件数据响应不正确") }
        let bytes = try response.1.readBytes()
        guard !bytes.isEmpty, bytes.count <= maximum else { throw MacSCPError.protocolViolation("文件数据长度不正确") }
        return bytes
    }

    private func openHandle(_ type: UInt8, body: (inout SFTPPacket) -> Void) throws -> Data {
        var response = try request(type, body: body)
        guard response.0 == 102 else { throw MacSCPError.protocolViolation("无法打开文件句柄") }
        return try response.1.readBytes()
    }

    private func close(_ handle: Data) throws { try expectOK(request(4) { $0.bytes(handle) }) }
    private func expectOK(_ response: (UInt8, SFTPPacket)) throws {
        guard response.0 == 101 else { throw MacSCPError.protocolViolation("缺少完成状态") }
    }

    private func request(_ type: UInt8, body: (inout SFTPPacket) -> Void) throws -> (UInt8, SFTPPacket) {
        try reply(send(type, body: body))
    }

    private func send(_ type: UInt8, body: (inout SFTPPacket) -> Void) throws -> UInt32 {
        nextID &+= 1
        var packet = SFTPPacket()
        packet.byte(type)
        packet.uint32(nextID)
        body(&packet)
        try sendPacket(packet)
        return nextID
    }

    private func reply(_ expectedID: UInt32) throws -> (UInt8, SFTPPacket) {
        var result = pending.removeValue(forKey: expectedID)
        while result == nil {
            var packet = try receivePacket()
            let type = try packet.readByte()
            let id = try packet.readUInt32()
            guard id > 0, id <= nextID else { throw MacSCPError.protocolViolation("请求编号不匹配") }
            if id == expectedID { result = (type, packet) }
            else {
                guard pending.count < 32, pending[id] == nil else { throw MacSCPError.protocolViolation("重复或过量的响应") }
                pending[id] = (type, packet)
            }
        }
        guard var response = result else { throw MacSCPError.protocolViolation("缺少响应") }
        if response.0 == 101 {
            let code = try response.1.readUInt32()
            let message = try response.1.readString()
            if code != 0 { throw MacSCPError.remoteStatus(code, message) }
        }
        return response
    }

    private func sendPacket(_ packet: SFTPPacket) throws {
        guard packet.data.count <= 1024 * 1024 else { throw MacSCPError.protocolViolation("数据包过大") }
        var framed = SFTPPacket()
        framed.bytes(packet.data)
        try channel.write(framed.data)
    }

    private func receivePacket() throws -> SFTPPacket {
        var header = SFTPPacket(try channel.readExactly(4))
        let count = Int(try header.readUInt32())
        guard (1...(1024 * 1024)).contains(count) else { throw MacSCPError.protocolViolation("数据包长度超限") }
        return SFTPPacket(try channel.readExactly(count))
    }
}
