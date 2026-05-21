// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ColimaDock",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ColimaDock",
            path: "Sources",
            exclude: ["Info.plist"]
        )
    ]
)
