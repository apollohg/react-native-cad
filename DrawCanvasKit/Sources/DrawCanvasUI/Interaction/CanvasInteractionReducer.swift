import Foundation
import DrawCanvasCore

@MainActor
public struct CanvasInteractionReducer: Sendable {
    public private(set) var state: CanvasInteractionState
    public private(set) var activeTool: CanvasTool
    public private(set) var recognitionGeneration: CanvasGeneration
    public private(set) var transientPreview: CanvasElement?

    private var manipulationStartViewport: CanvasViewport?
    private var activePreviewToken: CanvasPreviewToken?
    private var activeDraftID: UUID?
    private var archAwaitingSagittaStroke: Bool
    private var freehandPoints: [CanvasPoint]
    private var freehandInkSamples: [CanvasInkSample]
    private var freehandPredictedSamples: [CanvasInkSample]
    private var freehandUsesInk: Bool
    private var freehandPressureEnabled: Bool
    private var freehandWidthMode: CanvasInkWidthMode
    private var freehandStyle: CanvasStyle?
    private var eraserHitTester: CanvasEraserHitTester

    public init(
        activeTool: CanvasTool = .select,
        recognitionGeneration: CanvasGeneration = .zero
    ) {
        self.activeTool = activeTool
        state = .idle
        self.recognitionGeneration = recognitionGeneration
        transientPreview = nil
        manipulationStartViewport = nil
        activePreviewToken = nil
        activeDraftID = nil
        archAwaitingSagittaStroke = false
        freehandPoints = []
        freehandInkSamples = []
        freehandPredictedSamples = []
        freehandUsesInk = false
        freehandPressureEnabled = true
        freehandWidthMode = .canvasScaled
        freehandStyle = nil
        eraserHitTester = CanvasEraserHitTester()
    }

    init(
        activeTool: CanvasTool,
        state: CanvasInteractionState,
        recognitionGeneration: CanvasGeneration = .zero
    ) {
        self.activeTool = activeTool
        self.state = state
        self.recognitionGeneration = recognitionGeneration
        transientPreview = nil
        manipulationStartViewport = nil
        activePreviewToken = nil
        activeDraftID = nil
        archAwaitingSagittaStroke = false
        freehandPoints = []
        freehandInkSamples = []
        freehandPredictedSamples = []
        freehandUsesInk = false
        freehandPressureEnabled = true
        freehandWidthMode = .canvasScaled
        freehandStyle = nil
        eraserHitTester = CanvasEraserHitTester()
    }

    package mutating func reduce(
        _ input: CanvasInput,
        in context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        switch input {
        case .pencilSamples, .legacyPencilSamples, .pencilDown, .pencilMoved, .pencilUp, .pencilHover:
            guard context.configuration.allows(activeTool) else { return [] }
        case .tap:
            guard context.configuration.allows(.select) else { return [] }
        case .panBegan, .panChanged, .panEnded:
            guard context.configuration.allows(.panning) else { return [] }
        case .pinchBegan, .pinchChanged, .pinchEnded, .pinchCancelled:
            guard context.configuration.allows(.zooming) else { return [] }
        case .manipulationBegan, .manipulationChanged, .manipulationEnded, .manipulationCancelled:
            guard context.configuration.allows(.select) else { return [] }
        default:
            break
        }
        if case .pencilSamples(let phase, let confirmed, let predicted) = input {
            return reducePencilInkSamples(
                phase: phase,
                confirmed: confirmed,
                predicted: predicted,
                context: context
            )
        }
        if case .legacyPencilSamples(let points, let phase) = input {
            return reducePencilSamples(points, phase: phase, context: context)
        }
        if case .cancel = input {
            return cancelActiveInteraction()
        }
        if case .pencilCancelled = input {
            return cancelActiveInteraction()
        }

        if case .toolChanged(let tool) = input {
            return changeTool(to: tool)
        }

        if case .recognitionCompleted(let request, let result) = input {
            return applyRecognition(request: request, result: result, context: context)
        }

        if case .previewAcquired(let token) = input {
            return acceptPreview(token)
        }

        if case .previewRejected = input {
            return rejectPreview()
        }

        switch state {
        case .idle:
            return reduceIdle(input, context: context)
        case .panning(let startViewport, _):
            return reducePanning(input, startViewport: startViewport)
        case .pinching(let startViewport, let canvasAnchor, let startScreenCentroid):
            return reducePinching(
                input,
                startViewport: startViewport,
                canvasAnchor: canvasAnchor,
                startScreenCentroid: startScreenCentroid
            )
        case .awaitingFreehand:
            return []
        case .awaitingErasure:
            return []
        case .awaitingManipulation:
            return []
        case .manipulating(let snapshot, let handle, _):
            return reduceManipulating(
                input,
                snapshot: snapshot,
                handle: handle,
                context: context
            )
        case .drawing(let draft):
            return reduceDrawing(input, draft: draft, context: context)
        case .erasing:
            return reduceErasingInput(input, context: context)
        }
    }

    func canBeginManipulation(
        at point: CanvasPoint,
        in context: CanvasInteractionContext
    ) -> Bool {
        var copy = self
        return copy.beginManipulation(at: point, context: context).contains {
            if case .requestPreview = $0 { return true }
            return false
        }
    }
}

private extension CanvasInteractionReducer {
    mutating func reducePencilInkSamples(
        phase: CanvasPencilBatchPhase,
        confirmed: [CanvasInkSample],
        predicted: [CanvasInkSample],
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        let validConfirmed = confirmed.filter(validInkSample)
        let validPredicted = predicted.filter(validInkSample)
        guard !validConfirmed.isEmpty else { return [] }

        switch phase {
        case .began:
            let effects = reduce(.pencilDown(validConfirmed[0].point), in: context)
            if case .awaitingFreehand = state {
                freehandPoints = validConfirmed.map(\.point)
                freehandInkSamples = validConfirmed
                freehandPredictedSamples = validPredicted
                freehandUsesInk = true
                freehandPressureEnabled = context.inkConfiguration.pressureEnabled
                freehandWidthMode = context.inkConfiguration.widthMode
                state = .awaitingFreehand(pointCount: validConfirmed.count)
            }
            return effects
        case .moved, .ended:
            let points = validConfirmed.map(\.point)
            if case .erasing = state {
                return reduceEraserSamples(
                    points,
                    isUp: phase == .ended,
                    context: context
                )
            }
            if case .drawing(.freehand) = state, let id = activeDraftID {
                return reduceFreehandInkSamples(
                    validConfirmed,
                    predicted: phase == .ended ? [] : validPredicted,
                    isUp: phase == .ended,
                    id: id,
                    context: context
                )
            }
            guard let point = points.last else { return [] }
            return reduce(
                phase == .ended ? .pencilUp(point) : .pencilMoved(point),
                in: context
            )
        }
    }

