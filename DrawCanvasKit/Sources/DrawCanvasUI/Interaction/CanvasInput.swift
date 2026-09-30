import Foundation
import DrawCanvasCore

public struct CanvasGeneration: Hashable, Sendable {
    public static let zero = CanvasGeneration(words: [0])

    private var words: [UInt64]

    init(words: [UInt64]) {
        var canonical = words
        while canonical.count > 1, canonical.last == 0 {
            canonical.removeLast()
        }
        self.words = canonical.isEmpty ? [0] : canonical
    }

    mutating func advance() {
        for index in words.indices {
            let (next, overflow) = words[index].addingReportingOverflow(1)
            words[index] = next
            if !overflow {
                return
            }
        }
        words.append(1)
    }
}

public typealias RecognitionGeneration = CanvasGeneration

public struct CanvasInkConfiguration: Codable, Hashable, Sendable {
    public var pressureEnabled: Bool
    public var widthMode: CanvasInkWidthMode

    public init(
        pressureEnabled: Bool = true,
        widthMode: CanvasInkWidthMode = .canvasScaled
    ) {
        self.pressureEnabled = pressureEnabled
        self.widthMode = widthMode
    }

    public static let `default` = CanvasInkConfiguration()
}

public enum CanvasPencilBatchPhase: Sendable, Equatable {
    case began
    case moved
    case ended
}

package enum CanvasInput: Sendable {
    case legacyPencilSamples([CanvasPoint], phase: CanvasPencilPhase)
    case pencilSamples(
        phase: CanvasPencilBatchPhase,
        confirmed: [CanvasInkSample],
        predicted: [CanvasInkSample]
    )
    case pencilDown(CanvasPoint)
    case pencilMoved(CanvasPoint)
    case pencilUp(CanvasPoint)
    case pencilCancelled
    case pencilHover(CanvasPoint?)
    case tap(CanvasPoint)
    case panBegan(CanvasPoint)
    case panChanged(cumulativeScreenDelta: CanvasPoint)
    case panEnded(screenVelocity: CanvasPoint)
    case pinchBegan(canvasAnchor: CanvasPoint, screenCentroid: CanvasPoint)
    case pinchChanged(scaleFromStart: Double, currentScreenCentroid: CanvasPoint)
    case pinchEnded
    case pinchCancelled
    case manipulationBegan(point: CanvasPoint)
    case manipulationChanged(cumulativeScreenDelta: CanvasPoint)
    case manipulationEnded
    case manipulationCancelled
    case previewAcquired(CanvasPreviewToken)
    case previewRejected
    case recognitionCompleted(request: RecognitionRequest, result: RecognitionResult?)
    case toolChanged(CanvasTool)
    case cancel
}

package extension CanvasInput {
    static func pencilSamples(
        _ points: [CanvasPoint],
        phase: CanvasPencilPhase
    ) -> CanvasInput {
        .legacyPencilSamples(points, phase: phase)
    }
}

package enum CanvasEffect: Sendable {
    case setViewport(CanvasViewport)
    case select(UUID?)
    case requestPreview(CanvasPreviewKind)
    case updatePreview(CanvasPreviewPayload, CanvasPreviewToken)
    case commitPreview(CanvasPreviewToken)
    case cancelPreview(CanvasPreviewToken)
    case perform(CanvasCommand)
    case setTransientPreview(CanvasElement?)
    case appendFreehandPreview(
        id: UUID,
        style: CanvasStyle,
        points: [CanvasPoint],
        token: CanvasPreviewToken
    )
    case appendFreehandInkPreview(
        id: UUID,
        style: CanvasStyle,
        confirmed: [CanvasInkSample],
        predicted: [CanvasInkSample],
        pressureEnabled: Bool,
        widthMode: CanvasInkWidthMode,
        token: CanvasPreviewToken
    )
    case recognize(RecognitionRequest)
    case setGuides([SnapGuide])
    case setEraserTarget(UUID?)
}

public enum ToolDraft: Sendable {
    case line(start: CanvasPoint, current: CanvasPoint)
    case rectangle(start: CanvasPoint, current: CanvasPoint)
    case archBase(start: CanvasPoint, current: CanvasPoint)
    case archSagitta(start: CanvasPoint, end: CanvasPoint, current: CanvasPoint)
    case freehand(pointCount: Int)
}

package enum CanvasPencilPhase: Sendable, Equatable {
    case down
    case moved
    case up
    case cancelled
}

package struct RecognitionFingerprint: Hashable, Sendable {
    package let documentID: UUID
    package let replacementGeneration: CanvasGeneration
    package let elementID: UUID
    package let contentRevision: UInt64
}

