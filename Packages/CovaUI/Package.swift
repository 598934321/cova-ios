// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CovaUI",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "CovaUI", targets: ["CovaUI"])
    ],
    dependencies: [
        .package(path: "../CovaCore")
    ],
    targets: [
        .target(
            name: "CovaUI",
            dependencies: [.product(name: "CovaCore", package: "CovaCore")]
        )
    ],
    swiftLanguageModes: [.v6]
)