    mutating func reducePencilSamples(
        _ points: [CanvasPoint],
        phase: CanvasPencilPhase,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        if case .cancelled = phase {
            return reduce(.pencilCancelled, in: context)
        }
        let validPoints = points.filter(finite)
        guard !validPoints.isEmpty else {
            if phase == .up, case .erasing = state {
                return reduceEraserSamples([], isUp: true, context: context)
            }
            return []
        }

        switch phase {
        case .down:
            return reduce(.pencilDown(validPoints[0]), in: context)
        case .moved, .up:
            if case .erasing = state {
                return reduceEraserSamples(
                    validPoints,
                    isUp: phase == .up,
                    context: context
                )
            }
            if case .drawing(.freehand) = state, let id = activeDraftID {
                return reduceFreehandSamples(
                    validPoints,
                    isUp: phase == .up,
                    id: id,
                    context: context
                )
            }
            guard let point = validPoints.last else { return [] }
            return reduce(phase == .up ? .pencilUp(point) : .pencilMoved(point), in: context)
        case .cancelled:
            return []
        }
    }

    mutating func reduceIdle(
        _ input: CanvasInput,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        switch input {
        case .pencilDown(let point):
            return beginDrawing(at: point, context: context)

        case .pencilCancelled:
            return cancelActiveInteraction()

        case .pencilHover(let point):
            guard activeTool == .eraser else { return [.setEraserTarget(nil)] }
            guard let point else { return [.setEraserTarget(nil)] }
            prepareEraserHitTester(for: context)
            return [.setEraserTarget(eraserHitTester.cachedHoverTarget(
                at: point,
                elements: context.elements,
                viewport: context.viewport,
                toleranceScreen: context.hitToleranceScreen
            ))]

        case .tap(let point):
            guard finite(point), valid(context.viewport) else { return [] }
            let tolerance = canvasDistance(
                screenDistance: context.hitToleranceScreen,
                viewport: context.viewport
            )
            guard let tolerance else { return [] }
            let selected = context.elements.reversed().first { element in
                element.geometry.hitTest(point, tolerance: tolerance, textBounds: element.bounds)
            }
            return [.select(selected?.id)]

        case .panBegan(let point):
            guard finite(point), valid(context.viewport) else { return [] }
            let screenPoint = context.viewport.screenPoint(fromCanvas: point)
            guard finite(screenPoint) else { return [] }
            state = .panning(startViewport: context.viewport, startScreen: screenPoint)
            return []

        case .pinchBegan(let canvasAnchor, let screenCentroid):
            guard finite(canvasAnchor), finite(screenCentroid), valid(context.viewport) else { return [] }
            state = .pinching(
                startViewport: context.viewport,
                canvasAnchor: canvasAnchor,
                startScreenCentroid: screenCentroid
            )
            return []

        case .manipulationBegan(let point):
            return beginManipulation(at: point, context: context)

        case .pencilSamples, .legacyPencilSamples, .pencilMoved, .pencilUp,
             .panChanged, .panEnded, .pinchChanged, .pinchEnded, .pinchCancelled,
             .manipulationChanged, .manipulationEnded, .manipulationCancelled,
             .previewAcquired, .previewRejected,
             .recognitionCompleted, .toolChanged, .cancel:
            return []
        }
    }

    mutating func reducePanning(
        _ input: CanvasInput,
        startViewport: CanvasViewport
    ) -> [CanvasEffect] {
        switch input {
        case .panChanged(let cumulativeScreenDelta):
            guard finite(cumulativeScreenDelta) else { return [] }
            guard let viewport = try? startViewport.panned(byScreen: cumulativeScreenDelta) else {
                return []
            }
            guard valid(viewport) else { return [] }
            return [.setViewport(viewport)]

        case .panEnded:
            // Velocity is advisory for a future animation layer. Ending a valid active pan is
            // deterministic even when UIKit reports a nonfinite terminal velocity.
            state = .idle
            return []

        default:
            return []
        }
    }

    mutating func reducePinching(
        _ input: CanvasInput,
        startViewport: CanvasViewport,
        canvasAnchor: CanvasPoint,
        startScreenCentroid: CanvasPoint
    ) -> [CanvasEffect] {
        switch input {
        case .pinchChanged(let scaleFromStart, let currentScreenCentroid):
            guard scaleFromStart.isFinite, scaleFromStart > 0,
                  finite(currentScreenCentroid), finite(startScreenCentroid) else { return [] }
            let proposedZoom = startViewport.zoom * scaleFromStart
            guard proposedZoom.isFinite else { return [] }
            guard let zoomed = try? startViewport.zoomed(
                by: scaleFromStart,
                anchoredAtScreen: startScreenCentroid
            ) else {
                return []
            }
            guard let viewport = try? CanvasViewport(
                zoom: zoomed.zoom,
                translation: .init(
                    x: currentScreenCentroid.x - canvasAnchor.x * zoomed.zoom,
                    y: currentScreenCentroid.y - canvasAnchor.y * zoomed.zoom
                ),
                viewportSize: zoomed.viewportSize
            ) else { return [] }
            guard valid(viewport) else { return [] }
            return [.setViewport(viewport)]

        case .pinchEnded:
            state = .idle
            return []

        case .pinchCancelled:
            state = .idle
            return [.setViewport(startViewport)]

        default:
            return []
        }
    }

    mutating func reduceManipulating(
        _ input: CanvasInput,
        snapshot: CanvasElement,
        handle: CanvasManipulationHandle,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        guard let token = activePreviewToken else {
            return rejectPreview()
        }
        switch input {
        case .manipulationChanged(let cumulativeScreenDelta):
            guard finite(cumulativeScreenDelta),
                  let startViewport = manipulationStartViewport,
                  valid(startViewport) else {
                return []
            }
            let canvasDelta = CanvasPoint(
                x: cumulativeScreenDelta.x / startViewport.zoom,
                y: cumulativeScreenDelta.y / startViewport.zoom
            )
            guard finite(canvasDelta) else { return [] }

            switch handle {
            case .move:
                return moveEffects(
                    snapshot: snapshot,
                    canvasDelta: canvasDelta,
                    viewport: startViewport,
                    context: context
                )

            case .resize(let resizeHandle):
                let element: CanvasElement
                do {
                    element = try executableResize(
                        original: snapshot,
                        handle: resizeHandle,
                        cumulativeDelta: canvasDelta,
                        minimumSize: context.minimumElementSize
                    )
                } catch {
                    return []
                }
                guard element.bounds.isFinite else { return [] }
                return [.updatePreview(.element(element), token), .setGuides([])]

            case .lineEndpoint(let endpoint):
                return lineEndpointEffects(
                    snapshot: snapshot,
                    endpoint: endpoint,
                    canvasDelta: canvasDelta
                )
            }

        case .manipulationEnded:
            state = .idle
            manipulationStartViewport = nil
            activePreviewToken = nil
            return [.commitPreview(token), .setGuides([])]

        case .manipulationCancelled:
            return cancelActiveInteraction()

        default:
            return []
        }
    }

