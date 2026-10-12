// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Backglow",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Backglow", targets: ["Backglow"])
    ],
    dependencies: [
        .package(path: "Vendor/ORSSerialPort")
    ],
    targets: [
        .target(name: "BackglowCore"),
        .executableTarget(
            name: "Backglow",
            dependencies: [
                "BackglowCore",
                .product(name: "ORSSerial", package: "ORSSerialPort")
            ],
            resources: [.copy("Shaders/ZoneAverage.metal")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "BackglowCoreTests", dependencies: ["BackglowCore"])
    ]
)
