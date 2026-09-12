// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ullage",
    platforms: [.macOS(.v14)],
    products: [
        // The collector has no UI imports so that extracting it into a separate
        // daemon later (see plan §3, "escape hatch") stays mechanical.
        .library(name: "UllageCore", targets: ["UllageCore"]),
        .executable(name: "ullage", targets: ["ullage"]),
        .executable(name: "UllageApp", targets: ["UllageApp"]),
    ],
    targets: [
        .target(
            name: "CSQLite",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "UllageCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "ullage", dependencies: ["UllageCore"]),
        // The menu bar app. macOS-only in practice; the target builds elsewhere
        // so `swift build` stays one command on any platform.
        .executableTarget(name: "UllageApp", dependencies: ["UllageCore"]),
        .testTarget(name: "UllageCoreTests", dependencies: ["UllageCore"]),
    ]
)