    mutating func reduceDrawing(
        _ input: CanvasInput,
        draft: ToolDraft,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        if case .pencilCancelled = input {
            return cancelActiveInteraction()
        }

        guard let id = activeDraftID else { return [] }
        switch draft {
        case .line(let start, _):
            return reduceLine(input, id: id, start: start, context: context)
        case .rectangle(let start, _):
            return reduceRectangle(input, id: id, start: start, context: context)
        case .archBase(let start, _):
            return reduceArchBase(input, id: id, start: start, context: context)
        case .archSagitta(let start, let end, _):
            return reduceArchSagitta(
                input,
                id: id,
                start: start,
                end: end,
                context: context
            )
        case .freehand:
            return reduceFreehand(input, id: id, context: context)
        }
    }

    mutating func beginDrawing(
        at point: CanvasPoint,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        guard finite(point), valid(context.viewport) else { return [] }
        switch activeTool {
        case .line:
            let result = snapped(point, context: context)
            activeDraftID = context.proposedElementID
            state = .drawing(.line(start: result.point, current: result.point))
            return setDrawingPreview(
                CanvasElement(
                    id: context.proposedElementID,
                    geometry: .line(.init(start: result.point, end: result.point)),
                    style: context.strokeStyle
                ),
                guides: result.guides
            )
        case .rectangle:
            let result = snapped(point, context: context)
            activeDraftID = context.proposedElementID
            state = .drawing(.rectangle(start: result.point, current: result.point))
            return setDrawingPreview(
                CanvasElement.rectangle(
                    id: context.proposedElementID,
                    rect: normalizedRect(from: result.point, to: result.point),
                    style: context.strokeStyle
                ),
                guides: result.guides
            )
        case .arch:
            let result = snapped(point, context: context)
            activeDraftID = context.proposedElementID
            archAwaitingSagittaStroke = false
            state = .drawing(.archBase(start: result.point, current: result.point))
            return setDrawingPreview(
                CanvasElement(
                    id: context.proposedElementID,
                    geometry: .line(.init(start: result.point, end: result.point)),
                    style: context.strokeStyle
                ),
                guides: result.guides
            )
        case .freehand:
            activeDraftID = context.proposedElementID
            freehandPoints.removeAll(keepingCapacity: true)
            freehandPoints.append(point)
            freehandInkSamples = [CanvasInkSample(point: point, pressure: 1)]
            freehandPredictedSamples.removeAll(keepingCapacity: true)
            freehandUsesInk = false
            freehandPressureEnabled = context.inkConfiguration.pressureEnabled
            freehandWidthMode = context.inkConfiguration.widthMode
            freehandStyle = context.strokeStyle
            state = .awaitingFreehand(pointCount: 1)
            return [.requestPreview(.freehand(elementID: context.proposedElementID))]
        case .eraser:
            return beginErasing(at: point, context: context)
        case .select, .text:
            return []
        }
    }

    mutating func beginErasing(
        at point: CanvasPoint,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        guard finite(point), valid(context.viewport),
              context.documentRevision < UInt64.max - 2 else {
            return []
        }
        prepareEraserHitTester(for: context)
        let initialTarget = eraserHitTester.cachedHoverTarget(
            at: point,
            elements: context.elements,
            viewport: context.viewport,
            toleranceScreen: context.hitToleranceScreen
        )
        state = .awaitingErasure(
            start: point,
            targets: initialTarget.map { [$0] } ?? [],
            documentID: context.documentID,
            replacementGeneration: context.documentReplacementGeneration
        )
        return [.requestPreview(.erasing), .setEraserTarget(nil)]
    }

    mutating func reduceErasingInput(
        _ input: CanvasInput,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        switch input {
        case .pencilMoved(let point):
            return reduceEraserSamples([point], isUp: false, context: context)
        case .pencilUp(let point):
            return reduceEraserSamples([point], isUp: true, context: context)
        default:
            return []
        }
    }

    mutating func reduceEraserSamples(
        _ points: [CanvasPoint],
        isUp: Bool,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        guard case .erasing(
            let lastPoint,
            let existingTargets,
            let documentID,
            let replacementGeneration
        ) = state,
              let token = activePreviewToken else {
            return []
        }
        guard documentID == context.documentID,
              replacementGeneration == context.documentReplacementGeneration else {
            return abandonErasing()
        }

        var targets = existingTargets
        let validPoints = points.filter(finite)
        prepareEraserHitTester(for: context)
        let swept = eraserHitTester.cachedSweptTargets(
            along: [lastPoint] + validPoints,
            elements: context.elements,
            excluding: Set(existingTargets),
            viewport: context.viewport,
            toleranceScreen: context.hitToleranceScreen
        )
        targets.append(contentsOf: swept)
        let previous = validPoints.last ?? lastPoint

        var effects: [CanvasEffect] = []
        if targets != existingTargets {
            effects.append(.updatePreview(.erasedElementIDs(targets), token))
        }
        guard isUp else {
            state = .erasing(
                lastPoint: previous,
                targets: targets,
                documentID: documentID,
                replacementGeneration: replacementGeneration
            )
            return effects
        }

        state = .idle
        activePreviewToken = nil
        if targets.isEmpty {
            effects.append(.cancelPreview(token))
        } else {
            effects.append(.commitPreview(token))
        }
        effects.append(.setEraserTarget(nil))
        return effects
    }

    mutating func prepareEraserHitTester(for context: CanvasInteractionContext) {
        eraserHitTester.useDocument(
            id: context.documentID,
            replacementGeneration: context.documentReplacementGeneration
        )
    }

    mutating func abandonErasing() -> [CanvasEffect] {
        let effects = cancelPreviewEffects() + [.setEraserTarget(nil)]
        state = .idle
        activePreviewToken = nil
        return effects
    }

