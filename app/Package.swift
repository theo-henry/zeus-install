// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zeus",
    // macOS 13.3: the minimum of the whisper.cpp framework.
    platforms: [.macOS("13.3")],
    targets: [
        .target(name: "CPTY", path: "Sources/CPTY"),
        // Local speech to text: whisper.cpp 1.9.3 (commit 371b5a7, its build b4938) with Metal, as the release
        // publishes it. The checksum pins the file; see docs/dictation-models.md before a change.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b4938/whisper-b4938-xcframework.zip",
            checksum: "dcc6cdc6d6902d11893434ceda70c23a2a64450f65a1b570035c9908988dfedd"
        ),
        .executableTarget(
            name: "Zeus",
            dependencies: ["CPTY", "whisper"],
            path: "Sources/Zeus",
            linkerSettings: [
                // whisper.framework is in Zeus.app/Contents/Frameworks, and next to the binary of a development build.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
            ]
        ),
    ]
)
