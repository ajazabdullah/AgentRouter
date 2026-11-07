// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AgentRouter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentRouter", targets: ["AgentRouter"])],
    targets: [
        .target(name: "RouterCore"),
        .executableTarget(name: "AgentRouter", dependencies: ["RouterCore"]),
        .executableTarget(name: "AgentRouterHook", dependencies: ["RouterCore"]),
        .testTarget(name: "RouterCoreTests", dependencies: ["RouterCore"])
    ]
)
