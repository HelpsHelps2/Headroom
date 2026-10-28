// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "HeadroomCore", targets: ["HeadroomCore"]),
        .executable(name: "Headroom", targets: ["Headroom"]),
        // Distinct from the app binary: macOS volumes are usually case-insensitive.
        .executable(name: "headroom-cli", targets: ["HeadroomCLI"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "HeadroomCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Headroom", dependencies: ["HeadroomCore"]),
        .executableTarget(name: "HeadroomCLI", dependencies: ["HeadroomCore"]),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"])
    ],
    swiftLanguageModes: [.v5]
)
