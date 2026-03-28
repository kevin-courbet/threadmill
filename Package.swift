// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Threadmill",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Threadmill",
            targets: ["Threadmill"]
        ),
        .executable(
            name: "threadmill-relay",
            targets: ["threadmill-relay"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/wiedymi/swift-acp", branch: "main"),
        .package(path: "Packages/CodeEditSourceEditor"),
        .package(path: "Packages/CodeEditLanguages"),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "threadmill-relay",
            path: "Sources/threadmill-relay"
        ),
        .executableTarget(
            name: "Threadmill",
            dependencies: [
                "GhosttyKit",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ACP", package: "swift-acp"),
                .product(name: "ACPModel", package: "swift-acp"),
                "CodeEditSourceEditor",
                "CodeEditLanguages",
            ],
            path: "Sources/Threadmill",
            exclude: [
                "_Fridge",
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Security"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("WebKit"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "ThreadmillTests",
            dependencies: ["Threadmill"],
            path: "Tests/ThreadmillTests"
        )
    ]
)
