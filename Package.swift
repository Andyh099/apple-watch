// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InterpreterCore",
    platforms: [.macOS(.v13), .iOS(.v18), .watchOS(.v11)],
    products: [.library(name: "InterpreterCore", targets: ["InterpreterCore"])],
    targets: [
        .target(name: "InterpreterCore"),
        .testTarget(name: "InterpreterCoreTests", dependencies: ["InterpreterCore"])
    ]
)
