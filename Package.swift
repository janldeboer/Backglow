// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AmbientLightingV3",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "AmbientLightingV3", targets: ["AmbientLightingV3"])
    ],
    dependencies: [
        .package(path: "Vendor/ORSSerialPort")
    ],
    targets: [
        .target(name: "AmbientLightingCore"),
        .executableTarget(
            name: "AmbientLightingV3",
            dependencies: [
                "AmbientLightingCore",
                .product(name: "ORSSerial", package: "ORSSerialPort")
            ],
            resources: [.copy("Shaders/ZoneAverage.metal")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "AmbientLightingCoreTests", dependencies: ["AmbientLightingCore"])
    ]
)
