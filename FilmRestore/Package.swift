// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FilmRestore",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "FilmRestore",
            path: "Sources/FilmRestore",
            resources: [.copy("Resources/scripts")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FilmRestoreTests",
            dependencies: ["FilmRestore"],
            path: "Tests/FilmRestoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
