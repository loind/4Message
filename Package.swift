// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Messenger",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Messenger", targets: ["Messenger"]),
    ],
    targets: [
        .executableTarget(
            name: "Messenger",
            path: "Sources/Messenger",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
