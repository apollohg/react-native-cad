import Foundation
import CadCanvasCore

public enum CanvasRenderKey: Hashable {
    case committed(id: UUID, contentRevision: UInt64)
    case preview(id: UUID, generation: RecognitionGeneration)
}

@MainActor
public final class CanvasPreparedInk {
    struct IncrementalCandidate {
        let expectedGeneration: RecognitionGeneration
        let expectedConfirmedSampleCount: Int
        let appendedConfirmedSamples: [CanvasInkSample]
        let predictedSamples: [CanvasInkSample]
        let finalizedConfirmedSampleCount: Int
        let stableSpanCount: Int
        let stableSpanBounds: CanvasRect?
        let confirmedBounds: CanvasRect
        let evaluatedSpanCount: Int
    }

    public private(set) var confirmedSamples: [CanvasInkSample]
    public private(set) var predictedSamples: [CanvasInkSample]
    public private(set) var generation: RecognitionGeneration
    public private(set) var finalizedConfirmedSampleCount: Int
    package private(set) var confirmedBounds: CanvasRect?
    public let pressureEnabled: Bool
    public let widthMode: CanvasInkWidthMode
    private var supportsIncrementalBounds: Bool
    private var stableSpanCount = 0
    private var stableSpanBounds: CanvasRect?
    private(set) var incrementalBoundsEvaluatedSpanCount = 0

    public init(
        confirmedSamples: [CanvasInkSample],
        pressureEnabled: Bool,
        widthMode: CanvasInkWidthMode = .canvasScaled
    ) {
        self.confirmedSamples = confirmedSamples
        predictedSamples = []
        generation = .zero
        finalizedConfirmedSampleCount = confirmedSamples.count
        confirmedBounds = nil
        self.pressureEnabled = pressureEnabled
        self.widthMode = widthMode
        supportsIncrementalBounds = false
    }

    init(
        confirmedSamples: [CanvasInkSample],
        predictedSamples: [CanvasInkSample],
        pressureEnabled: Bool,
        widthMode: CanvasInkWidthMode = .canvasScaled,
        isFinalized: Bool
    ) {
        let boundary = CanvasInkCurve.incrementalBoundary(
            confirmedPrefix: confirmedSamples,
            appending: [],
            isFinalized: isFinalized
        )
        self.confirmedSamples = confirmedSamples
        self.predictedSamples = predictedSamples
        generation = .zero
        finalizedConfirmedSampleCount = boundary.finalizedSampleCount
        confirmedBounds = nil
        self.pressureEnabled = pressureEnabled
        self.widthMode = widthMode
        supportsIncrementalBounds = confirmedSamples.isEmpty
            && predictedSamples.isEmpty
            && !isFinalized
        stableSpanCount = boundary.stableSpanCount
    }

    public func snapshot() -> CanvasPreparedInkSnapshot {
        CanvasPreparedInkSnapshot(
            confirmed: confirmedSamples,
            predicted: predictedSamples,
            pressureEnabled: pressureEnabled,
            widthMode: widthMode,
            finalizedConfirmedSampleCount: finalizedConfirmedSampleCount
        )
    }

    @discardableResult
    func appendConfirmed(_ candidate: [CanvasInkSample]) -> Bool {
        guard isPrefix(confirmedSamples, of: candidate) else { return false }
        apply(
            confirmed: candidate,
            predicted: predictedSamples,
            isFinalized: false
        )
        return true
    }

    func replacePredicted(_ replacement: [CanvasInkSample]) {
        apply(
            confirmed: confirmedSamples,
            predicted: replacement,
            isFinalized: false
        )
    }

    func finalizeConfirmed() {
        apply(
            confirmed: confirmedSamples,
            predicted: [],
            isFinalized: true
        )
    }

