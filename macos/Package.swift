// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MPVRadioTray",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "RadioMenuBar", targets: ["RadioMenuBar"])],
    targets: [
        .target(name: "RadioCore"),
        .executableTarget(name: "RadioMenuBar", dependencies: ["RadioCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["RadioCore"], path: "Tests/RadioCoreTests")
    ]
)
