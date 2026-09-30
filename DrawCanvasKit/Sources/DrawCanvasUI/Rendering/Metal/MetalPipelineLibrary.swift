import Foundation
import Metal

struct MetalShaderFunctionNames {
    var unitQuadVertex: String
    var analyticLineFragment: String
    var analyticBoxFragment: String
    var analyticArcFragment: String
    var coverageSegmentVertex: String
    var coverageSegmentFragment: String
    var compositeMaskFragment: String
    var compositeMaskRegionFragment: String
    var compositeColorFragment: String
    var compositeTileFragment: String
    var meshVertex: String
    var meshFragment: String
    var stencilCoverFragment: String

    static let required = MetalShaderFunctionNames(
        unitQuadVertex: "canvasUnitQuadVertex",
        analyticLineFragment: "canvasAnalyticLineFragment",
        analyticBoxFragment: "canvasAnalyticBoxFragment",
        analyticArcFragment: "canvasAnalyticArcFragment",
        coverageSegmentVertex: "canvasCoverageSegmentVertex",
        coverageSegmentFragment: "canvasCoverageSegmentFragment",
        compositeMaskFragment: "canvasCompositeMaskFragment",
        compositeMaskRegionFragment: "canvasCompositeMaskRegionFragment",
        compositeColorFragment: "canvasCompositeColorFragment",
        compositeTileFragment: "canvasCompositeTileFragment",
        meshVertex: "canvasMeshVertex",
        meshFragment: "canvasMeshFragment",
        stencilCoverFragment: "canvasStencilCoverFragment"
    )

    var allNames: [String] {
        [
            unitQuadVertex,
            analyticLineFragment,
            analyticBoxFragment,
            analyticArcFragment,
            coverageSegmentVertex,
            coverageSegmentFragment,
            compositeMaskFragment,
            compositeMaskRegionFragment,
            compositeColorFragment,
            compositeTileFragment,
            meshVertex,
            meshFragment,
            stencilCoverFragment,
        ]
    }
}

@MainActor
final class MetalPipelineLibrary {
    static let moduleBundle = Bundle.module

    let analyticLine: any MTLRenderPipelineState
    let analyticBox: any MTLRenderPipelineState
    let analyticArc: any MTLRenderPipelineState
    let coverageSegment: any MTLRenderPipelineState
    let compositeMask: any MTLRenderPipelineState
    let compositeMaskRegion: any MTLRenderPipelineState
    let compositeColor: any MTLRenderPipelineState
    let compositeTile: any MTLRenderPipelineState
    let mesh: any MTLRenderPipelineState
    let stencilWinding: any MTLRenderPipelineState
    let stencilCover: any MTLRenderPipelineState

    let stencilWindingState: any MTLDepthStencilState
    let stencilUnionState: any MTLDepthStencilState
    let stencilCoverState: any MTLDepthStencilState

    let coverageSegmentDescriptor: MTLRenderPipelineDescriptor

    convenience init(device: any MTLDevice, bundle: Bundle = .module) throws {
        try self.init(
            device: device,
            bundle: bundle,
            functionNames: .required
        )
    }

