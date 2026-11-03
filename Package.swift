// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CoThinkBoard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BoardCore", targets: ["BoardCore"]),
        .executable(name: "CoThinkBoard", targets: ["CoThinkApp"]),
        .executable(name: "cothink-mcp", targets: ["CoThinkMCP"]),
        .executable(name: "cothink-pdf", targets: ["CoThinkPDF"])
    ],
    targets: [
        .target(name: "BoardCore"),
        .target(name: "PiChatCore"),
        .target(name: "BoardPDFRendering", dependencies: ["BoardCore"]),
        .executableTarget(name: "CoThinkApp", dependencies: ["BoardCore", "BoardPDFRendering", "PiChatCore"]),
        .executableTarget(name: "CoThinkMCP", dependencies: ["BoardCore"]),
        .executableTarget(name: "CoThinkPDF", dependencies: ["BoardCore", "BoardPDFRendering"]),
        .testTarget(name: "BoardCoreTests", dependencies: ["BoardCore"]),
        .testTarget(name: "PiChatCoreTests", dependencies: ["PiChatCore"])
    ]
)
