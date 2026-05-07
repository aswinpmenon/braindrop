// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Braindrop",
    platforms: [.macOS(.v14)],   // actual target is macOS 26; glass APIs guarded with @available
    targets: [
        .executableTarget(
            name: "Braindrop",
            path: "Sources/Braindrop"
        )
    ]
)
