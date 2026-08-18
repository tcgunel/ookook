// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Ookook",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.18.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Ookook",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/Ookook",
            // SwiftTerm's view layer is main-thread-confined AppKit written against
            // the Swift 5 concurrency model; pin the language mode rather than fight
            // strict-concurrency diagnostics across the dependency boundary.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
