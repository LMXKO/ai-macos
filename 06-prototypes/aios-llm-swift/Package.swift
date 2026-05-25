// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AIOSLLMSwift",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "aios", targets: ["AIOS"])
    ],
    targets: [
        .executableTarget(
            name: "AIOS",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Vision"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ScriptingBridge"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
