// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Burrow",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BurrowCore", targets: ["BurrowCore"]),
        .executable(name: "Burrow", targets: ["Burrow"]),
        .executable(name: "burrow-worker", targets: ["BurrowWorker"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "BurrowCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Burrow", dependencies: ["BurrowCore"]),
        .executableTarget(name: "BurrowWorker", dependencies: ["BurrowCore"]),
        .testTarget(name: "BurrowCoreTests", dependencies: ["BurrowCore"])
    ],
    swiftLanguageModes: [.v5]
)
