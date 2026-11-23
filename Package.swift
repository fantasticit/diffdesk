// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "diff+",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "diff+", targets: ["ChangeDesk"])],
    targets: [.executableTarget(name: "ChangeDesk")],
    swiftLanguageModes: [.v5]
)
