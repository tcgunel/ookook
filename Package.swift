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
        // Voice notes and video audio are transcribed on-device: DeepSeek takes
        // no audio, and Apple's speech models have no Turkish.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        // SQLCipher 4.x amalgamation, vendored from the tagged source release
        // (v4.19.0). The ticket pipeline reads ZapFast's message archive, which
        // is a SQLCipher database keyed from the login keychain; SQLCipher also
        // opens the plaintext databases unchanged, so it replaces the system
        // SQLite everywhere. CommonCrypto is the crypto provider - no OpenSSL.
        .target(
            name: "CSQLCipher",
            path: "Sources/CSQLCipher",
            publicHeadersPath: "include",
            cSettings: [
                // The amalgamation is maintained upstream; its own -Wshorten
                // warnings are noise for every clean build.
                .unsafeFlags(["-w"]),
                .define("SQLITE_HAS_CODEC", to: "1"),
                .define("SQLCIPHER_CRYPTO_CC", to: "1"),
                .define("SQLITE_TEMP_STORE", to: "2"),
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
                .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
                .define("NDEBUG", to: "1"),
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "Ookook",
            dependencies: [
                "CSQLCipher",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/Ookook",
            // SwiftTerm's view layer is main-thread-confined AppKit written against
            // the Swift 5 concurrency model; pin the language mode rather than fight
            // strict-concurrency diagnostics across the dependency boundary.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