    func snapped(
        _ point: CanvasPoint,
        context: CanvasInteractionContext
    ) -> SnapResult {
        SnapEngine.snap(
            point: point,
            excluding: nil,
            elements: context.elements,
            viewport: context.viewport,
            configuration: context.snapConfiguration
        )
    }

    mutating func reduceLine(
        _ input: CanvasInput,
        id: UUID,
        start: CanvasPoint,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        guard let terminal = pencilTerminal(input), finite(terminal.point) else { return [] }
        let result = snapped(terminal.point, context: context)
        let element = CanvasElement(
            id: id,
            geometry: .line(.init(start: start, end: result.point)),
            style: context.strokeStyle
        )
        state = .drawing(.line(start: start, current: result.point))
        if terminal.isUp {
            return finishDrawing(element, context: context, guides: result.guides)
        }
        return setDrawingPreview(element, guides: result.guides)
    }

    mutating func reduceRectangle(
        _ input: CanvasInput,
        id: UUID,
        start: CanvasPoint,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        guard let terminal = pencilTerminal(input), finite(terminal.point) else { return [] }
        let result = snapped(terminal.point, context: context)
        let element = CanvasElement.rectangle(
            id: id,
            rect: normalizedRect(from: start, to: result.point),
            style: context.strokeStyle
        )
        state = .drawing(.rectangle(start: start, current: result.point))
        if terminal.isUp {
            return finishDrawing(element, context: context, guides: result.guides)
        }
        return setDrawingPreview(element, guides: result.guides)
    }

    mutating func reduceArchBase(
        _ input: CanvasInput,
        id: UUID,
        start: CanvasPoint,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        guard let terminal = pencilTerminal(input), finite(terminal.point) else { return [] }
        let result = snapped(terminal.point, context: context)
        let base = CanvasElement(
            id: id,
            geometry: .line(.init(start: start, end: result.point)),
            style: context.strokeStyle
        )
        guard terminal.isUp else {
            state = .drawing(.archBase(start: start, current: result.point))
            return setDrawingPreview(base, guides: result.guides)
        }
        guard start != result.point else {
            return abandonDrawing()
        }
        let midpoint = CanvasPoint(
            x: start.x + (result.point.x - start.x) / 2,
            y: start.y + (result.point.y - start.y) / 2
        )
        guard finite(midpoint) else { return abandonDrawing() }
        state = .drawing(.archSagitta(start: start, end: result.point, current: midpoint))
        archAwaitingSagittaStroke = true
        return setDrawingPreview(base, guides: result.guides)
    }

    mutating func reduceArchSagitta(
        _ input: CanvasInput,
        id: UUID,
        start: CanvasPoint,
        end: CanvasPoint,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        let point: CanvasPoint
        let isUp: Bool
        switch input {
        case .pencilDown(let value):
            archAwaitingSagittaStroke = false
            point = value
            isUp = false
        case .pencilMoved(let value):
            guard !archAwaitingSagittaStroke else { return [] }
            point = value
            isUp = false
        case .pencilUp(let value):
            guard !archAwaitingSagittaStroke else { return [] }
            point = value
            isUp = true
        default:
            return []
        }
        guard finite(point) else { return [] }
        let result = snapped(point, context: context)
        guard let sagitta = signedSagitta(start: start, end: end, point: result.point) else {
            return isUp ? abandonDrawing() : []
        }
        let element = CanvasElement(
            id: id,
            geometry: .arch(.init(start: start, end: end, sagitta: sagitta)),
            style: context.strokeStyle
        )
        state = .drawing(.archSagitta(start: start, end: end, current: result.point))
        if isUp {
            return finishDrawing(element, context: context, guides: result.guides)
        }
        guard validDrawingElement(element) else { return [] }
        return setDrawingPreview(element, guides: result.guides)
    }

    mutating func reduceFreehand(
        _ input: CanvasInput,
        id: UUID,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        let point: CanvasPoint
        let isUp: Bool
        switch input {
        case .pencilMoved(let value):
            point = value
            isUp = false
        case .pencilUp(let value):
            point = value
            isUp = true
        default:
            return []
        }
        return reduceFreehandSamples([point], isUp: isUp, id: id, context: context)
    }

    mutating func reduceFreehandSamples(
        _ points: [CanvasPoint],
        isUp: Bool,
        id: UUID,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        let validPoints = points.filter(finite)
        guard !validPoints.isEmpty, let token = activePreviewToken,
              let style = freehandStyle else { return [] }
        freehandPoints.append(contentsOf: validPoints)
        state = .drawing(.freehand(pointCount: freehandPoints.count))
        guard isUp else {
            return [.appendFreehandPreview(
                id: id,
                style: style,
                points: validPoints,
                token: token
            )]
        }
        let samples = freehandPoints
        guard (try? style.validate()) != nil,
              samples.contains(where: { $0 != samples[0] }) else {
            return abandonDrawing()
        }
        state = .idle
        activeDraftID = nil
        activePreviewToken = nil
        freehandPoints.removeAll(keepingCapacity: true)
        freehandInkSamples.removeAll(keepingCapacity: true)
        freehandPredictedSamples.removeAll(keepingCapacity: true)
        freehandUsesInk = false
        freehandStyle = nil
        transientPreview = nil
        guard context.recognitionEnabled else {
            return [
                .appendFreehandPreview(id: id, style: style, points: validPoints, token: token),
                .setGuides([]),
                .commitPreview(token),
            ]
        }
        let request = RecognitionRequest(
            fingerprint: .init(
                documentID: context.documentID,
                replacementGeneration: context.documentReplacementGeneration,
                elementID: id,
                contentRevision: 0
            ),
            points: samples,
            recognitionGeneration: recognitionGeneration
        )
        return [
            .appendFreehandPreview(id: id, style: style, points: validPoints, token: token),
            .setGuides([]),
            .commitPreview(token),
            .recognize(request),
        ]
    }

