// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zeus",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CPTY", path: "Sources/CPTY"),
        .executableTarget(
            name: "Zeus",
            dependencies: ["CPTY"],
            path: "Sources/Zeus"
        ),
    ]
)
