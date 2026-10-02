import Foundation
import Testing
@testable import MacSCPCore

@Test func packetRoundTripAndTruncation() throws {
    var packet = SFTPPacket()
    packet.uint32(0x01020304)
    packet.uint64(0x123456789abcdef0)
    packet.string("文件 ' $(echo nope).txt")
    #expect(try packet.readUInt32() == 0x01020304)
    #expect(try packet.readUInt64() == 0x123456789abcdef0)
    #expect(try packet.readString() == "文件 ' $(echo nope).txt")
    #expect(throws: MacSCPError.self) { try packet.readUInt32() }
}

@Test func rejectOptionAndPathInjection() throws {
    var site = Site()
    site.host = "-oProxyCommand=evil"
    #expect(throws: MacSCPError.self) { try site.validated() }
    site.host = "host; touch /tmp/bad"
    #expect(throws: MacSCPError.self) { try site.validated() }
    site.host = "[::1]"
    site.username = "user"
    #expect(try site.validated().host == "::1")
    #expect(throws: MacSCPError.self) { try RemotePath.validateName("../escape") }
    #expect(throws: MacSCPError.self) { try RemotePath.validateName("bad\nname") }
}

@Test func shellQuotingRemainsLiteral() throws {
    let value = "中文 '$HOME' `id` $(whoami); * ? \\"
    let channel = try ProcessChannel(executable: "/bin/sh", arguments: ["-c", "printf '%s' " + RemotePath.quote(value)], cancellation: CancellationFlag())
    channel.closeInput()
    #expect(String(decoding: try channel.readToEnd(), as: UTF8.self) == value)
}

@Test func rejectOversizedSFTPResponse() throws {
    let channel = try ProcessChannel(executable: "/bin/sh",
                                    arguments: ["-c", "printf '\\177\\377\\377\\377'; read ignored"],
                                    cancellation: CancellationFlag())
    #expect(throws: MacSCPError.self) { try SFTPClient(channel: channel) }
}

@Test func rejectSCPTraversalBeforeCreatingLocalFile() throws {
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("MacSCP-traversal-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: destination) }
    let channel = try ProcessChannel(executable: "/bin/sh",
                                    arguments: ["-c", "printf 'C0644 1 ../escape\\n'; read ignored"],
                                    cancellation: CancellationFlag())
    let entry = FileEntry(name: "safe.txt", path: "/safe.txt", kind: .file, size: 1)
    #expect(throws: MacSCPError.self) {
        try SCPTransfer.download(channel: channel, local: destination, entry: entry) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}
