// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CovaCore",
    // macOS 仅为在宿主侧跑覆盖率测量（Xcode 26.6 不为本地 SwiftPM 包目标生成 xccov 覆盖率，
    // 见 Scripts/check.sh 与 docs/log/20260917.md）；iOS 仍是产品目标平台。
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [
        .library(name: "CovaCore", targets: ["CovaCore"])
    ],
    targets: [
        .target(name: "CovaCore"),
        .testTarget(
            name: "CovaCoreTests",
            dependencies: ["CovaCore"],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