    mutating func reduceFreehandInkSamples(
        _ samples: [CanvasInkSample],
        predicted: [CanvasInkSample],
        isUp: Bool,
        id: UUID,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        let validSamples = samples.filter(validInkSample)
        guard !validSamples.isEmpty, let token = activePreviewToken,
              let style = freehandStyle else { return [] }
        freehandInkSamples.append(contentsOf: validSamples)
        freehandPoints.append(contentsOf: validSamples.map(\.point))
        freehandPredictedSamples = isUp ? [] : predicted.filter(validInkSample)
        state = .drawing(.freehand(pointCount: freehandInkSamples.count))

        let append = CanvasEffect.appendFreehandInkPreview(
            id: id,
            style: style,
            confirmed: validSamples,
            predicted: freehandPredictedSamples,
            pressureEnabled: freehandPressureEnabled,
            widthMode: freehandWidthMode,
            token: token
        )
        guard isUp else { return [append] }
        let confirmed = freehandInkSamples
        guard (try? style.validate()) != nil,
              confirmed.dropFirst().contains(where: { $0.point != confirmed[0].point }) else {
            return abandonDrawing()
        }
        state = .idle
        activeDraftID = nil
        activePreviewToken = nil
        freehandPoints.removeAll(keepingCapacity: true)
        freehandInkSamples.removeAll(keepingCapacity: true)
        freehandPredictedSamples.removeAll(keepingCapacity: true)
        freehandUsesInk = false
        freehandStyle = nil
        transientPreview = nil
        guard context.recognitionEnabled else {
            return [append, .setGuides([]), .commitPreview(token)]
        }
        let request = RecognitionRequest(
            fingerprint: .init(
                documentID: context.documentID,
                replacementGeneration: context.documentReplacementGeneration,
                elementID: id,
                contentRevision: 0
            ),
            inkSamples: confirmed,
            recognitionGeneration: recognitionGeneration
        )
        return [append, .setGuides([]), .commitPreview(token), .recognize(request)]
    }

    mutating func finishDrawing(
        _ element: CanvasElement,
        context: CanvasInteractionContext,
        guides: [SnapGuide]
    ) -> [CanvasEffect] {
        guard validDrawingElement(element) else { return abandonDrawing() }
        guard canInsert(id: element.id, context: context) else {
            return setDrawingPreview(element, guides: guides)
        }
        state = .idle
        activeDraftID = nil
        archAwaitingSagittaStroke = false
        transientPreview = nil
        return [
            .setTransientPreview(nil),
            .setGuides(guides),
            .perform(.insert(element, at: context.elements.endIndex)),
            .setGuides([]),
        ]
    }

    mutating func abandonDrawing() -> [CanvasEffect] {
        let effects = cancelPreviewEffects(includeTransientReset: true)
        state = .idle
        activePreviewToken = nil
        activeDraftID = nil
        archAwaitingSagittaStroke = false
        transientPreview = nil
        freehandPoints.removeAll(keepingCapacity: true)
        freehandInkSamples.removeAll(keepingCapacity: true)
        freehandPredictedSamples.removeAll(keepingCapacity: true)
        freehandUsesInk = false
        freehandStyle = nil
        return effects
    }

    mutating func setDrawingPreview(
        _ element: CanvasElement?,
        guides: [SnapGuide] = []
    ) -> [CanvasEffect] {
        transientPreview = element
        return [.setTransientPreview(element), .setGuides(guides)]
    }

    mutating func applyRecognition(
        request: RecognitionRequest,
        result: RecognitionResult?,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        guard context.recognitionEnabled, context.configuration.allows(.shapeRecognition),
              request.recognitionGeneration == recognitionGeneration,
              request.fingerprint.documentID == context.documentID,
              request.fingerprint.replacementGeneration == context.documentReplacementGeneration,
              context.documentRevision < UInt64.max - 2,
              let current = context.elements.first(where: { $0.id == request.elementID }),
              current.contentRevision == request.contentRevision,
              matchesFreehand(current.geometry, points: request.points),
              current.contentRevision < UInt64.max - 1,
              let result else {
            return []
        }
        var replacement = current
        replacement.geometry = result.geometry
        guard context.configuration.allows(CanvasTool.tool(for: result.geometry)),
              validRecognitionElement(replacement) else { return [] }
        return [.perform(.setGeometry(id: current.id, result.geometry))]
    }

    func canInsert(id: UUID, context: CanvasInteractionContext) -> Bool {
        context.documentRevision < UInt64.max - 2
            && !context.elements.contains(where: { $0.id == id })
    }

    mutating func beginManipulation(
        at point: CanvasPoint,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        guard context.configuration.allows(.select), finite(point), valid(context.viewport),
              context.documentRevision < UInt64.max - 2,
              let id = context.selectedElementID,
              let snapshot = context.elements.first(where: { $0.id == id }),
              snapshot.contentRevision < UInt64.max - 1,
              let hitTolerance = canvasDistance(
                screenDistance: context.hitToleranceScreen,
                viewport: context.viewport
              ),
              let handleTolerance = canvasDistance(
                screenDistance: context.resizeHandleToleranceScreen,
                viewport: context.viewport
              ) else {
            return []
        }

        let hitsElement = snapshot.geometry.hitTest(
            point,
            tolerance: hitTolerance,
            textBounds: snapshot.bounds
        )
        guard let manipulationHandle = executableManipulationHandle(
            for: snapshot,
            at: point,
            hitsElement: hitsElement,
            handleTolerance: handleTolerance,
            minimumSize: context.minimumElementSize
        ) else {
            return []
        }

        switch manipulationHandle {
        case .move:
            guard context.configuration.allows(.selectionMovement) else { return [] }
        case .resize, .lineEndpoint:
            guard context.configuration.allows(.selectionResizing) else { return [] }
        }

        let startScreen = context.viewport.screenPoint(fromCanvas: point)
        guard finite(startScreen) else { return [] }
        state = .awaitingManipulation(
            snapshot: snapshot,
            handle: manipulationHandle,
            startScreen: startScreen
        )
        manipulationStartViewport = context.viewport
        return [.requestPreview(.editing(elementID: snapshot.id))]
    }

    func moveEffects(
        snapshot: CanvasElement,
        canvasDelta: CanvasPoint,
        viewport: CanvasViewport,
        context: CanvasInteractionContext
    ) -> [CanvasEffect] {
        guard snapshot.contentRevision < UInt64.max - 1 else { return [] }
        guard let unsnapped = try? snapshot.moved(by: canvasDelta) else { return [] }
        guard unsnapped.bounds.isFinite else { return [] }
        let result = SnapEngine.snap(
            point: CanvasPoint(x: unsnapped.bounds.minX, y: unsnapped.bounds.minY),
            excluding: snapshot.id,
            elements: context.elements,
            viewport: viewport,
            configuration: context.snapConfiguration
        )
        let adjustment = CanvasPoint(
            x: result.point.x - unsnapped.bounds.minX,
            y: result.point.y - unsnapped.bounds.minY
        )
        guard finite(adjustment) else { return [] }
        let finalDelta = CanvasPoint(
            x: canvasDelta.x + adjustment.x,
            y: canvasDelta.y + adjustment.y
        )
        guard finite(finalDelta) else { return [] }
        guard let moved = try? snapshot.moved(by: finalDelta) else { return [] }
        guard moved.bounds.isFinite else { return [] }
        guard let token = activePreviewToken else { return [] }
        return [.updatePreview(.element(moved), token), .setGuides(result.guides)]
    }