    @discardableResult
    func apply(
        confirmed candidateConfirmed: [CanvasInkSample],
        predicted candidatePredicted: [CanvasInkSample],
        isFinalized: Bool
    ) -> Bool {
        guard isPrefix(confirmedSamples, of: candidateConfirmed) else { return false }
        let boundary = CanvasInkCurve.incrementalBoundary(
            confirmedPrefix: candidateConfirmed,
            appending: [],
            isFinalized: isFinalized
        )
        let candidateFinalizedCount = boundary.finalizedSampleCount
        guard confirmedSamples != candidateConfirmed
                || predictedSamples != candidatePredicted
                || finalizedConfirmedSampleCount != candidateFinalizedCount else {
            return true
        }
        confirmedSamples = candidateConfirmed
        predictedSamples = candidatePredicted
        finalizedConfirmedSampleCount = candidateFinalizedCount
        supportsIncrementalBounds = false
        stableSpanCount = boundary.stableSpanCount
        stableSpanBounds = nil
        confirmedBounds = nil
        generation.advance()
        return true
    }

    func makeIncrementalCandidate(
        appendingConfirmed appendedConfirmedSamples: [CanvasInkSample],
        predicted candidatePredictedSamples: [CanvasInkSample],
        isFinalized: Bool
    ) throws -> IncrementalCandidate {
        guard supportsIncrementalBounds else {
            throw CanvasInkCurveError.invalidInput
        }
        try validate(samples: appendedConfirmedSamples)
        try validate(samples: candidatePredictedSamples)

        let candidateConfirmedCount = confirmedSamples.count + appendedConfirmedSamples.count
        let boundary = CanvasInkCurve.incrementalBoundary(
            confirmedPrefix: confirmedSamples,
            appending: appendedConfirmedSamples,
            isFinalized: isFinalized
        )
        let candidateFinalizedCount = boundary.finalizedSampleCount
        let candidateStableSpanCount = boundary.stableSpanCount
        guard candidateStableSpanCount >= stableSpanCount else {
            throw CanvasInkCurveError.invalidInput
        }

        let newlyStableRange = stableSpanCount..<candidateStableSpanCount
        let newlyStableBounds = try CanvasInkCurve.boundsOfSpans(
            confirmedPrefix: confirmedSamples,
            appending: appendedConfirmedSamples,
            spanRange: newlyStableRange
        )
        let candidateStableBounds = union(stableSpanBounds, newlyStableBounds)
        let confirmedSpanCount = max(0, candidateConfirmedCount - 1)
        let unresolvedRange = candidateStableSpanCount..<confirmedSpanCount
        let unresolvedBounds = try CanvasInkCurve.boundsOfSpans(
            confirmedPrefix: confirmedSamples,
            appending: appendedConfirmedSamples,
            spanRange: unresolvedRange
        )

        let confirmedBounds: CanvasRect
        if candidateConfirmedCount == 0 {
            confirmedBounds = CanvasRect(x: 0, y: 0, width: 0, height: 0)
        } else if candidateConfirmedCount == 1 {
            let sample = appendedConfirmedSamples.first ?? confirmedSamples[0]
            confirmedBounds = CanvasRect(
                x: sample.point.x,
                y: sample.point.y,
                width: 0,
                height: 0
            )
        } else if let combinedBounds = union(candidateStableBounds, unresolvedBounds) {
            confirmedBounds = combinedBounds
        } else {
            throw CanvasInkCurveError.invalidInput
        }

        if !appendedConfirmedSamples.isEmpty || !candidatePredictedSamples.isEmpty {
            let appendedForValidation = appendedConfirmedSamples + candidatePredictedSamples
            let combinedSampleCount = confirmedSamples.count + appendedForValidation.count
            let affectedSpanStart = stableSpanCount
            _ = try CanvasInkCurve.boundsOfSpans(
                confirmedPrefix: confirmedSamples,
                appending: appendedForValidation,
                spanRange: affectedSpanStart..<max(0, combinedSampleCount - 1)
            )
        }

        return IncrementalCandidate(
            expectedGeneration: generation,
            expectedConfirmedSampleCount: confirmedSamples.count,
            appendedConfirmedSamples: appendedConfirmedSamples,
            predictedSamples: candidatePredictedSamples,
            finalizedConfirmedSampleCount: candidateFinalizedCount,
            stableSpanCount: candidateStableSpanCount,
            stableSpanBounds: candidateStableBounds,
            confirmedBounds: confirmedBounds,
            evaluatedSpanCount: newlyStableRange.count + unresolvedRange.count
        )
    }

