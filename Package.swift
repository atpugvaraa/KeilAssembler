// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "KeilAssembler",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "KeilAssembler", targets: ["KeilAssembler"]),
    ],
    targets: [
        .target(
            name: "KeilAssembler",
            resources: [.copy("Runtime/Resources/armd_rt.c")]
        ),
        .testTarget(
            name: "KeilAssemblerTests",
            dependencies: ["KeilAssembler"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
