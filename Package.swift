// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Ookook",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned to a fork, which carries four changes the 1.18 release line
        // does not: repaints paced at the screen's refresh rate rather than a
        // fixed 16.67ms (upstream master replaced that scheduler with a
        // display-link frame loop, so that one can go once a release contains
        // it), the opt-in caret glide and line fade the terminal settings
        // drive, repainting only the rows whose content changed, and painting
        // a partly visible terminal in full - a clipped tile gets a draw of
        // its visible strip, and rows the cache skipped on it came back blank.
        .package(url: "https://github.com/tcgunel/SwiftTerm", revision: "ee5631ef0dbffcd70103397ce05fe95c68f05aa1"),
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
