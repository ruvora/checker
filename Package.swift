// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Checker",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Checker", targets: ["Checker"])],
    targets: [
        .target(name: "CheckerCore"),
        .executableTarget(name: "Checker", dependencies: ["CheckerCore"]),
        .executableTarget(name: "CheckerCoreChecks", dependencies: ["CheckerCore"], path: "Tests/CheckerCoreChecks")
    ]
)
