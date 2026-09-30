import simd

enum CanvasMetalLimits {
    static let resourceBudgetBytes = 64 * 1_024 * 1_024
    static let maximumCoveragePixelCount = 64 * 1_024 * 1_024
    static let maximumInFlightFrameCount = 3
}

enum MetalCanvasError: Error, Equatable {
    case deviceUnavailable
    case shaderLibraryUnavailable
    case functionUnavailable(String)
    case pipelineCreationFailed(String)
    case invalidResourceSize
    case resourceBudgetExceeded
    case commandEncodingFailed
    case commandBufferFailed
    case presentationCallbackUnavailable
    case invalidNumericInput
}

enum MetalFailurePermanence: Equatable {
    case temporary
    case permanent
}

struct MetalCanvasUniforms {
    var viewportSize: SIMD2<Float>
    var inverseViewportSize: SIMD2<Float>
}

struct MetalLineInstance {
    var start: SIMD2<Float>
    var end: SIMD2<Float>
    var color: SIMD4<Float>
    var lineWidth: Float
    var dashLength: Float = 0
    var dashPeriod: Float = 0
    var dashOffset: Float = 0
}

struct MetalBoxInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var fillColor: SIMD4<Float>
    var strokeColor: SIMD4<Float>
    var lineWidth: Float
    var padding0: Float = 0
    var padding1: Float = 0
    var padding2: Float = 0
}

struct MetalArcInstance {
    var start: SIMD2<Float>
    var end: SIMD2<Float>
    var center: SIMD2<Float>
    var radius: Float
    var geometryPadding: Float = 0
    var color: SIMD4<Float>
    var lineWidth: Float
    var padding0: Float = 0
    var padding1: Float = 0
    var padding2: Float = 0
}

struct MetalCoverageSegment {
    var start: SIMD2<Float>
    var end: SIMD2<Float>
    var startWidth: Float
    var endWidth: Float
    var padding0: Float = 0
    var padding1: Float = 0
}

struct MetalCompositeMaskParameters {
    var color: SIMD4<Float>
}

struct MetalMaskRegionParameters {
    var color: SIMD4<Float>
    var sourceOrigin: SIMD2<Float>
    var sourceSize: SIMD2<Float>
}

struct MetalTileCompositeParameters {
    var destinationOrigin: SIMD2<Float>
    var sourceScale: Float
    var gutter: Float
}

struct MetalMeshVertex {
    var position: SIMD2<Float>
    var layoutPadding: SIMD2<Float> = .zero
    var color: SIMD4<Float>
}

struct MetalStencilCoverParameters {
    var color: SIMD4<Float>
}
