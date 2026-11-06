// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TCKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "TCKit", targets: ["TCKit"])],
    targets: [
        .target(name: "TCKit", swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]),
        .testTarget(name: "TCKitTests", dependencies: ["TCKit"]),
    ],
    swiftLanguageModes: [.v5]
)
