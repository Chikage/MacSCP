import Foundation

/// Implements the SCP acknowledgement and C/T record exchange used by
/// WinSCP's SCPSource / SCPSink. SSH encryption is delegated to system OpenSSH.
enum SCPTransfer {
    static func upload(channel: ProcessChannel, local: URL, remoteName: String,
                       entry: FileEntry, progress: (UInt64) -> Void) throws {
        try RemotePath.validateName(remoteName)
        let input = try LocalFiles.readHandle(local)
        defer { try? input.close() }
        try acknowledge(channel)
        if let date = entry.modified {
            let time = max(0, Int64(date.timeIntervalSince1970))
            try channel.write(Data("T\(time) 0 \(time) 0\n".utf8))
            try acknowledge(channel)
        }
        let mode = String(format: "%04o", entry.permissions & 0o777)
        try channel.write(Data("C\(mode) \(entry.size) \(remoteName)\n".utf8))
        try acknowledge(channel)
        var remaining = entry.size
        while remaining > 0 {
            try channel.cancellation.check()
            guard let bytes = try input.read(upToCount: Int(min(65536, remaining))), !bytes.isEmpty else {
                throw MacSCPError.message("本地文件在传输过程中变小，请重试。")
            }
            try channel.write(bytes)
            remaining -= UInt64(bytes.count)
            progress(UInt64(bytes.count))
        }
        if let extra = try input.read(upToCount: 1), !extra.isEmpty {
            throw MacSCPError.message("本地文件在传输过程中变大，请重试。")
        }
        try channel.write(Data([0]))
        try acknowledge(channel)
        channel.closeInput()
        try channel.finish()
    }

    static func download(channel: ProcessChannel, local: URL, entry: FileEntry,
                         progress: (UInt64) -> Void) throws {
        try channel.write(Data([0]))
        var header = try channel.readLine()
        if header.hasPrefix("T") {
            let timestamps = header.dropFirst().split(separator: " ")
            guard timestamps.count == 4, timestamps.allSatisfy({ UInt64($0) != nil }) else {
                throw MacSCPError.protocolViolation("SCP 时间记录无效")
            }
            try channel.write(Data([0]))
            header = try channel.readLine()
        }
        if header.first == "\u{1}" || header.first == "\u{2}" {
            throw MacSCPError.message(String(header.dropFirst()))
        }
        let fields = header.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0].hasPrefix("C"),
              UInt32(fields[0].dropFirst(), radix: 8) != nil,
              let size = UInt64(fields[1]), size == entry.size else {
            throw MacSCPError.protocolViolation("SCP 文件大小或控制记录不匹配，请刷新目录后重试")
        }
        let name = String(fields[2])
        try RemotePath.validateName(name)
        guard name == entry.name else { throw MacSCPError.protocolViolation("SCP 返回了未请求的文件名") }
        let output = try LocalFiles.createExclusive(local)
        defer { try? output.close() }
        try channel.write(Data([0]))
        var remaining = size
        while remaining > 0 {
            let bytes = try channel.readExactly(Int(min(65536, remaining)))
            try output.write(contentsOf: bytes)
            remaining -= UInt64(bytes.count)
            progress(UInt64(bytes.count))
        }
        try acknowledge(channel)
        try output.synchronize()
        try channel.write(Data([0]))
        channel.closeInput()
        try channel.finish()
    }

    private static func acknowledge(_ channel: ProcessChannel) throws {
        let byte = try channel.readExactly(1)[0]
        switch byte {
        case 0: return
        case 1, 2: throw MacSCPError.message(try channel.readLine())
        default: throw MacSCPError.protocolViolation("SCP 确认字节无效")
        }
    }
}
