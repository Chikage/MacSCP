import Foundation
import Testing
@testable import MacSCPCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACSCP_SSH_FIXTURE"] != nil))
struct SSHIntegrationTests {
    private func fixture() throws -> (URL, Site) {
        let environment = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(environment["MACSCP_SSH_FIXTURE"]))
        var site = Site()
        site.host = "127.0.0.1"
        site.port = try #require(Int(environment["MACSCP_SSH_PORT"] ?? ""))
        site.authentication = .privateKey
        site.privateKeyPath = root.appendingPathComponent("client_key").path
        site.remotePath = root.appendingPathComponent("remote").path
        return (root, site)
    }

    @Test(arguments: TransferProtocol.allCases)
    func authenticatedSSHTransfer(_ mode: TransferProtocol) async throws {
        var (root, site) = try fixture()
        site.transferProtocol = mode
        let session = try await SSHSession.connect(site: site, askPassPath: "/usr/bin/false", cancellation: CancellationFlag(),
                                                  knownHostsFile: root.appendingPathComponent("known_hosts"))
        defer { session.disconnect() }
        #expect(session.isConnected)
        let local = root.appendingPathComponent("local/hello-\(mode.rawValue)-中文.txt")
        let payload = Data("SSH round trip — 中文 ' $HOME \n".utf8)
        try payload.write(to: local)
        let upload = TransferRequest(direction: .upload, entries: [try LocalFiles.entry(local)], destination: site.remotePath, conflictPolicy: .replace)
        _ = try await TransferEngine.run(upload, context: session.context, cancellation: CancellationFlag()) { _ in }
        let listing = try await RemoteOperations.list(site.remotePath, context: session.context, cancellation: CancellationFlag())
        let remote = try #require(listing.entries.first { $0.name == local.lastPathComponent })
        let download = TransferRequest(direction: .download, entries: [remote], destination: root.appendingPathComponent("download").path, conflictPolicy: .replace)
        _ = try await TransferEngine.run(download, context: session.context, cancellation: CancellationFlag()) { _ in }
        #expect(try Data(contentsOf: root.appendingPathComponent("download").appendingPathComponent(local.lastPathComponent)) == payload)
        try await RemoteOperations.delete([remote], context: session.context, cancellation: CancellationFlag())
        #expect(try await RemoteOperations.list(site.remotePath, context: session.context, cancellation: CancellationFlag()).entries.allSatisfy { $0.name != remote.name })
    }

    @Test func changedHostKeyIsRejected() async throws {
        let (root, site) = try fixture()
        await #expect(throws: MacSCPError.self) {
            let session = try await SSHSession.connect(site: site, askPassPath: "/usr/bin/false", cancellation: CancellationFlag(),
                                                      knownHostsFile: root.appendingPathComponent("wrong_hosts"))
            session.disconnect()
        }
    }

    @Test func disconnectedMasterDoesNotReconnectSilently() async throws {
        let (root, site) = try fixture()
        let session = try await SSHSession.connect(site: site, askPassPath: "/usr/bin/false", cancellation: CancellationFlag(),
                                                  knownHostsFile: root.appendingPathComponent("known_hosts"))
        let context = session.context
        session.disconnect()
        await #expect(throws: MacSCPError.self) {
            try await RemoteOperations.list(site.remotePath, context: context, cancellation: CancellationFlag())
        }
    }
}
