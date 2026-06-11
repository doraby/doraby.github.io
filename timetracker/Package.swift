// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "TaskTimeTracker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "TaskTimeTracker", path: "Sources/TaskTimeTracker")
    ]
)