    @discardableResult
    func apply(_ candidate: IncrementalCandidate) -> Bool {
        guard supportsIncrementalBounds,
              generation == candidate.expectedGeneration,
              confirmedSamples.count == candidate.expectedConfirmedSampleCount else {
            return false
        }
        let changed = !candidate.appendedConfirmedSamples.isEmpty
            || predictedSamples != candidate.predictedSamples
            || finalizedConfirmedSampleCount != candidate.finalizedConfirmedSampleCount
        confirmedSamples.append(contentsOf: candidate.appendedConfirmedSamples)
        predictedSamples = candidate.predictedSamples
        finalizedConfirmedSampleCount = candidate.finalizedConfirmedSampleCount
        stableSpanCount = candidate.stableSpanCount
        stableSpanBounds = candidate.stableSpanBounds
        confirmedBounds = candidate.confirmedBounds
        incrementalBoundsEvaluatedSpanCount += candidate.evaluatedSpanCount
        if changed {
            generation.advance()
        }
        return true
    }

    private func validate(samples: [CanvasInkSample]) throws {
        guard samples.allSatisfy({
            $0.point.x.isFinite && $0.point.y.isFinite && $0.pressure.isFinite
        }) else {
            throw CanvasInkCurveError.invalidInput
        }
    }

    private func union(_ first: CanvasRect?, _ second: CanvasRect?) -> CanvasRect? {
        guard let first else { return second }
        guard let second else { return first }
        let minimumX = min(first.minX, second.minX)
        let maximumX = max(first.maxX, second.maxX)
        let minimumY = min(first.minY, second.minY)
        let maximumY = max(first.maxY, second.maxY)
        let width = maximumX - minimumX
        let height = maximumY - minimumY
        guard minimumX.isFinite,
              minimumY.isFinite,
              width.isFinite,
              height.isFinite else {
            return nil
        }
        return CanvasRect(x: minimumX, y: minimumY, width: width, height: height)
    }

    private func isPrefix<T: Equatable>(_ prefix: [T], of candidate: [T]) -> Bool {
        prefix.count <= candidate.count
            && zip(prefix, candidate).allSatisfy { $0.0 == $0.1 }
    }
}

public struct CanvasPreparedInkSnapshot: Sendable {
    public let confirmed: [CanvasInkSample]
    public let predicted: [CanvasInkSample]
    public let pressureEnabled: Bool
    public let widthMode: CanvasInkWidthMode
    public let finalizedConfirmedSampleCount: Int

    public init(
        confirmed: [CanvasInkSample],
        predicted: [CanvasInkSample],
        pressureEnabled: Bool,
        widthMode: CanvasInkWidthMode = .canvasScaled,
        finalizedConfirmedSampleCount: Int
    ) {
        self.confirmed = confirmed
        self.predicted = predicted
        self.pressureEnabled = pressureEnabled
        self.widthMode = widthMode
        self.finalizedConfirmedSampleCount = finalizedConfirmedSampleCount
    }
}

public enum CanvasPreparedPath {
    case immutable(CanvasPath)
    case ink(CanvasPreparedInk)
}

/// Opaque identity for backend resources derived from one prepared geometry build.
///
/// The identity remains stable while the prepared geometry is reused and changes whenever
/// its renderable content is rebuilt, even when its model ``CanvasRenderKey`` is unchanged.
public struct CanvasPreparedResourceIdentity: Hashable, Sendable {
    private let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

public struct CanvasPreparedGeometry: Identifiable {
    public let id: UUID
    public let renderKey: CanvasRenderKey
    public let resourceIdentity = CanvasPreparedResourceIdentity()
    public let path: CanvasPreparedPath
    public let bounds: CanvasRect
    public let style: CanvasStyle
}

public struct CanvasPreparedGridLine {
    public let start: CanvasPoint
    public let end: CanvasPoint
    public var tier: CanvasGridTier = .minor
}

public enum CanvasGridTier: Sendable { case minor, major, axis }

public struct CanvasPreparedScene {
    let geometryLayers: CanvasPreparedGeometryLayers
    public var geometry: [CanvasPreparedGeometry] { geometryLayers.materialized }
    var committedGeometry: [CanvasPreparedGeometry] { geometryLayers.committed }
    var dynamicGeometry: [CanvasPreparedGeometry] { geometryLayers.dynamic }
    public let gridLines: [CanvasPreparedGridLine]
    public let selectionBounds: CanvasRect?
    public let guides: [SnapGuide]
    public let viewport: CanvasViewport
    public let theme: CanvasThemeSnapshot
    public let previewGeneration: RecognitionGeneration?

