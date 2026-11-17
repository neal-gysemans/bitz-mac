// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bitz",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "BitzCore",
            targets: ["BitzCore"]
        ),
        .executable(
            name: "Bitz",
            targets: ["Bitz"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1")
    ],
    targets: [
        .target(
            name: "BitzCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "src",
            exclude: ["Executable"],
            resources: [
                .process("Resources/Sounds")
            ]
        ),
        .executableTarget(
            name: "Bitz",
            dependencies: ["BitzCore"],
            path: "src/Executable"
        ),
        .testTarget(
            name: "BitzTests",
            dependencies: ["BitzCore"],
            path: "Tests/BitzTests"
        )
    ]
)
