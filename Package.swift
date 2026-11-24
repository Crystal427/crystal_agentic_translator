// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrystalAgenticTranslator",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TranslatorCore", targets: ["TranslatorCore"]),
        .executable(name: "CrystalTranslator", targets: ["CrystalTranslatorApp"])
    ],
    targets: [
        .target(name: "TranslatorCore"),
        .executableTarget(name: "CrystalTranslatorApp", dependencies: ["TranslatorCore"]),
        .testTarget(name: "TranslatorCoreTests", dependencies: ["TranslatorCore"])
    ],
    swiftLanguageModes: [.v5]
)
