// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CovaPlayer",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "CovaPlayer", targets: ["CovaPlayer"])
    ],
    dependencies: [
        .package(path: "../CovaCore")
    ],
    targets: [
        .target(
            name: "CovaPlayer",
            dependencies: [.product(name: "CovaCore", package: "CovaCore")]
        )
    ],
    swiftLanguageModes: [.v6]
)
