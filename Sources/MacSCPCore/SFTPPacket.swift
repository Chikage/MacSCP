import Foundation

/// SFTP v3 wire encoding, matching WinSCP's SftpFileSystem packet layout.
struct SFTPPacket {
    var data = Data()
    private var offset = 0

    init() {}
    init(_ data: Data) { self.data = data }
    var remaining: Int { data.count - offset }
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func uint32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                                 UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    mutating func uint64(_ value: UInt64) { uint32(UInt32(value >> 32)); uint32(UInt32(truncatingIfNeeded: value)) }
    mutating func string(_ value: String) { bytes(Data(value.utf8)) }
    mutating func bytes(_ value: Data) { uint32(UInt32(value.count)); data.append(value) }

    mutating func readByte() throws -> UInt8 { try take(1)[0] }
    mutating func readUInt32() throws -> UInt32 { try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    mutating func readUInt64() throws -> UInt64 {
        let high = try readUInt32()
        return UInt64(high) << 32 | UInt64(try readUInt32())
    }
    mutating func readBytes() throws -> Data { try take(Int(readUInt32())) }
    mutating func readString() throws -> String {
        guard let string = String(data: try readBytes(), encoding: .utf8) else {
            throw MacSCPError.protocolViolation("服务器未使用 UTF-8 编码")
        }
        return string
    }

    mutating func attributes(name: String, path: String) throws -> FileEntry {
        let flags = try readUInt32()
        let size: UInt64 = flags & 1 != 0 ? try readUInt64() : 0
        if flags & 2 != 0 { _ = try take(8) }
        let mode: UInt32 = flags & 4 != 0 ? try readUInt32() : 0
        var modified: Date?
        if flags & 8 != 0 { _ = try readUInt32(); modified = Date(timeIntervalSince1970: Double(try readUInt32())) }
        if flags & 0x80000000 != 0 {
            let count = try readUInt32()
            guard count < 4096 else { throw MacSCPError.protocolViolation("属性数量过多") }
            for _ in 0..<count { _ = try readBytes(); _ = try readBytes() }
        }
        let kind: FileKind
        switch mode & 0o170000 {
        case 0o040000: kind = .directory
        case 0o100000: kind = .file
        case 0o120000: kind = .symbolicLink
        default: kind = .other
        }
        return FileEntry(name: name, path: path, kind: kind, size: size, modified: modified, permissions: mode & 0o777)
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw MacSCPError.protocolViolation("数据包被截断") }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}
