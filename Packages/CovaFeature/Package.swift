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
        )
    ],
    swiftLanguageModes: [.v6]
)
