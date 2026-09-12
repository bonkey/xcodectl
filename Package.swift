// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "xcodectl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "xcodectl", targets: ["xcodectl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/tuist/Noora", from: "0.57.0"),
        .package(url: "https://github.com/saagarjha/unxip", from: "3.2.0"),
        .package(url: "https://github.com/kinoroy/LibFido2Swift", from: "0.1.6"),
    ],
    targets: [
        .executableTarget(
            name: "xcodectl",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Noora", package: "Noora"),
                .product(name: "libunxip", package: "unxip"),
                .product(name: "LibFido2Swift", package: "LibFido2Swift"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Security"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
