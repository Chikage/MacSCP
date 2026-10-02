import Foundation
import Testing
@testable import MacSCPCore

@Suite(.serialized)
struct TransferIntegrationTests {
    @Test(arguments: TransferProtocol.allCases)
    func recursiveRoundTrip(_ mode: TransferProtocol) throws {
        let fixture = try Fixture(mode: mode)
        defer { fixture.clean() }
        let source = fixture.local.appendingPathComponent("中文 folder ' $test")
        let nested = source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let payload = Data((0..<(2 * 1024 * 1024 + 73)).map { UInt8(truncatingIfNeeded: $0) })
        try payload.write(to: nested.appendingPathComponent("引号 ' ; $(whoami) [x].bin"))
        try Data().write(to: source.appendingPathComponent("zero.txt"))
        try Data("hidden".utf8).write(to: source.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: nested)
        let entry = try LocalFiles.entry(source)
        let uploaded = try fixture.worker().run(TransferRequest(direction: .upload, entries: [entry], destination: fixture.remote.path, conflictPolicy: .skip))
        #expect(uploaded.totalFiles == 3)
        #expect(uploaded.completedFiles == 3)
        #expect(uploaded.skipped == 1)
        #expect(uploaded.bytes == UInt64(payload.count + 6))
        let remoteSource = fixture.remote.appendingPathComponent(source.lastPathComponent)
        let downloaded = try fixture.worker().run(TransferRequest(direction: .download, entries: [try LocalFiles.entry(remoteSource)], destination: fixture.download.path, conflictPolicy: .skip))
        #expect(downloaded.totalFiles == 3)
        let destination = fixture.download.appendingPathComponent(source.lastPathComponent)
        #expect(try Data(contentsOf: destination.appendingPathComponent("nested/引号 ' ; $(whoami) [x].bin")) == payload)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("empty").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("link").path))
    }

    @Test(arguments: TransferProtocol.allCases)
    func collisionAndAtomicReplace(_ mode: TransferProtocol) throws {
        let fixture = try Fixture(mode: mode)
        defer { fixture.clean() }
        let local = fixture.local.appendingPathComponent("same ' name.txt")
        let remote = fixture.remote.appendingPathComponent(local.lastPathComponent)
        try Data("new contents".utf8).write(to: local)
        try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: local.path)
        try Data("original".utf8).write(to: remote)
        let entry = try LocalFiles.entry(local)
        let skipped = try fixture.worker().run(TransferRequest(direction: .upload, entries: [entry], destination: fixture.remote.path, conflictPolicy: .skip))
        #expect(skipped.skipped == 1)
        #expect(try String(contentsOf: remote, encoding: .utf8) == "original")
        _ = try fixture.worker().run(TransferRequest(direction: .upload, entries: [entry], destination: fixture.remote.path, conflictPolicy: .replace))
        #expect(try String(contentsOf: remote, encoding: .utf8) == "new contents")
        #expect(try LocalFiles.entry(remote).permissions == 0o664)
        let output = fixture.download.appendingPathComponent(local.lastPathComponent)
        try Data("old local".utf8).write(to: output)
        _ = try fixture.worker().run(TransferRequest(direction: .download, entries: [try LocalFiles.entry(remote)], destination: fixture.download.path, conflictPolicy: .replace))
        #expect(try String(contentsOf: output, encoding: .utf8) == "new contents")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.remote.path).allSatisfy { !$0.hasSuffix(".part") })
    }

    @Test(arguments: TransferProtocol.allCases)
    func directoryOperationsAndSymlinkProtection(_ mode: TransferProtocol) throws {
        let fixture = try Fixture(mode: mode)
        defer { fixture.clean() }
        let client = try fixture.client()
        let folder = fixture.remote.appendingPathComponent("new ' folder")
        try client.mkdir(folder.path)
        #expect(try client.list(fixture.remote.path).contains { $0.name == folder.lastPathComponent && $0.isDirectory })
        let renamed = fixture.remote.appendingPathComponent("renamed")
        try client.rename(folder.path, to: renamed.path, replace: false)
        #expect(try client.stat(folder.path) == nil)
        try client.remove(renamed.path, directory: true)
        #expect(try client.stat(renamed.path) == nil)
        let source = fixture.local.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("safe".utf8).write(to: source.appendingPathComponent("data"))
        try FileManager.default.createSymbolicLink(at: fixture.remote.appendingPathComponent("folder"), withDestinationURL: fixture.download)
        #expect(throws: MacSCPError.self) {
            try fixture.worker().run(TransferRequest(direction: .upload, entries: [try LocalFiles.entry(source)], destination: fixture.remote.path, conflictPolicy: .replace))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.download.path).isEmpty)
    }

    @Test func cancelStalledChannelPromptly() throws {
        let flag = CancellationFlag()
        let channel = try ProcessChannel(executable: "/bin/sleep", arguments: ["30"], cancellation: flag)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { flag.cancel() }
        let start = Date()
        #expect(throws: MacSCPError.self) { try channel.readExactly(1) }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func failedDownloadPreservesExistingFile() throws {
        let fixture = try Fixture(mode: .sftp)
        defer { fixture.clean() }
        let target = fixture.download.appendingPathComponent("data.txt")
        try Data("valuable original".utf8).write(to: target)
        let client = PartialFailureClient()
        let worker = TransferWorker(client: client, cancellation: CancellationFlag(), report: { _ in })
        let request = TransferRequest(direction: .download, entries: [client.file], destination: fixture.download.path, conflictPolicy: .replace)
        #expect(throws: MacSCPError.self) { try worker.run(request) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "valuable original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.download.path) == ["data.txt"])
    }
}

private struct Fixture {
    let mode: TransferProtocol
    let root: URL
    let local: URL
    let remote: URL
    let download: URL

    init(mode: TransferProtocol) throws {
        self.mode = mode
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSCP-tests-" + UUID().uuidString)
        local = root.appendingPathComponent("local")
        remote = root.appendingPathComponent("remote ' space")
        download = root.appendingPathComponent("download")
        for directory in [local, remote, download] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func client() throws -> any RemoteFileSystem {
        if mode == .sftp {
            return try SFTPClient(channel: ProcessChannel(executable: "/usr/libexec/sftp-server", arguments: [], cancellation: CancellationFlag()))
        }
        return ShellFileSystem(cancellation: CancellationFlag()) { script, flag in
            try ProcessChannel(executable: "/bin/sh", arguments: ["-c", script], cancellation: flag)
        }
    }
    func worker() throws -> TransferWorker { try TransferWorker(client: client(), cancellation: CancellationFlag(), report: { _ in }) }
}

private final class PartialFailureClient: RemoteFileSystem {
    let file = FileEntry(name: "data.txt", path: "/data.txt", kind: .file, size: 20)
    func canonicalPath(_ path: String) throws -> String { "/" }
    func list(_ path: String) throws -> [FileEntry] { [file] }
    func stat(_ path: String) throws -> FileEntry? { file }
    func mkdir(_ path: String) throws {}
    func rename(_ source: String, to destination: String, replace: Bool) throws {}
    func remove(_ path: String, directory: Bool) throws {}
    func upload(_ local: URL, to remote: String, entry: FileEntry, progress: (UInt64) -> Void) throws {}
    func download(_ remote: String, to local: URL, entry: FileEntry, progress: (UInt64) -> Void) throws {
        try Data("partial".utf8).write(to: local)
        throw MacSCPError.message("Simulated interrupted connection")
    }
}
