// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Substage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Substage",
            path: "Sources/Substage"
        )
    ]
)
