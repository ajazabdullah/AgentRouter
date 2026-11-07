import Foundation
import Darwin

public enum LocalIPC {
    public static let maximumBytes = 64 * 1024
    static func address(_ path: String) throws -> sockaddr_un {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: a.sun_path) else { throw RouterError.message("IPC socket path is too long.") }
        a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &a.sun_path) { target in target.copyBytes(from: bytes) }
        return a
    }
    static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0), noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }
    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else { throw RouterError.message("IPC write failed.") }
                offset += n
            }
        }
    }
    static func readExactly(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
                guard n > 0 else { throw RouterError.message("IPC read failed or timed out.") }
                offset += n
            }
        }
        return data
    }
    public static func send(_ data: Data, path: String) throws -> Bool {
        guard data.count <= maximumBytes else { throw RouterError.message("Hook event too large.") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RouterError.message("Cannot create local IPC socket.") }
        defer { Darwin.close(fd) }; configure(fd)
        var a = try address(path)
        let connected = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw RouterError.message("AgentRouter IPC is unavailable.") }
        var length = UInt32(data.count).bigEndian
        try writeAll(fd, withUnsafeBytes(of: &length) { Data($0) })
        try writeAll(fd, data)
        return try readExactly(fd, count: 1).first == 1
    }
}

/// Owner-only Unix socket, same-uid peer credentials, framed bounded payloads, no TCP listener.
public final class HookServer: @unchecked Sendable {
    private let fd: Int32
    public let path: String
    private let queue = DispatchQueue(label: "local.agentrouter.hooks")
    private let lock = NSLock()
    private var stopped = false
    public init(path: String, handler: @escaping @Sendable (Data, Int32) async -> Bool) throws {
        self.path = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try fm.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw RouterError.message("Unsafe IPC directory ownership.") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Probe before removing a stale socket: a second app must not steal a running endpoint.
        if fm.fileExists(atPath: path) {
            let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            var a = try LocalIPC.address(path)
            let active = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
            Darwin.close(probe)
            guard !active else { throw RouterError.message("Another AgentRouter instance owns the hook socket.") }
            let socketAttrs = try fm.attributesOfItem(atPath: path)
            guard socketAttrs[.type] as? FileAttributeType == .typeSocket else { throw RouterError.message("IPC path is occupied by a non-socket file.") }
            try fm.removeItem(atPath: path)
        }
        var a = try LocalIPC.address(path)
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RouterError.message("Cannot create hook listener.") }
        let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { Darwin.close(fd); throw RouterError.message("Cannot bind local hook listener.") }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 8) == 0 else { Darwin.close(fd); throw RouterError.message("Cannot listen for local hooks.") }
        let listener = fd
        queue.async { [weak self] in
            while let self, !self.isStopped {
                let peer = Darwin.accept(listener, nil, nil)
                if peer < 0 { break }
                LocalIPC.configure(peer)
                var uid: uid_t = 0, gid: gid_t = 0, pid: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                let sameUser = getpeereid(peer, &uid, &gid) == 0 && uid == getuid()
                let gotPID = getsockopt(peer, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0
                do {
                    guard sameUser, gotPID, pid > 0 else { throw RouterError.message("Unverified IPC peer.") }
                    let header = try LocalIPC.readExactly(peer, count: 4)
                    let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard length > 0, length <= LocalIPC.maximumBytes else { throw RouterError.message("Invalid hook frame.") }
                    let data = try LocalIPC.readExactly(peer, count: Int(length))
                    let semaphore = DispatchSemaphore(value: 0)
                    let response = IPCReply()
                    Task { response.accepted = await handler(data, pid); semaphore.signal() }
                    let done = semaphore.wait(timeout: .now() + 2) == .success
                    try LocalIPC.writeAll(peer, Data([done && response.accepted ? 1 : 0]))
                } catch { try? LocalIPC.writeAll(peer, Data([0])) }
                Darwin.close(peer)
            }
        }
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public func stop() {
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true; lock.unlock()
        Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd); unlink(path)
    }
    deinit { stop() }
}
private final class IPCReply: @unchecked Sendable { var accepted = false }