    init(
        geometry: [CanvasPreparedGeometry],
        gridLines: [CanvasPreparedGridLine],
        selectionBounds: CanvasRect?,
        guides: [SnapGuide],
        viewport: CanvasViewport,
        theme: CanvasThemeSnapshot,
        previewGeneration: RecognitionGeneration?
    ) {
        geometryLayers = CanvasPreparedGeometryLayers(geometry: geometry)
        self.gridLines = gridLines
        self.selectionBounds = selectionBounds
        self.guides = guides
        self.viewport = viewport
        self.theme = theme
        self.previewGeneration = previewGeneration
    }

    init(
        committedGeometry: [CanvasPreparedGeometry],
        dynamicGeometry: [CanvasPreparedGeometry],
        orderedGeometry: [CanvasPreparedGeometry]? = nil,
        gridLines: [CanvasPreparedGridLine],
        selectionBounds: CanvasRect?,
        guides: [SnapGuide],
        viewport: CanvasViewport,
        theme: CanvasThemeSnapshot,
        previewGeneration: RecognitionGeneration?
    ) {
        geometryLayers = CanvasPreparedGeometryLayers(
            committed: committedGeometry,
            dynamic: dynamicGeometry,
            ordered: orderedGeometry
        )
        self.gridLines = gridLines
        self.selectionBounds = selectionBounds
        self.guides = guides
        self.viewport = viewport
        self.theme = theme
        self.previewGeneration = previewGeneration
    }
}

struct CanvasTextDescriptor {
    let id: UUID
    let contentRevision: UInt64
    let frame: CanvasRect
    let text: String
    let font: CanvasFont
    let color: CanvasColor
    let isSelected: Bool
    let isEditing: Bool
    let previewGeneration: RecognitionGeneration?
    let viewport: CanvasViewport
    let theme: CanvasThemeSnapshot
}

package enum CanvasViewportRenderPhase: Equatable {
    case interactive
    case settled
}

struct CanvasCommittedGeneration: Hashable {
    let documentRevision: UInt64
    let replacementGeneration: RecognitionGeneration
}

struct CanvasCommittedItem {
    let documentIndex: Int
    let geometry: CanvasPreparedGeometry
    let paintedBounds: CanvasRect
}

struct CanvasCommittedReplacement {
    let documentIndex: Int
    let originalGeometry: CanvasPreparedGeometry
    let originalPaintedBounds: CanvasRect
    let replacementGeometry: CanvasPreparedGeometry
    let replacementPaintedBounds: CanvasRect
}

struct CanvasCommittedPresentation {
    let generation: CanvasCommittedGeneration
    let items: [CanvasCommittedItem]
    let replacement: CanvasCommittedReplacement?
}

struct CanvasPreparedPresentation {
    let scene: CanvasPreparedScene
    let textDescriptors: [CanvasTextDescriptor]
    let committed: CanvasCommittedPresentation
    let committedSnapshot: CanvasCommittedPreparedSnapshot?
    let viewportRenderPhase: CanvasViewportRenderPhase

    init(
        scene: CanvasPreparedScene,
        textDescriptors: [CanvasTextDescriptor],
        committed: CanvasCommittedPresentation,
        committedSnapshot: CanvasCommittedPreparedSnapshot? = nil,
        viewportRenderPhase: CanvasViewportRenderPhase
    ) {
        self.scene = scene
        self.textDescriptors = textDescriptors
        self.committed = committed
        self.committedSnapshot = committedSnapshot
        self.viewportRenderPhase = viewportRenderPhase
    }
}

struct CanvasScenePreparationStatistics: Equatable {
    var geometryBuildCount = 0
    var boundsBuildCount = 0
    var cachedGeometryCount = 0
    var committedElementVisitCount = 0
    var incrementalFreehandCommitCount = 0
    var incrementalFreehandCommitEvaluatedSpanCount = 0
}
