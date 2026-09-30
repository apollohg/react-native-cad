// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CadCanvasKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "CadCanvasCore", targets: ["CadCanvasCore"]),
        .library(name: "CadCanvasUI", targets: ["CadCanvasUI"]),
    ],
    targets: [
        .target(name: "CadCanvasCore"),
        .target(
            name: "CadCanvasUI",
            dependencies: ["CadCanvasCore"],
            resources: [.process("Rendering/Metal/Shaders")]
        ),
        .testTarget(
            name: "CadCanvasCoreTests",
            dependencies: ["CadCanvasCore"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(name: "CadCanvasUITests", dependencies: ["CadCanvasUI"]),
    ]
)
