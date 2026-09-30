// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DrawCanvasKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "DrawCanvasCore", targets: ["DrawCanvasCore"]),
        .library(name: "DrawCanvasUI", targets: ["DrawCanvasUI"]),
    ],
    targets: [
        .target(name: "DrawCanvasCore"),
        .target(
            name: "DrawCanvasUI",
            dependencies: ["DrawCanvasCore"],
            resources: [.process("Rendering/Metal/Shaders")]
        ),
        .testTarget(
            name: "DrawCanvasCoreTests",
            dependencies: ["DrawCanvasCore"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(name: "DrawCanvasUITests", dependencies: ["DrawCanvasUI"]),
    ]
)
