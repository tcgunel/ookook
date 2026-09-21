// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Ookook",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned to a fork, which carries two changes the 1.18 release line does
        // not: repaints paced at the screen's refresh rate rather than a fixed
        // 16.67ms (upstream master replaced that scheduler with a display-link
        // frame loop, so this pin can go once a release contains it), and the
        // opt-in caret glide and line fade the terminal settings drive.
        .package(url: "https://github.com/tcgunel/SwiftTerm", revision: "3a30693ce221b1188ee190da1f3f97099dad0c52"),
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
