// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodeEditSymbols",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "CodeEditSymbols",
            targets: ["CodeEditSymbols"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/pointfreeco/swift-snapshot-testing.git",
            from: "1.9.0"
        ),
    ],
    targets: [
        .target(
            name: "CodeEditSymbols",
            dependencies: [],
            exclude: ["Documentation.docc"],
            resources: [.process("Symbols.xcassets")]
        ),
        .testTarget(
            name: "CodeEditSymbolsTests",
            dependencies: [
                "CodeEditSymbols",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ]
        ),
    ]
)