    func lineEndpointEffects(
        snapshot: CanvasElement,
        endpoint: CanvasLineEndpoint,
        canvasDelta: CanvasPoint
    ) -> [CanvasEffect] {
        guard snapshot.contentRevision < UInt64.max - 1,
              case .line(var line) = snapshot.geometry else {
            return []
        }

        let source = endpoint == .first ? line.start : line.end
        let destination = CanvasPoint(
            x: source.x + canvasDelta.x,
            y: source.y + canvasDelta.y
        )
        guard finite(destination) else { return [] }
        switch endpoint {
        case .first:
            line.start = destination
        case .second:
            line.end = destination
        }

        var element = snapshot
        element.geometry = .line(line)
        element.contentRevision += 1
        guard element.bounds.isFinite else { return [] }
        guard let token = activePreviewToken else { return [] }
        return [.updatePreview(.element(element), token), .setGuides([])]
    }

    mutating func changeTool(to tool: CanvasTool) -> [CanvasEffect] {
        // CanvasSession remains the host source of truth. Repeated notifications of its current
        // value must not look like a user switch and cancel an in-flight reducer draft.
        guard tool != activeTool else { return [] }
        let effects: [CanvasEffect]
        switch state {
        case .drawing, .awaitingFreehand:
            effects = cancelPreviewEffects(includeTransientReset: true)
        case .manipulating, .erasing:
            effects = cancelPreviewEffects()
        case .awaitingErasure:
            effects = [.setGuides([])]
        case .awaitingManipulation:
            effects = [.setGuides([])]
        case .idle, .panning, .pinching:
            effects = [.setGuides([])]
        }
        activeTool = tool
        state = .idle
        manipulationStartViewport = nil
        activePreviewToken = nil
        activeDraftID = nil
        archAwaitingSagittaStroke = false
        freehandPoints.removeAll(keepingCapacity: true)
        freehandInkSamples.removeAll(keepingCapacity: true)
        freehandPredictedSamples.removeAll(keepingCapacity: true)
        freehandUsesInk = false
        freehandStyle = nil
        transientPreview = nil
        invalidateRecognition()
        return effects + [.setEraserTarget(nil)]
    }

    mutating func cancelActiveInteraction() -> [CanvasEffect] {
        let effects = cancelPreviewEffects(includeTransientReset: true)
        state = .idle
        manipulationStartViewport = nil
        activePreviewToken = nil
        activeDraftID = nil
        archAwaitingSagittaStroke = false
        freehandPoints.removeAll(keepingCapacity: true)
        freehandInkSamples.removeAll(keepingCapacity: true)
        freehandPredictedSamples.removeAll(keepingCapacity: true)
        freehandUsesInk = false
        freehandStyle = nil
        transientPreview = nil
        invalidateRecognition()
        return effects + [.setEraserTarget(nil)]
    }

    mutating func acceptPreview(_ token: CanvasPreviewToken) -> [CanvasEffect] {
        switch state {
        case .awaitingManipulation(let snapshot, let handle, let startScreen):
            activePreviewToken = token
            state = .manipulating(snapshot: snapshot, handle: handle, startScreen: startScreen)
            return []
        case .awaitingFreehand(let pointCount):
            guard let id = activeDraftID, let style = freehandStyle,
                  !freehandPoints.isEmpty else {
                return [.cancelPreview(token)]
            }
            activePreviewToken = token
            state = .drawing(.freehand(pointCount: pointCount))
            if freehandUsesInk {
                return [.appendFreehandInkPreview(
                    id: id,
                    style: style,
                    confirmed: freehandInkSamples,
                    predicted: freehandPredictedSamples,
                    pressureEnabled: freehandPressureEnabled,
                    widthMode: freehandWidthMode,
                    token: token
                )]
            }
            return [.appendFreehandPreview(
                id: id,
                style: style,
                points: freehandPoints,
                token: token
            )]
        case .awaitingErasure(
            let start,
            let targets,
            let documentID,
            let replacementGeneration
        ):
            activePreviewToken = token
            state = .erasing(
                lastPoint: start,
                targets: targets,
                documentID: documentID,
                replacementGeneration: replacementGeneration
            )
            return targets.isEmpty
                ? []
                : [.updatePreview(.erasedElementIDs(targets), token)]
        default:
            return [.cancelPreview(token)]
        }
    }

    mutating func rejectPreview() -> [CanvasEffect] {
        switch state {
        case .awaitingManipulation, .manipulating, .awaitingFreehand,
             .awaitingErasure, .erasing:
            break
        default:
            return []
        }
        state = .idle
        manipulationStartViewport = nil
        activePreviewToken = nil
        activeDraftID = nil
        freehandPoints.removeAll(keepingCapacity: true)
        freehandInkSamples.removeAll(keepingCapacity: true)
        freehandPredictedSamples.removeAll(keepingCapacity: true)
        freehandUsesInk = false
        freehandStyle = nil
        return [.setGuides([]), .setEraserTarget(nil)]
    }

    func cancelPreviewEffects(includeTransientReset: Bool = false) -> [CanvasEffect] {
        var effects: [CanvasEffect] = includeTransientReset ? [.setTransientPreview(nil)] : []
        if let activePreviewToken {
            effects.append(.cancelPreview(activePreviewToken))
        }
        effects.append(.setGuides([]))
        return effects
    }

    mutating func invalidateRecognition() {
        recognitionGeneration.advance()
    }
}

private func finite(_ point: CanvasPoint) -> Bool {
    point.x.isFinite && point.y.isFinite
}

private func validInkSample(_ sample: CanvasInkSample) -> Bool {
    finite(sample.point) && sample.pressure.isFinite && (0 ... 1).contains(sample.pressure)
}

private struct PencilTerminal {
    let point: CanvasPoint
    let isUp: Bool
}

private func pencilTerminal(_ input: CanvasInput) -> PencilTerminal? {
    switch input {
    case .pencilMoved(let point): PencilTerminal(point: point, isUp: false)
    case .pencilUp(let point): PencilTerminal(point: point, isUp: true)
    default: nil
    }
}

