// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppSigner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SigningKit", targets: ["SigningKit"]),
        .executable(name: "AppSigner", targets: ["AppSigner"]),
    ],
    targets: [
        .target(
            name: "SigningKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SigningKitTests",
            dependencies: ["SigningKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AppSigner",
            dependencies: ["SigningKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