public struct RecognitionRequest: Hashable, Sendable {
    package var fingerprint: RecognitionFingerprint
    private var storedPoints: [CanvasPoint]
    package var inkSamples: [CanvasInkSample]?
    public var recognitionGeneration: CanvasGeneration

    public var points: [CanvasPoint] {
        get { inkSamples?.map(\.point) ?? storedPoints }
        set {
            storedPoints = newValue
            inkSamples = nil
        }
    }

    public var elementID: UUID { fingerprint.elementID }
    public var contentRevision: UInt64 { fingerprint.contentRevision }
    public var documentReplacementGeneration: CanvasGeneration {
        fingerprint.replacementGeneration
    }

    package init(
        fingerprint: RecognitionFingerprint,
        points: [CanvasPoint],
        recognitionGeneration: CanvasGeneration
    ) {
        self.fingerprint = fingerprint
        storedPoints = points
        inkSamples = nil
        self.recognitionGeneration = recognitionGeneration
    }

    package init(
        fingerprint: RecognitionFingerprint,
        inkSamples: [CanvasInkSample],
        recognitionGeneration: CanvasGeneration
    ) {
        self.fingerprint = fingerprint
        storedPoints = []
        self.inkSamples = inkSamples
        self.recognitionGeneration = recognitionGeneration
    }

}

public enum CanvasLineEndpoint: Sendable, Hashable {
    case first
    case second
}

public enum CanvasManipulationHandle: Sendable, Hashable {
    case move
    case resize(ResizeHandle)
    case lineEndpoint(CanvasLineEndpoint)
}

public enum CanvasInteractionState: Sendable {
    case idle
    case panning(startViewport: CanvasViewport, startScreen: CanvasPoint)
    case pinching(
        startViewport: CanvasViewport,
        canvasAnchor: CanvasPoint,
        startScreenCentroid: CanvasPoint
    )
    case awaitingFreehand(pointCount: Int)
    case awaitingManipulation(
        snapshot: CanvasElement,
        handle: CanvasManipulationHandle,
        startScreen: CanvasPoint
    )
    case manipulating(
        snapshot: CanvasElement,
        handle: CanvasManipulationHandle,
        startScreen: CanvasPoint
    )
    case drawing(ToolDraft)
    case awaitingErasure(
        start: CanvasPoint,
        targets: [UUID],
        documentID: UUID,
        replacementGeneration: CanvasGeneration
    )
    case erasing(
        lastPoint: CanvasPoint,
        targets: [UUID],
        documentID: UUID,
        replacementGeneration: CanvasGeneration
    )
}

public struct CanvasInteractionContext: Sendable {
    public var configuration: CanvasConfiguration
    public var documentID: UUID
    public var viewport: CanvasViewport
    public var elements: [CanvasElement]
    public var selectedElementID: UUID?
    public var proposedElementID: UUID
    public var documentReplacementGeneration: CanvasGeneration
    public var documentRevision: UInt64
    public var snapConfiguration: SnapConfiguration
    public var strokeStyle: CanvasStyle
    public var inkConfiguration: CanvasInkConfiguration
    public var recognitionEnabled: Bool
    public var hitToleranceScreen: Double
    public var resizeHandleToleranceScreen: Double
    public var minimumElementSize: Double

    public init(
        documentID: UUID,
        viewport: CanvasViewport,
        elements: [CanvasElement],
        selectedElementID: UUID?,
        proposedElementID: UUID,
        documentReplacementGeneration: CanvasGeneration,
        documentRevision: UInt64,
        snapConfiguration: SnapConfiguration,
        strokeStyle: CanvasStyle = .default,
        inkConfiguration: CanvasInkConfiguration = .default,
        recognitionEnabled: Bool = true,
        hitToleranceScreen: Double = 8,
        resizeHandleToleranceScreen: Double = 12,
        minimumElementSize: Double = 10,
        configuration: CanvasConfiguration = .default
    ) {
        self.configuration = configuration
        self.documentID = documentID
        self.viewport = viewport
        self.elements = elements
        self.selectedElementID = selectedElementID
        self.proposedElementID = proposedElementID
        self.documentReplacementGeneration = documentReplacementGeneration
        self.documentRevision = documentRevision
        self.snapConfiguration = snapConfiguration
        self.strokeStyle = strokeStyle
        self.inkConfiguration = inkConfiguration
        self.recognitionEnabled = recognitionEnabled
        self.hitToleranceScreen = hitToleranceScreen
        self.resizeHandleToleranceScreen = resizeHandleToleranceScreen
        self.minimumElementSize = minimumElementSize
    }
}
