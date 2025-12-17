// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JTimer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "JTimer",
            targets: ["JTimer"]
        )
    ],
    targets: [
        .executableTarget(
            name: "JTimer",
            dependencies: [],
            path: "Sources/JTimer"
        )
    ]
)