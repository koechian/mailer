// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Mailer",
    // Same floor as Cued: macOS 15. The SVG icons load through NSImage, which
    // has read SVG since macOS 14; Apple's on-device model (the writing
    // fallback) is macOS 26 and sits behind availability checks.
    platforms: [.macOS("15.0")],
    dependencies: [
        // The writing model — suggested replies, ghost text, grammar fixes —
        // is Qwen 3.5 4B running in-process on the GPU through MLX, the same
        // stack and pinned versions as Cued, so the 2.9 GB model Cued already
        // downloaded (~/.cache/huggingface) is reused, never fetched again.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMinor(from: "3.32.3"), traits: []),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0")
    ],
    targets: [
        // OpenOTP's code detector (MIT, © 2026 jeninh), vendored unchanged so
        // its precision-first rules stay exactly as tested upstream. The
        // licence travels with it in LICENSE-OpenOTP.txt.
        .target(
            name: "OTPCore",
            path: "Sources/OTPCore",
            exclude: ["LICENSE-OpenOTP.txt"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Mailer",
            dependencies: [
                "OTPCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface")
            ],
            path: "Sources/Mailer",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Network"),
                // Weak: Apple's model exists only from macOS 26.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
                // Minimum 15, SDK 26, so macOS 26 draws it with today's look.
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos",
                              "-Xlinker", "15.0", "-Xlinker", "26.0"])
            ]
        ),
        .testTarget(
            name: "MailerTests",
            dependencies: ["Mailer", "OTPCore"],
            path: "Tests/MailerTests"
        )
    ]
)
