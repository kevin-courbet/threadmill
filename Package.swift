// swift-tools-version: 5.10
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
        )
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Threadmill",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        )
    ]
)
