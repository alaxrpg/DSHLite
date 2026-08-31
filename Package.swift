// swift-tools-version: 5.9
//
//  DSH Lite — macOS 原生 DSH Web Runtime Supervisor + System WebView Shell
//
//  设计约束：
//  - 零第三方依赖（不使用任何 SPM 外部包）
//  - DSHHLiteCore: 纯逻辑层（无 AppKit/WebKit），可单元测试
//  - DSHLite:      App 壳（SwiftUI + WKWebView + Menu Bar）
//
import PackageDescription

let package = Package(
    name: "DSHLite",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DSHLite", targets: ["DSHLite"]),
        .library(name: "DSHLiteCore", targets: ["DSHLiteCore"])
    ],
    targets: [
        .target(
            name: "DSHLiteCore",
            path: "Sources/DSHLiteCore"
        ),
        .executableTarget(
            name: "DSHLite",
            dependencies: ["DSHLiteCore"],
            path: "Sources/DSHLite"
        ),
        .testTarget(
            name: "DSHLiteTests",
            dependencies: ["DSHLiteCore"],
            path: "Tests/DSHLiteTests"
        )
    ]
)
