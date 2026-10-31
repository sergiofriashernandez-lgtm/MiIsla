// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MiIsla",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MiIsla",
            path: "Sources/MiIsla"
        )
    ]
)
