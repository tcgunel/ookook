// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Ookook",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned to a fork: the 1.18 release paces terminal repaints at a fixed
        // 16.67ms, so on a 120Hz or 180Hz screen output streaming into a tile is
        // visibly capped at 60fps. The fork carries one commit that paces at the
        // screen's refresh rate instead. Upstream master already replaced that
        // scheduler with a display-link frame loop, so this pin can go once a
        // release contains it.
        .package(url: "https://github.com/tcgunel/SwiftTerm", revision: "7fac06d29d74e1d0bcd865c04c7bee0a9dd9c6cd"),
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
            swiftSettings: [.swiftLanguageMode(.v5)],
            // opencode keeps its session history in a SQLite database; reading it
            // for the Resume menu needs the system library and nothing more.
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
