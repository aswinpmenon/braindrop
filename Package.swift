// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Braindrop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Braindrop",
            path: "Sources/Braindrop"
        )
    ]
)
