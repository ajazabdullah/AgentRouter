import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
}
private final class Bytes: @unchecked Sendable {
    var data = Data()
}
public enum ProcessRunner {
    private static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()
    public static func run(_ executable: String, _ arguments: [String], input: Data? = nil, timeout: Double = 6) throws -> CommandResult {
        _ = ignoreBrokenPipe
        let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        try p.run()
        let group = DispatchGroup(), out = Bytes(), err = Bytes()
        group.enter()
        DispatchQueue.global().async { out.data = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { err.data = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let watchdog = DispatchWorkItem { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel(); if p.isRunning { p.terminate() } }
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit(); group.wait()
        return CommandResult(status: p.terminationStatus, output: String(decoding: out.data, as: UTF8.self), error: String(decoding: err.data, as: UTF8.self))
    }
}

public struct ProcessInfoEntry: Sendable {
    public let pid: Int32
    public let parent: Int32
    public let executable: String
}
public enum ProcessTable {
    public static func entries() throws -> [ProcessInfoEntry] {
        let result = try ProcessRunner.run("/bin/ps", ["-axo", "pid=,ppid=,comm="])
        guard result.status == 0 else { throw RouterError.message("Cannot verify process health: \(result.error)") }
        return result.output.split(separator: "\n").compactMap {
            let fields = $0.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return ProcessInfoEntry(pid: pid, parent: parent, executable: String(fields[2]))
        }
    }
    public static func startTime(_ pid: Int32) throws -> String {
        let r = try ProcessRunner.run("/bin/ps", ["-p", String(pid), "-o", "lstart="])
        guard r.status == 0, !r.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RouterError.message("Agent process no longer exists.") }
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func descendants(of pid: Int32, in entries: [ProcessInfoEntry]) -> [ProcessInfoEntry] {
        var ids: Set<Int32> = [pid]
        for _ in 0..<32 {
            let next = Set(entries.filter { ids.contains($0.parent) }.map(\.pid))
            let count = ids.count; ids.formUnion(next)
            if count == ids.count { break }
        }
        return entries.filter { ids.contains($0.pid) }
    }
}
