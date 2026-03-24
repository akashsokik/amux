import Darwin
import Foundation

/// Unix domain socket server for receiving structured events from agent hook scripts.
/// Hook scripts connect and send JSON messages of the form:
///   {"paneId": "uuid-string", "tabId": "uuid-string?", "event": "event-name", "data": {...}}
final class AgentSocketServer {

    /// Socket path for the current process.
    static var defaultPath: String {
        "/tmp/amux-\(ProcessInfo.processInfo.processIdentifier).sock"
    }

    /// The path this server instance listens on.
    let path: String

    /// Called on the main queue when a valid event arrives.
    var onEvent: ((UUID, UUID?, String, [String: Any]) -> Void)?

    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]

    init() {
        self.path = Self.defaultPath
    }

    func start() {
        // Remove stale socket file if present.
        unlink(path)

        // Create socket.
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            NSLog("AgentSocketServer: socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        // Bind.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("AgentSocketServer: socket path too long")
            Darwin.close(listenFD)
            listenFD = -1
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dst, src.baseAddress!, src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenFD, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            NSLog("AgentSocketServer: bind() failed: \(String(cString: strerror(errno)))")
            Darwin.close(listenFD)
            listenFD = -1
            return
        }

        // Listen.
        guard listen(listenFD, 5) == 0 else {
            NSLog("AgentSocketServer: listen() failed: \(String(cString: strerror(errno)))")
            Darwin.close(listenFD)
            listenFD = -1
            return
        }

        // Dispatch source to accept incoming connections on the main queue.
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.listenFD, fd >= 0 {
                Darwin.close(fd)
                self?.listenFD = -1
            }
        }
        listenSource = source
        source.resume()
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil

        for (fd, source) in clientSources {
            source.cancel()
            Darwin.close(fd)
        }
        clientSources.removeAll()

        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }

        unlink(path)
    }

    deinit {
        stop()
    }

    // MARK: - Private

    private func acceptClient() {
        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(listenFD, sockPtr, &clientAddrLen)
            }
        }
        guard clientFD >= 0 else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readFromClient(fd: clientFD)
        }
        source.setCancelHandler { [weak self] in
            Darwin.close(clientFD)
            self?.clientSources.removeValue(forKey: clientFD)
        }
        clientSources[clientFD] = source
        source.resume()
    }

    private func readFromClient(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &buffer, buffer.count)

        if bytesRead <= 0 {
            // Client disconnected or error.
            clientSources[fd]?.cancel()
            return
        }

        guard let text = String(bytes: buffer.prefix(bytesRead), encoding: .utf8) else {
            NSLog("[AgentSocket] Failed to decode bytes as UTF-8")
            return
        }
        NSLog("[AgentSocket] Received: %@", text)

        guard let jsonData = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let paneIdString = json["paneId"] as? String,
              let paneId = UUID(uuidString: paneIdString),
              let event = json["event"] as? String else {
            NSLog("[AgentSocket] Failed to parse JSON from: %@", text)
            return
        }

        let tabId: UUID?
        if let tabIdString = json["tabId"] as? String {
            tabId = UUID(uuidString: tabIdString)
        } else {
            tabId = nil
        }
        let data = json["data"] as? [String: Any] ?? [:]
        onEvent?(paneId, tabId, event, data)
    }
}
