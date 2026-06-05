// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NorthStar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NorthStar", targets: ["NorthStar"])
    ],
    targets: [
        .executableTarget(name: "NorthStar")
    ]
)
