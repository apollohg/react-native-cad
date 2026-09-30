import Metal
import XCTest
@testable import CadCanvasUI

@MainActor
final class MetalPipelineLibraryTests: XCTestCase {
    func testPackageMetalLibraryLoadsEveryRequiredFunction() throws {
        let device = try requiredMetalDevice()
        let library = try device.makeDefaultLibrary(bundle: MetalPipelineLibrary.moduleBundle)

        for name in MetalShaderFunctionNames.required.allNames {
            XCTAssertNotNil(library.makeFunction(name: name), "Missing Metal function: \(name)")
        }
    }

    func testPackageMetalLibraryLoadsMaskRegionFragment() throws {
        let device = try requiredMetalDevice()
        let library = try device.makeDefaultLibrary(bundle: MetalPipelineLibrary.moduleBundle)

        XCTAssertNotNil(library.makeFunction(name: "canvasCompositeMaskRegionFragment"))
    }

    func testPackageMetalLibraryLoadsCoverageSegmentVertex() throws {
        let device = try requiredMetalDevice()
        let library = try device.makeDefaultLibrary(bundle: MetalPipelineLibrary.moduleBundle)

        XCTAssertNotNil(library.makeFunction(name: "canvasCoverageSegmentVertex"))
    }

    func testPipelineLibraryBuildsEveryRequiredPipeline() throws {
        let pipelines = try MetalPipelineLibrary(device: requiredMetalDevice())

        XCTAssertEqual(pipelines.analyticLine.label, "Canvas analytic line")
        XCTAssertEqual(pipelines.analyticBox.label, "Canvas analytic box")
        XCTAssertEqual(pipelines.analyticArc.label, "Canvas analytic arc")
        XCTAssertEqual(pipelines.coverageSegment.label, "Canvas coverage segment")
        XCTAssertEqual(pipelines.compositeMask.label, "Canvas composite mask")
        XCTAssertEqual(pipelines.compositeMaskRegion.label, "Canvas composite mask region")
        XCTAssertEqual(pipelines.compositeTile.label, "Canvas committed tile composite")
        XCTAssertEqual(pipelines.mesh.label, "Canvas mesh")
        XCTAssertEqual(pipelines.stencilCover.label, "Canvas stencil cover")
    }

    func testCoveragePipelineUsesMaximumColorAndAlphaBlendOperations() throws {
        let pipelines = try MetalPipelineLibrary(device: requiredMetalDevice())
        let attachment = try XCTUnwrap(pipelines.coverageSegmentDescriptor.colorAttachments[0])

        XCTAssertTrue(attachment.isBlendingEnabled)
        XCTAssertEqual(attachment.rgbBlendOperation, .max)
        XCTAssertEqual(attachment.alphaBlendOperation, .max)
    }

    func testShaderParameterStridesMatchMetalABI() throws {
        XCTAssertEqual(MemoryLayout<MetalCanvasUniforms>.stride, 16)
        XCTAssertEqual(MemoryLayout<MetalLineInstance>.stride, 48)
        XCTAssertEqual(MemoryLayout<MetalBoxInstance>.stride, 64)
        XCTAssertEqual(MemoryLayout<MetalArcInstance>.stride, 64)
        XCTAssertEqual(MemoryLayout<MetalCoverageSegment>.stride, 32)
        XCTAssertEqual(MemoryLayout<MetalMaskRegionParameters>.stride, 32)
        XCTAssertEqual(MemoryLayout<MetalTileCompositeParameters>.stride, 16)
        XCTAssertEqual(MemoryLayout<MetalMeshVertex>.stride, 32)
    }

    func testMetalLimitsAreExactAndOverflowSafe() {
        XCTAssertEqual(CanvasMetalLimits.resourceBudgetBytes, 67_108_864)
        XCTAssertEqual(CanvasMetalLimits.maximumCoveragePixelCount, 67_108_864)
        XCTAssertEqual(CanvasMetalLimits.maximumInFlightFrameCount, 3)

        let coverageBytes = CanvasMetalLimits.maximumCoveragePixelCount
            .multipliedReportingOverflow(by: MemoryLayout<UInt8>.stride)
        XCTAssertFalse(coverageBytes.overflow)
        XCTAssertEqual(coverageBytes.partialValue, CanvasMetalLimits.resourceBudgetBytes)
    }

    func testMissingFunctionProducesTypedInitializationError() throws {
        let missingName = "intentionally_missing_canvas_fragment"
        var names = MetalShaderFunctionNames.required
        names.analyticLineFragment = missingName

        XCTAssertThrowsError(
            try MetalPipelineLibrary(
                device: requiredMetalDevice(),
                functionNames: names
            )
        ) { error in
            XCTAssertEqual(error as? MetalCanvasError, .functionUnavailable(missingName))
        }
    }

    private func requiredMetalDevice(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> any MTLDevice {
        try XCTUnwrap(
            MTLCreateSystemDefaultDevice(),
            "The iOS Simulator must provide a Metal device",
            file: file,
            line: line
        )
    }
}
