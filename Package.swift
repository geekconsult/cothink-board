// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CoThinkBoard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BoardCore", targets: ["BoardCore"]),
        .executable(name: "CoThinkBoard", targets: ["CoThinkApp"]),
        .executable(name: "cothink-mcp", targets: ["CoThinkMCP"])
    ],
    targets: [
        .target(name: "BoardCore"),
        .executableTarget(name: "CoThinkApp", dependencies: ["BoardCore"]),
        .executableTarget(name: "CoThinkMCP", dependencies: ["BoardCore"]),
        .testTarget(name: "BoardCoreTests", dependencies: ["BoardCore"])
    ]
)
