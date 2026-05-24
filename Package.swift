// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Database",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "Database", targets: ["Database"]),
        .executable(name: "sql", targets: ["sql"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Database"
        ),
        .executableTarget(
            name: "sql",
            dependencies: [
                "Database",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/SQL"
        ),
        .testTarget(
            name: "DatabaseTests",
            dependencies: ["Database"]
        ),
    ]
)
