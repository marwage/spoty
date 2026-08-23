// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Spoty",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git",
                 .upToNextMinor(from: "1.20.0"))
    ],
    targets: [
        .executableTarget(
            name: "Spoty",
            dependencies: ["SwiftTerm"]
        )
    ]
)
