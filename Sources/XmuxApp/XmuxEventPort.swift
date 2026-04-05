import Foundation
import Darwin

struct XmuxEventLine: Equatable {
    let timestamp: Date
    let raw: String
}

struct XmuxEventSnapshot {
    let path: String
    let lines: [XmuxEventLine]
}

/// Manages the `xmux.port` Unix socket, an in-memory ring buffer, and a durable events log.
final class XmuxEventPort: @unchecked Sendable {
    static let shared = XmuxEventPort()

    private(set) var path: String?
    private(set) var eventsLogPath: String?

    private let listenQueue = DispatchQueue(label: "xmux.event-port.listen")
    private let clientQueue = DispatchQueue(label: "xmux.event-port.clients", attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "xmux.event-port.state", attributes: .concurrent)
    private let maxLines = 10_000

    private var isStarted = false
    private var listenFD: Int32 = -1
    private var clientFDs: Set<Int32> = []
    private var lines: [XmuxEventLine] = []

    private init() {}

    func setup() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".xmux")
        let socketPath = (dir as NSString).appendingPathComponent("xmux.port")
        let eventsPath = (dir as NSString).appendingPathComponent("xmux.events.log")

        do {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            if !FileManager.default.fileExists(atPath: eventsPath) {
                FileManager.default.createFile(atPath: eventsPath, contents: nil)
            }
            path = socketPath
            eventsLogPath = eventsPath
        } catch {
            return
        }

        guard !isStarted else { return }
        isStarted = true

        listenQueue.async { [weak self] in
            self?.runListener(at: socketPath)
        }
    }

    var displayPath: String {
        if let path, !path.isEmpty {
            return path
        }

        return (NSHomeDirectory() as NSString).appendingPathComponent(".xmux/xmux.port")
    }

    func snapshot() -> XmuxEventSnapshot {
        XmuxEventSnapshot(
            path: displayPath,
            lines: stateQueue.sync { lines }
        )
    }

    func clear() {
        stateQueue.sync(flags: .barrier) {
            self.lines.removeAll(keepingCapacity: true)
        }
    }

    /// Inject a line directly from within the app (same as if a client sent it).
    func emit(_ line: String) {
        record(line)
    }

    private func runListener(at socketPath: String) {
        cleanupSocketFile(at: socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        listenFD = fd

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        address.sun_family = sa_family_t(AF_UNIX)

        let socketPathBytes = Array(socketPath.utf8CString)
        guard socketPathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            cleanupSocketFile(at: socketPath)
            return
        }

        _ = socketPath.withCString { pathPointer in
            strncpy(&address.sun_path.0, pathPointer, socketPathBytes.count)
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }

        guard bindResult == 0 else {
            Darwin.close(fd)
            cleanupSocketFile(at: socketPath)
            return
        }

        guard Darwin.listen(fd, Int32(SOMAXCONN)) == 0 else {
            Darwin.close(fd)
            cleanupSocketFile(at: socketPath)
            return
        }

        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }

            configureClientSocket(clientFD)
            registerClient(clientFD)

            clientQueue.async { [weak self] in
                self?.handleClient(clientFD)
            }
        }

        if listenFD == fd {
            listenFD = -1
        }
        Darwin.close(fd)
        cleanupSocketFile(at: socketPath)
    }

    private func configureClientSocket(_ clientFD: Int32) {
        var enabled: Int32 = 1
        _ = withUnsafePointer(to: &enabled) { pointer in
            Darwin.setsockopt(
                clientFD,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
    }

    private func registerClient(_ clientFD: Int32) {
        let _: Void = stateQueue.sync(flags: .barrier) {
            self.clientFDs.insert(clientFD)
        }
    }

    private func unregisterClient(_ clientFD: Int32) {
        let _: Void = stateQueue.sync(flags: .barrier) {
            self.clientFDs.remove(clientFD)
        }
    }

    private func handleClient(_ clientFD: Int32) {
        defer {
            unregisterClient(clientFD)
            Darwin.close(clientFD)
        }

        var buffered = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let readCount = Darwin.read(clientFD, &chunk, chunk.count)
            if readCount > 0 {
                buffered.append(contentsOf: chunk.prefix(readCount))
                consumeCompleteLines(from: &buffered)
                continue
            }

            if readCount == 0 {
                break
            }

            if errno == EINTR {
                continue
            }

            break
        }

        if !buffered.isEmpty {
            consumeTerminalBuffer(buffered)
        }
    }

    private func consumeCompleteLines(from buffered: inout Data) {
        while let newlineIndex = buffered.firstIndex(of: 0x0A) {
            let line = Data(buffered[..<newlineIndex])
            let endIndex = buffered.index(after: newlineIndex)
            buffered.removeSubrange(buffered.startIndex..<endIndex)
            consumeLine(line)
        }
    }

    private func consumeLine(_ data: Data) {
        guard let line = normalizedValidJSONLine(from: data) else { return }
        record(line)
    }

    private func consumeTerminalBuffer(_ data: Data) {
        guard let line = normalizedValidJSONLine(from: data) else { return }
        record(line)
    }

    private func normalizedValidJSONLine(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        let line = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let jsonData = line.data(using: .utf8) else {
            return nil
        }

        guard (try? JSONSerialization.jsonObject(with: jsonData)) != nil else {
            return nil
        }

        return line
    }

    private func record(_ line: String) {
        let payload = "\(line)\n"
        let clientFDs = stateQueue.sync(flags: .barrier) {
            let timestamp = Date()
            lines.append(XmuxEventLine(timestamp: timestamp, raw: line))
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            appendToEventsLog(line, timestamp: timestamp)
            return Array(self.clientFDs)
        }

        for clientFD in clientFDs {
            if !writeAll(payload, to: clientFD) {
                unregisterClient(clientFD)
            }
        }
    }

    private func appendToEventsLog(_ line: String, timestamp: Date) {
        guard let eventsLogPath, let data = serializedEventsLogLine(line, timestamp: timestamp) else {
            return
        }

        if !FileManager.default.fileExists(atPath: eventsLogPath) {
            FileManager.default.createFile(atPath: eventsLogPath, contents: nil)
        }

        let url = URL(fileURLWithPath: eventsLogPath)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return
        }
        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    private func serializedEventsLogLine(_ line: String, timestamp: Date) -> Data? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let stamp = formatter.string(from: timestamp)
        return "\(stamp)\t\(line)\n".data(using: .utf8)
    }

    private func writeAll(_ string: String, to clientFD: Int32) -> Bool {
        let bytes = Array(string.utf8)
        var offset = 0

        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.send(
                    clientFD,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset,
                    0
                )
            }

            if written > 0 {
                offset += written
                continue
            }

            if written == -1 && errno == EINTR {
                continue
            }

            return false
        }

        return true
    }

    private func cleanupSocketFile(at socketPath: String) {
        Darwin.unlink(socketPath)
    }
}
