import Darwin
import Foundation

/// Confined to one background worker except for the lock-protected stderr buffer.
/// poll + nonblocking descriptors bound cancellation latency even on a stalled server.
final class ProcessChannel {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let errorBuffer = ErrorBuffer()
    private var buffered = Data()
    let cancellation: CancellationFlag
    var timeout: TimeInterval = 60

    init(executable: String, arguments: [String], environment: [String: String]? = nil,
         cancellation: CancellationFlag) throws {
        self.cancellation = cancellation
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let buffer = errorBuffer
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffer.append(data) }
        }
        try cancellation.check()
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        for descriptor in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        // Writing to a closed SSH pipe must report an error, not terminate the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    deinit { stop() }
    var isRunning: Bool { process.isRunning }
    var errorText: String { errorBuffer.text }

    func stop() {
        if process.isRunning { process.terminate() }
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        // An in-flight stderr callback retains its FileHandle. ARC closes it
        // after the callback returns, rather than underneath availableData.
    }

    func write(_ data: Data) throws {
        var offset = 0
        var deadline = Date().addingTimeInterval(timeout)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < bytes.count {
                try ready(input.fileHandleForWriting.fileDescriptor, events: Int16(POLLOUT), deadline: deadline)
                let written = Darwin.write(input.fileHandleForWriting.fileDescriptor, base.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written; deadline = Date().addingTimeInterval(timeout) }
                else if written < 0, errno != EINTR, errno != EAGAIN { throw failure("无法写入 SSH 通道。") }
            }
        }
    }

    func readExactly(_ count: Int) throws -> Data {
        guard count >= 0, count <= 16 * 1024 * 1024 else { throw MacSCPError.protocolViolation("数据块过大") }
        while buffered.count < count {
            guard let data = try readChunk() else { throw failure("SSH 连接已关闭。") }
            buffered.append(data)
        }
        let result = Data(buffered.prefix(count))
        buffered.removeFirst(count)
        return result
    }

    func readLine() throws -> String {
        while !buffered.contains(10) {
            guard buffered.count < 64 * 1024 else { throw MacSCPError.protocolViolation("控制行过长") }
            guard let data = try readChunk() else { throw failure("SSH 连接已关闭。") }
            buffered.append(data)
        }
        guard let index = buffered.firstIndex(of: 10) else { throw MacSCPError.protocolViolation("缺少换行") }
        let data = buffered[..<index]
        guard let line = String(data: data, encoding: .utf8) else { throw MacSCPError.protocolViolation("文件名不是 UTF-8") }
        buffered.removeSubrange(...index)
        return line
    }

    func readToEnd(limit: Int = 64 * 1024 * 1024) throws -> Data {
        var data = buffered
        buffered.removeAll()
        while let chunk = try readChunk() {
            data.append(chunk)
            guard data.count <= limit else { throw MacSCPError.message("服务器目录输出超过安全上限。") }
        }
        try finish()
        return data
    }

    func finish() throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            try cancellation.check()
            guard Date() < deadline else { throw failure("SSH 操作超时。") }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure("SSH 进程退出，状态码 \(process.terminationStatus)。") }
    }

    func closeInput() { try? input.fileHandleForWriting.close() }

    private func readChunk() throws -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try ready(output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), deadline: deadline)
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return nil }
            if errno != EINTR, errno != EAGAIN { throw failure("无法读取 SSH 通道。") }
        }
    }

    private func ready(_ descriptor: Int32, events: Int16, deadline: Date) throws {
        while true {
            try cancellation.check()
            guard Date() < deadline else { throw failure("服务器长时间没有响应，操作已超时。") }
            var info = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&info, 1, 150)
            if result > 0 { return }
            if result < 0, errno != EINTR { throw failure("SSH 通道不可用。") }
        }
    }

    private func failure(_ fallback: String) -> MacSCPError {
        let detail = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return .message(detail.isEmpty ? fallback : detail)
    }
}

private final class ErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > 64 * 1024 { data = Data(data.suffix(64 * 1024)) }
        }
    }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