private func normalizedRect(from start: CanvasPoint, to end: CanvasPoint) -> CanvasRect {
    CanvasRect(
        x: min(start.x, end.x),
        y: min(start.y, end.y),
        width: abs(end.x - start.x),
        height: abs(end.y - start.y)
    )
}

private func matchesFreehand(_ geometry: CanvasGeometry, points: [CanvasPoint]) -> Bool {
    guard case .freehand(let stroke) = geometry else { return false }
    return stroke.points == points
}

private func signedSagitta(
    start: CanvasPoint,
    end: CanvasPoint,
    point: CanvasPoint
) -> Double? {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let chordLength = hypot(dx, dy)
    guard dx.isFinite, dy.isFinite, chordLength.isFinite, chordLength > 0 else { return nil }
    let midpoint = CanvasPoint(x: start.x + dx / 2, y: start.y + dy / 2)
    let offsetX = point.x - midpoint.x
    let offsetY = point.y - midpoint.y
    let sagitta = offsetX * (-dy / chordLength) + offsetY * (dx / chordLength)
    guard finite(midpoint), offsetX.isFinite, offsetY.isFinite,
          sagitta.isFinite, sagitta != 0 else {
        return nil
    }
    return sagitta
}

private func validDrawingElement(_ element: CanvasElement) -> Bool {
    guard element.bounds.isFinite, !element.geometry.renderPath.commands.isEmpty,
          (try? CanvasDocument(elements: [element]).validate()) != nil else {
        return false
    }
    switch element.geometry {
    case .line(let line):
        return line.start != line.end
    case .rectangle(let rectangle):
        return rectangle.rect.width > 0 && rectangle.rect.height > 0
    case .arch(let arch):
        return (try? ArchGeometry.parameters(for: arch)) != nil
            && !element.geometry.renderPath.commands.isEmpty
    case .freehand(let stroke):
        return inkHasDrawableSegment(stroke)
    case .text:
        return false
    }
}

private func validRecognitionElement(_ element: CanvasElement) -> Bool {
    guard element.bounds.isFinite,
          !element.geometry.renderPath.commands.isEmpty,
          (try? CanvasDocument(elements: [element]).validate()) != nil else {
        return false
    }
    switch element.geometry {
    case .line(let line):
        return line.start != line.end
    case .rectangle(let rectangle):
        return rectangle.rect.width > 0 && rectangle.rect.height > 0
    case .freehand(let stroke):
        return inkHasDrawableSegment(stroke)
    case .arch(let arch):
        return (try? ArchGeometry.parameters(for: arch)) != nil
            && !element.geometry.renderPath.commands.isEmpty
    case .text:
        return false
    }
}

private func pathHasDrawableSegment(_ path: CanvasPath) -> Bool {
    var current: CanvasPoint?
    var subpathStart: CanvasPoint?
    for command in path.commands {
        switch command {
        case .move(let point):
            current = point
            subpathStart = point
        case .line(let end):
            if let current, end != current { return true }
            current = end
        case .quad(let control, let end):
            if let current, control != current || end != current { return true }
            current = end
        case .cubic(let control1, let control2, let end):
            if let current,
               control1 != current || control2 != current || end != current {
                return true
            }
            current = end
        case .close:
            if let current, let subpathStart, current != subpathStart { return true }
            current = subpathStart
        }
    }
    return false
}

private func inkHasDrawableSegment(_ stroke: CanvasInkStroke) -> Bool {
    guard let first = stroke.samples.first?.point else { return false }
    return stroke.samples.dropFirst().contains { $0.point != first }
}

private func valid(_ viewport: CanvasViewport) -> Bool {
    viewport.isValid
}

private func canvasDistance(
    screenDistance: Double,
    viewport: CanvasViewport
) -> Double? {
    guard screenDistance.isFinite, screenDistance >= 0, valid(viewport) else { return nil }
    let distance = screenDistance / viewport.zoom
    return distance.isFinite ? distance : nil
}

@MainActor
private func executableManipulationHandle(
    for element: CanvasElement,
    at point: CanvasPoint,
    hitsElement: Bool,
    handleTolerance: Double,
    minimumSize: Double
) -> CanvasManipulationHandle? {
    switch element.geometry {
    case .line(let line):
        if line.start == line.end {
            return hitsElement ? .move : nil
        }
        let firstDistance = point.distance(to: line.start)
        let secondDistance = point.distance(to: line.end)
        let firstIsHandle = firstDistance.isFinite && firstDistance <= handleTolerance
        let secondIsHandle = secondDistance.isFinite && secondDistance <= handleTolerance
        switch (firstIsHandle, secondIsHandle) {
        case (true, true):
            return .lineEndpoint(firstDistance <= secondDistance ? .first : .second)
        case (true, false):
            return .lineEndpoint(.first)
        case (false, true):
            return .lineEndpoint(.second)
        case (false, false):
            return hitsElement ? .move : nil
        }

    case .text:
        return executableBoundsHandle(
            for: element,
            at: point,
            hitsElement: hitsElement,
            handleTolerance: handleTolerance,
            minimumSize: minimumSize
        )

    case .arch(let arch):
        if archSupportsBoundsResize(arch, minimumSize: minimumSize) {
            return executableBoundsHandle(
                for: element,
                at: point,
                hitsElement: hitsElement,
                handleTolerance: handleTolerance,
                minimumSize: minimumSize
            )
        }
        return hitsElement ? .move : nil

    case .freehand:
        let bounds = element.bounds
        if !bounds.width.isNormal || !bounds.height.isNormal {
            return hitsElement ? .move : nil
        }
        return executableBoundsHandle(
            for: element,
            at: point,
            hitsElement: hitsElement,
            handleTolerance: handleTolerance,
            minimumSize: minimumSize
        )

    case .rectangle:
        return executableBoundsHandle(
            for: element,
            at: point,
            hitsElement: hitsElement,
            handleTolerance: handleTolerance,
            minimumSize: minimumSize
        )
    }
}

private func archSupportsBoundsResize(_ arch: CanvasArch, minimumSize: Double) -> Bool {
    let dx = arch.end.x - arch.start.x
    let dy = arch.end.y - arch.start.y
    guard minimumSize.isNormal, minimumSize > 0, dx == 0 || dy == 0 else { return false }
    let chordLength = hypot(dx, dy)
    return chordLength.isFinite
        && chordLength > 0
        && arch.sagitta.isFinite
        && abs(arch.sagitta) < chordLength / 2
}

