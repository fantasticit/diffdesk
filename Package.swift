// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChangeDesk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ChangeDesk", targets: ["ChangeDesk"])],
    targets: [.executableTarget(name: "ChangeDesk")],
    swiftLanguageModes: [.v5]
)
