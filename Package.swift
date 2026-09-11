// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkillPin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SkillPin", targets: ["SkillPin"]),
    ],
    targets: [
        .executableTarget(name: "SkillPin"),
        .testTarget(name: "SkillPinTests", dependencies: ["SkillPin"]),
    ]
)
