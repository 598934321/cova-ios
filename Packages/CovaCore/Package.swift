// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CovaCore",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "CovaCore", targets: ["CovaCore"])
    ],
    targets: [
        .target(name: "CovaCore")
    ],
    swiftLanguageModes: [.v6]
)
