// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CadenceCompanion",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CadenceCompanion",
            targets: ["CadenceCompanion"]
        )
    ],
    targets: [
        .target(
            name: "CadenceCompanion",
            path: "CadenceCompanion"
        ),
        .testTarget(
            name: "CadenceCompanionTests",
            dependencies: ["CadenceCompanion"],
            path: "Tests/CadenceCompanionTests"
        )
    ]
)
