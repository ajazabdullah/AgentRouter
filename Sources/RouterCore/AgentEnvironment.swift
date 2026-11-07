import Foundation

enum AgentEnvironment {
    /// Finder does not inherit shell startup files. Include installed Homebrew Node
    /// runtimes so npm-based CLI launchers work even when the unversioned link is broken.
    static func path(for executable: String) -> String {
        let fm = FileManager.default
        var runtimeDirectories: [String] = []
        for root in ["/opt/homebrew/opt", "/usr/local/opt"] {
            let names = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            let versions = names.filter { $0.range(of: "^node@[0-9]+$", options: .regularExpression) != nil }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for name in versions + ["node"] {
                let bin = root + "/" + name + "/bin"
                if fm.isExecutableFile(atPath: bin + "/node") { runtimeDirectories.append(bin) }
            }
        }
        let cliDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        var checked = Set<String>()
        let workingRuntime = (runtimeDirectories + [cliDirectory] + inherited).first { directory in
            let node = directory + "/node"
            guard fm.isExecutableFile(atPath: node), checked.insert(URL(fileURLWithPath: node).resolvingSymlinksInPath().path).inserted,
                  let result = try? ProcessRunner.run(node, ["--version"], timeout: 2) else { return false }
            return result.status == 0 && result.output.hasPrefix("v")
        }
        // An executable symlink can still point to a Node with broken dylib dependencies.
        // A verified runtime must precede the CLI's directory and unversioned Homebrew bin.
        var directories = workingRuntime.map { [$0] } ?? []
        directories.append(cliDirectory)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        directories += inherited
        var seen = Set<String>()
        return directories.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
    }
}
