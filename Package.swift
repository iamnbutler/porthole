// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "porthole",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "porthole",
            path: "Sources/porthole"
        ),
        .testTarget(
            name: "portholeTests",
            dependencies: ["porthole"],
            path: "Tests/portholeTests"
        ),
    ]
)
