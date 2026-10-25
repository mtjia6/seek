// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Seek",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Seek",
            path: "Sources/Seek",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Ounchecked"])]
        )
    ]
)