@MainActor
private func executableBoundsHandle(
    for element: CanvasElement,
    at point: CanvasPoint,
    hitsElement: Bool,
    handleTolerance: Double,
    minimumSize: Double
) -> CanvasManipulationHandle? {
    if hitsElement,
       isInteriorMovePoint(point, bounds: element.bounds, handleTolerance: handleTolerance) {
        return .move
    }
    if let handle = resizeHandle(
        at: point,
        bounds: element.bounds,
        tolerance: handleTolerance
    ), resizeIsExecutable(
        element,
        handle: handle,
        minimumSize: minimumSize
    ) {
        return .resize(handle)
    }
    return hitsElement ? .move : nil
}

@MainActor
private func resizeIsExecutable(
    _ element: CanvasElement,
    handle: ResizeHandle,
    minimumSize: Double
) -> Bool {
    do {
        let candidate = try executableResize(
            original: element,
            handle: handle,
            cumulativeDelta: .init(x: 0, y: 0),
            minimumSize: minimumSize
        )
        return candidate.bounds.isFinite
    } catch {
        return false
    }
}

@MainActor
private func executableResize(
    original: CanvasElement,
    handle: ResizeHandle,
    cumulativeDelta: CanvasPoint,
    minimumSize: Double
) throws -> CanvasElement {
    if case .text(let text) = original.geometry {
        return try resizedText(
            original: original,
            text: text,
            handle: handle,
            cumulativeDelta: cumulativeDelta,
            minimumSize: minimumSize
        )
    }
    var bounds = ResizeEngine.resizedBounds(
        original: original.bounds,
        handle: handle,
        cumulativeDelta: cumulativeDelta,
        minimumSize: minimumSize
    )
    if case .arch(let arch) = original.geometry,
       archSupportsBoundsResize(arch, minimumSize: minimumSize) {
        bounds = clampedArchResizeBounds(
            bounds,
            originalBounds: original.bounds,
            arch: arch,
            handle: handle
        )
    }
    return try original.replacingBounds(bounds)
}

@MainActor
private func resizedText(
    original: CanvasElement,
    text: CanvasText,
    handle: ResizeHandle,
    cumulativeDelta: CanvasPoint,
    minimumSize: Double
) throws -> CanvasElement {
    let minimumWidth = minimumSize.isFinite ? max(0, minimumSize) : 0
    let width: Double
    let x: Double
    switch handle {
    case .topLeft, .left, .bottomLeft:
        width = max(minimumWidth, text.frame.width - cumulativeDelta.x)
        x = text.frame.maxX - width
    case .topRight, .right, .bottomRight:
        width = max(minimumWidth, text.frame.width + cumulativeDelta.x)
        x = text.frame.minX
    case .top, .bottom:
        throw CanvasGeometryError.unsupportedResize(.text)
    }
    guard let frame = CanvasTextLayoutEngine().measure(
        text: text.text,
        font: text.font,
        origin: .init(x: x, y: text.frame.y),
        width: width
    ) else {
        throw CanvasGeometryError.invalidBounds
    }
    return CanvasElement(
        id: original.id,
        contentRevision: original.contentRevision,
        geometry: .text(.init(frame: frame, text: text.text, font: text.font, color: text.color)),
        style: original.style
    )
}

private func clampedArchResizeBounds(
    _ bounds: CanvasRect,
    originalBounds: CanvasRect,
    arch: CanvasArch,
    handle: ResizeHandle
) -> CanvasRect {
    var clamped = bounds
    if arch.start.y == arch.end.y {
        let maximumBulge = bounds.width / 2
        guard bounds.height > maximumBulge else { return bounds }
        switch handle {
        case .topLeft, .top, .topRight:
            clamped.y = bounds.maxY - maximumBulge
        case .bottomLeft, .bottom, .bottomRight:
            break
        case .left, .right:
            if arch.start.y == originalBounds.maxY {
                clamped.y = bounds.maxY - maximumBulge
            }
        }
        clamped.height = maximumBulge
    } else {
        let maximumBulge = bounds.height / 2
        guard bounds.width > maximumBulge else { return bounds }
        switch handle {
        case .topLeft, .left, .bottomLeft:
            clamped.x = bounds.maxX - maximumBulge
        case .topRight, .right, .bottomRight:
            break
        case .top, .bottom:
            if arch.start.x == originalBounds.maxX {
                clamped.x = bounds.maxX - maximumBulge
            }
        }
        clamped.width = maximumBulge
    }
    return clamped
}

private func resizeHandle(
    at point: CanvasPoint,
    bounds: CanvasRect,
    tolerance: Double
) -> ResizeHandle? {
    guard bounds.isFinite, bounds.width >= 0, bounds.height >= 0,
          tolerance.isFinite, tolerance >= 0 else {
        return nil
    }
    let middleX = bounds.minX + bounds.width / 2
    let middleY = bounds.minY + bounds.height / 2
    let candidates: [(ResizeHandle, CanvasPoint)] = [
        (.topLeft, .init(x: bounds.minX, y: bounds.minY)),
        (.top, .init(x: middleX, y: bounds.minY)),
        (.topRight, .init(x: bounds.maxX, y: bounds.minY)),
        (.right, .init(x: bounds.maxX, y: middleY)),
        (.bottomRight, .init(x: bounds.maxX, y: bounds.maxY)),
        (.bottom, .init(x: middleX, y: bounds.maxY)),
        (.bottomLeft, .init(x: bounds.minX, y: bounds.maxY)),
        (.left, .init(x: bounds.minX, y: middleY)),
    ]

    return candidates
        .map { ($0.0, point.distance(to: $0.1)) }
        .filter { $0.1.isFinite && $0.1 <= tolerance }
        .min { lhs, rhs in lhs.1 < rhs.1 }?
        .0
}

private func isInteriorMovePoint(
    _ point: CanvasPoint,
    bounds: CanvasRect,
    handleTolerance: Double
) -> Bool {
    guard bounds.isFinite, bounds.width >= 0, bounds.height >= 0,
          handleTolerance.isFinite, handleTolerance >= 0 else {
        return false
    }

    if bounds.height == 0, bounds.width > 0 {
        let inset = min(handleTolerance, bounds.width / 4)
        return point.x > bounds.minX + inset && point.x < bounds.maxX - inset
    }
    if bounds.width == 0, bounds.height > 0 {
        let inset = min(handleTolerance, bounds.height / 4)
        return point.y > bounds.minY + inset && point.y < bounds.maxY - inset
    }
    let inset = min(handleTolerance, min(bounds.width, bounds.height) / 4)
    return point.x > bounds.minX + inset
        && point.x < bounds.maxX - inset
        && point.y > bounds.minY + inset
        && point.y < bounds.maxY - inset
}
