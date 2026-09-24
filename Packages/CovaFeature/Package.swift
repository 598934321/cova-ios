// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CovaFeature",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "CovaFeature", targets: ["CovaFeature"])
    ],
    dependencies: [
        .package(path: "../CovaCore"),
        .package(path: "../CovaPlayer"),
        .package(path: "../CovaUI")
    ],
    targets: [
        .target(
            name: "CovaFeature",
            dependencies: [
                .product(name: "CovaCore", package: "CovaCore"),
                .product(name: "CovaPlayer", package: "CovaPlayer"),
                .product(name: "CovaUI", package: "CovaUI")
            ]
        ),
        // R18-2 建的最小测试目标：只钉「美术腿的媒体裁决」（10 条腿各自的字段 → 裁决结果，23 条用例）。
        // 它**不是**功能层的完整测试面：没有 UI 快照框架，视图体（body）不在覆盖范围内，
        // 导航/登录态/播放器联动同样没测 —— 那批按第 18 轮裁决留给后续批次与门禁 owner 定地板。
        .testTarget(
            name: "CovaFeatureTests",
            dependencies: [
                "CovaFeature",
                .product(name: "CovaCore", package: "CovaCore"),
                .product(name: "CovaUI", package: "CovaUI"),
            ],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