    init(
        device: any MTLDevice,
        bundle: Bundle = .module,
        functionNames: MetalShaderFunctionNames
    ) throws {
        let library: any MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: bundle)
        } catch {
            throw MetalCanvasError.shaderLibraryUnavailable
        }

        func function(named name: String) throws -> any MTLFunction {
            guard let function = library.makeFunction(name: name) else {
                throw MetalCanvasError.functionUnavailable(name)
            }
            return function
        }

        let unitQuadVertex = try function(named: functionNames.unitQuadVertex)
        let analyticLineFragment = try function(named: functionNames.analyticLineFragment)
        let analyticBoxFragment = try function(named: functionNames.analyticBoxFragment)
        let analyticArcFragment = try function(named: functionNames.analyticArcFragment)
        let coverageSegmentVertex = try function(named: functionNames.coverageSegmentVertex)
        let coverageSegmentFragment = try function(named: functionNames.coverageSegmentFragment)
        let compositeMaskFragment = try function(named: functionNames.compositeMaskFragment)
        let compositeMaskRegionFragment = try function(
            named: functionNames.compositeMaskRegionFragment
        )
        let compositeColorFragment = try function(named: functionNames.compositeColorFragment)
        let compositeTileFragment = try function(named: functionNames.compositeTileFragment)
        let meshVertex = try function(named: functionNames.meshVertex)
        let meshFragment = try function(named: functionNames.meshFragment)
        let stencilCoverFragment = try function(named: functionNames.stencilCoverFragment)

        let analyticLineDescriptor = Self.colorPipelineDescriptor(
            label: "Canvas analytic line",
            vertex: unitQuadVertex,
            fragment: analyticLineFragment
        )
        let analyticBoxDescriptor = Self.colorPipelineDescriptor(
            label: "Canvas analytic box",
            vertex: unitQuadVertex,
            fragment: analyticBoxFragment
        )
        let analyticArcDescriptor = Self.colorPipelineDescriptor(
            label: "Canvas analytic arc",
            vertex: unitQuadVertex,
            fragment: analyticArcFragment
        )
        let coverageSegmentDescriptor = Self.coveragePipelineDescriptor(
            vertex: coverageSegmentVertex,
            fragment: coverageSegmentFragment
        )
        let compositeMaskDescriptor = Self.colorPipelineDescriptor(
            label: "Canvas composite mask",
            vertex: unitQuadVertex,
            fragment: compositeMaskFragment
        )
        let compositeMaskRegionDescriptor = Self.colorPipelineDescriptor(
            label: "Canvas composite mask region",
            vertex: unitQuadVertex,
            fragment: compositeMaskRegionFragment
        )
        let compositeColorDescriptor = Self.colorPipelineDescriptor(
            label: "Canvas composite color",
            vertex: unitQuadVertex,
            fragment: compositeColorFragment
        )
        let compositeTileDescriptor = Self.colorPipelineDescriptor(
            label: "Canvas committed tile composite",
            vertex: unitQuadVertex,
            fragment: compositeTileFragment
        )
        let meshDescriptor = Self.colorPipelineDescriptor(
            label: "Canvas mesh",
            vertex: meshVertex,
            fragment: meshFragment
        )
        let stencilWindingDescriptor = Self.colorPipelineDescriptor(
            label: "Canvas stencil winding",
            vertex: meshVertex,
            fragment: meshFragment
        )
        stencilWindingDescriptor.stencilAttachmentPixelFormat = .stencil8
        stencilWindingDescriptor.colorAttachments[0]?.writeMask = []
        let stencilCoverDescriptor = Self.colorPipelineDescriptor(
            label: "Canvas stencil cover",
            vertex: unitQuadVertex,
            fragment: stencilCoverFragment
        )
        stencilCoverDescriptor.stencilAttachmentPixelFormat = .stencil8

        analyticLine = try Self.makePipeline(
            device: device,
            descriptor: analyticLineDescriptor
        )
        analyticBox = try Self.makePipeline(
            device: device,
            descriptor: analyticBoxDescriptor
        )
        analyticArc = try Self.makePipeline(
            device: device,
            descriptor: analyticArcDescriptor
        )
        coverageSegment = try Self.makePipeline(
            device: device,
            descriptor: coverageSegmentDescriptor
        )
        compositeMask = try Self.makePipeline(
            device: device,
            descriptor: compositeMaskDescriptor
        )
        compositeMaskRegion = try Self.makePipeline(
            device: device,
            descriptor: compositeMaskRegionDescriptor
        )
        compositeColor = try Self.makePipeline(
            device: device,
            descriptor: compositeColorDescriptor
        )
        compositeTile = try Self.makePipeline(
            device: device,
            descriptor: compositeTileDescriptor
        )
        mesh = try Self.makePipeline(
            device: device,
            descriptor: meshDescriptor
        )
        stencilWinding = try Self.makePipeline(
            device: device,
            descriptor: stencilWindingDescriptor
        )
        stencilCover = try Self.makePipeline(
            device: device,
            descriptor: stencilCoverDescriptor
        )
        guard let windingState = device.makeDepthStencilState(
            descriptor: Self.stencilWindingDescriptor()
        ), let unionState = device.makeDepthStencilState(
            descriptor: Self.stencilUnionDescriptor()
        ), let coverState = device.makeDepthStencilState(
            descriptor: Self.stencilCoverDescriptor()
        ) else {
            throw MetalCanvasError.pipelineCreationFailed("Canvas stencil state")
        }
        stencilWindingState = windingState
        stencilUnionState = unionState
        stencilCoverState = coverState
        self.coverageSegmentDescriptor = coverageSegmentDescriptor
    }

    private static func colorPipelineDescriptor(
        label: String,
        vertex: any MTLFunction,
        fragment: any MTLFunction
    ) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment

        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = .bgra8Unorm
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .add
        attachment?.alphaBlendOperation = .add
        attachment?.sourceRGBBlendFactor = .one
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return descriptor
    }

    private static func coveragePipelineDescriptor(
        vertex: any MTLFunction,
        fragment: any MTLFunction
    ) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Canvas coverage segment"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment

        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = .r8Unorm
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .max
        attachment?.alphaBlendOperation = .max
        attachment?.sourceRGBBlendFactor = .one
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationRGBBlendFactor = .one
        attachment?.destinationAlphaBlendFactor = .one
        return descriptor
    }

    private static func makePipeline(
        device: any MTLDevice,
        descriptor: MTLRenderPipelineDescriptor
    ) throws -> any MTLRenderPipelineState {
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalCanvasError.pipelineCreationFailed(
                descriptor.label ?? "Unnamed canvas pipeline"
            )
        }
    }

    private static func stencilWindingDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.label = "Canvas signed winding stencil"
        let front = MTLStencilDescriptor()
        front.stencilCompareFunction = .always
        front.stencilFailureOperation = .keep
        front.depthFailureOperation = .keep
        front.depthStencilPassOperation = .incrementWrap
        front.readMask = 0xff
        front.writeMask = 0xff
        let back = MTLStencilDescriptor()
        back.stencilCompareFunction = .always
        back.stencilFailureOperation = .keep
        back.depthFailureOperation = .keep
        back.depthStencilPassOperation = .decrementWrap
        back.readMask = 0xff
        back.writeMask = 0xff
        descriptor.frontFaceStencil = front
        descriptor.backFaceStencil = back
        return descriptor
    }

    private static func stencilCoverDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.label = "Canvas nonzero winding cover"
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .notEqual
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        stencil.depthStencilPassOperation = .zero
        stencil.readMask = 0xff
        stencil.writeMask = 0xff
        descriptor.frontFaceStencil = stencil
        descriptor.backFaceStencil = stencil
        return descriptor
    }

    private static func stencilUnionDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.label = "Canvas stroke union stencil"
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .always
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        stencil.depthStencilPassOperation = .replace
        stencil.readMask = 0xff
        stencil.writeMask = 0xff
        descriptor.frontFaceStencil = stencil
        descriptor.backFaceStencil = stencil
        return descriptor
    }
}
