import Foundation

public enum DimensionEngineError: Error, Equatable, Sendable {
    case dimensionNotEditable
    case invalidMeasurement
    case invalidCalibration
    case measurementOverflow
    case elementNotFound(UUID)
    case staleDimension
}

public enum DimensionEngine {
    public static func compute(
        document: CanvasDocument,
        viewport: CanvasViewport
    ) -> DimensionLayout {
        project(structure: computeStructure(document: document), viewport: viewport)
    }

    public static func computeStructure(document: CanvasDocument) -> CanvasDimensionStructure {
        computeStructure(document: document) { $0.bounds }
    }

    package static func computeStructure(
        document: CanvasDocument,
        boundsForElement: (CanvasElement) -> CanvasRect
    ) -> CanvasDimensionStructure {
        let calibration = document.calibration.millimetersPerPoint
        guard calibration.isFinite, calibration > 0 else {
            return CanvasDimensionStructure(horizontal: [], vertical: [])
        }

        let elements = document.elements.compactMap { element -> BoundedElement? in
            let bounds = boundsForElement(element)
            guard valid(bounds: bounds) else {
                return nil
            }
            return BoundedElement(element: element, bounds: bounds)
        }

        return CanvasDimensionStructure(
            horizontal: computeStructure(
                axis: .horizontal,
                elements: elements,
                millimetersPerPoint: calibration
            ),
            vertical: computeStructure(
                axis: .vertical,
                elements: elements,
                millimetersPerPoint: calibration
            )
        )
    }

    public static func project(
        structure: CanvasDimensionStructure,
        viewport: CanvasViewport
    ) -> DimensionLayout {
        DimensionLayout(
            horizontal: structure.horizontal.compactMap { project($0, viewport: viewport) },
            vertical: structure.vertical.compactMap { project($0, viewport: viewport) }
        )
    }

    public static func resizeCommand(
        for dimension: ProjectedDimension,
        newMillimeters: Double,
        in document: CanvasDocument
    ) throws -> CanvasCommand {
        guard newMillimeters.isFinite, newMillimeters > 0 else {
            throw DimensionEngineError.invalidMeasurement
        }

        let calibration = document.calibration.millimetersPerPoint
        guard calibration.isFinite, calibration > 0 else {
            throw DimensionEngineError.invalidCalibration
        }

        let key = dimension.key
        guard key.role == .element, key.elementIDs.count == 1 else {
            throw DimensionEngineError.dimensionNotEditable
        }

        let id = key.elementIDs[0]
        guard let element = document.elements.first(where: { $0.id == id }) else {
            throw DimensionEngineError.elementNotFound(id)
        }

        let bounds = element.bounds
        guard valid(bounds: bounds) else {
            throw DimensionEngineError.staleDimension
        }

        let currentEdges = edges(of: bounds, for: key.axis)
        let currentKey = DimensionKey(
            axis: key.axis,
            role: .element,
            elementIDs: [id],
            startEdge: currentEdges.start,
            endEdge: currentEdges.end
        )
        guard currentKey.startEdge == key.startEdge, currentKey.endEdge == key.endEdge else {
            throw DimensionEngineError.staleDimension
        }

        let currentStructure = computeStructure(document: document)
        guard currentStructure.all.contains(where: { $0.isEditable && $0.key == key }) else {
            throw DimensionEngineError.dimensionNotEditable
        }

        let canvasLength = newMillimeters / calibration
        guard canvasLength.isFinite, canvasLength > 0 else {
            throw DimensionEngineError.measurementOverflow
        }

        let anchoredEnd = currentEdges.start + canvasLength
        guard anchoredEnd.isFinite else {
            throw DimensionEngineError.measurementOverflow
        }

        let currentLength = currentEdges.end - currentEdges.start
        let delta = canvasLength - currentLength
        guard currentLength.isFinite, delta.isFinite else {
            throw DimensionEngineError.measurementOverflow
        }

        var replacement: CanvasElement
        do {
            switch key.axis {
            case .horizontal:
                replacement = try ResizeEngine.resize(
                    original: element,
                    handle: .right,
                    cumulativeDelta: .init(x: delta, y: 0),
                    minimumSize: 0
                )
            case .vertical:
                replacement = try ResizeEngine.resize(
                    original: element,
                    handle: .bottom,
                    cumulativeDelta: .init(x: 0, y: delta),
                    minimumSize: 0
                )
            }
        } catch {
            throw DimensionEngineError.dimensionNotEditable
        }

        let replacementLength: Double
        switch key.axis {
        case .horizontal:
            replacementLength = replacement.bounds.width
        case .vertical:
            replacementLength = replacement.bounds.height
        }
        if replacementLength != canvasLength {
            let exactBounds: CanvasRect
            switch key.axis {
            case .horizontal:
                exactBounds = CanvasRect(
                    x: bounds.x,
                    y: bounds.y,
                    width: canvasLength,
                    height: bounds.height
                )
            case .vertical:
                exactBounds = CanvasRect(
                    x: bounds.x,
                    y: bounds.y,
                    width: bounds.width,
                    height: canvasLength
                )
            }
            do {
                replacement = try element.replacingBounds(exactBounds)
            } catch {
                throw DimensionEngineError.dimensionNotEditable
            }
        }

        guard valid(bounds: replacement.bounds) else {
            throw DimensionEngineError.measurementOverflow
        }
        return .setGeometry(id: id, replacement.geometry)
    }

    private static func computeStructure(
        axis: DimensionAxis,
        elements: [BoundedElement],
        millimetersPerPoint: Double
    ) -> [CanvasDimensionSpan] {
        var extensionCoordinates: [Double: Double] = [:]
        var startingIDs: [Double: [UUID]] = [:]
        var endingIDs: [Double: [UUID]] = [:]
        let intervals: [AxisInterval] = elements.compactMap { element in
            let axisEdges = Self.edges(of: element.bounds, for: axis)
            let length = axisEdges.end - axisEdges.start
            guard length.isFinite, length > 0 else {
                return nil
            }
            let perpendicular = axis == .horizontal ? element.bounds.maxY : element.bounds.maxX
            for edge in [axisEdges.start, axisEdges.end] {
                extensionCoordinates[edge] = max(extensionCoordinates[edge] ?? perpendicular, perpendicular)
            }
            startingIDs[axisEdges.start, default: []].append(element.element.id)
            endingIDs[axisEdges.end, default: []].append(element.element.id)
            return AxisInterval(
                id: element.element.id,
                start: axisEdges.start,
                end: axisEdges.end,
                isEditable: supportsResize(element, axis: axis)
            )
        }
        let ordered = intervals.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.id.uuidString < $1.id.uuidString
        }
        var spans: [AxisSpan] = []
        for interval in ordered {
            if let last = spans.last, last.start == interval.start, last.end == interval.end {
                spans[spans.count - 1].elementIDs.append(interval.id)
                spans[spans.count - 1].role = .merged
            } else {
                spans.append(AxisSpan(
                    start: interval.start, end: interval.end,
                    role: .element, elementIDs: [interval.id]
                ))
            }
        }
        // Keep individual spans; unions are additional chain rows, not replacements.
        let groups = mergeCoveredSpans(spans)
        for (left, right) in zip(groups, groups.dropFirst()) {
            spans.append(AxisSpan(
                start: left.end, end: right.start, role: .gap,
                elementIDs: (endingIDs[left.end] ?? []) + (startingIDs[right.start] ?? [])
            ))
        }
        spans.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        var ranges = Set(spans.map { $0.start...$0.end })
        if groups.count > 1 {
            for group in groups where ranges.insert(group.start...group.end).inserted {
                spans.append(group)
            }
        }
        let editableElementIDs = Set(intervals.filter(\.isEditable).map(\.id))
        var dimensions = spans.compactMap {
            dimensionSpan(
                axis: axis,
                span: $0,
                editableElementIDs: editableElementIDs,
                millimetersPerPoint: millimetersPerPoint,
                extensionCoordinates: extensionCoordinates
            )
        }

        let distinctIDs = Set(intervals.map { $0.id })
        if distinctIDs.count >= 2,
           let overallStart = intervals.map({ $0.start }).min(),
           let overallEnd = intervals.map({ $0.end }).max(),
           !ranges.contains(overallStart...overallEnd),
           let overall = dimensionSpan(
               axis: axis,
               span: AxisSpan(
                   start: overallStart,
                   end: overallEnd,
                   role: .overall,
                   elementIDs: Array(distinctIDs)
               ),
               editableElementIDs: editableElementIDs,
               millimetersPerPoint: millimetersPerPoint,
               extensionCoordinates: extensionCoordinates
           ) {
            dimensions.append(overall)
        }

        return dimensions
    }

    private static func mergeCoveredSpans(_ spans: [AxisSpan]) -> [AxisSpan] {
        guard var current = spans.first else {
            return []
        }

        var result: [AxisSpan] = []
        for next in spans.dropFirst() {
            if next.start <= current.end {
                current.end = max(current.end, next.end)
                current.role = .merged
                current.elementIDs.append(contentsOf: next.elementIDs)
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    private static func dimensionSpan(
        axis: DimensionAxis,
        span: AxisSpan,
        editableElementIDs: Set<UUID>,
        millimetersPerPoint: Double,
        extensionCoordinates: [Double: Double]
    ) -> CanvasDimensionSpan? {
        let canvasLength = span.end - span.start
        let millimeters = canvasLength * millimetersPerPoint
        guard canvasLength.isFinite,
              canvasLength > 0,
              millimeters.isFinite,
              millimeters > 0 else {
            return nil
        }

        let canvasStart: CanvasPoint
        let canvasEnd: CanvasPoint
        switch axis {
        case .horizontal:
            canvasStart = CanvasPoint(x: span.start, y: 0)
            canvasEnd = CanvasPoint(x: span.end, y: 0)
        case .vertical:
            canvasStart = CanvasPoint(x: 0, y: span.start)
            canvasEnd = CanvasPoint(x: 0, y: span.end)
        }

        let key = DimensionKey(
            axis: axis,
            role: span.role,
            elementIDs: span.elementIDs,
            startEdge: span.start,
            endEdge: span.end
        )
        return CanvasDimensionSpan(
            key: key,
            canvasStart: canvasStart,
            canvasEnd: canvasEnd,
            millimeters: millimeters,
            isEditable: span.role == .element
                && key.elementIDs.count == 1
                && editableElementIDs.contains(key.elementIDs[0]),
            extensionStart: extensionOrigin(at: span.start, axis: axis, coordinates: extensionCoordinates),
            extensionEnd: extensionOrigin(at: span.end, axis: axis, coordinates: extensionCoordinates)
        )
    }

    private static func extensionOrigin(
        at edge: Double,
        axis: DimensionAxis,
        coordinates: [Double: Double]
    ) -> CanvasPoint? {
        guard let perpendicular = coordinates[edge] else { return nil }
        return axis == .horizontal
            ? .init(x: edge, y: perpendicular)
            : .init(x: perpendicular, y: edge)
    }

    private static func project(
        _ span: CanvasDimensionSpan,
        viewport: CanvasViewport
    ) -> ProjectedDimension? {
        let screenStart = viewport.screenPoint(fromCanvas: span.canvasStart)
        let screenEnd = viewport.screenPoint(fromCanvas: span.canvasEnd)
        guard finite(screenStart), finite(screenEnd) else { return nil }
        return ProjectedDimension(
            key: span.key,
            canvasLength: span.canvasLength,
            millimeters: span.millimeters,
            screenStart: screenStart,
            screenEnd: screenEnd,
            isEditable: span.isEditable
        )
    }

    private static func supportsResize(
        _ element: BoundedElement,
        axis: DimensionAxis
    ) -> Bool {
        let bounds = element.bounds
        guard valid(bounds: bounds), geometrySupportsAxisResize(element.element.geometry) else {
            return false
        }

        let axisEdges = edges(of: bounds, for: axis)
        let length = axisEdges.end - axisEdges.start
        return length.isFinite && length > 0
    }

    private static func geometrySupportsAxisResize(_ geometry: CanvasGeometry) -> Bool {
        switch geometry {
        case .text:
            return false
        case .arch(let arch):
            let dx = arch.end.x - arch.start.x
            let dy = arch.end.y - arch.start.y
            return arch.sagitta.isFinite
                && arch.sagitta != 0
                && dx.isFinite
                && dy.isFinite
                && (dx != 0 || dy != 0)
                && (dx == 0 || dy == 0)
        case .line, .rectangle, .freehand:
            return true
        }
    }

    private static func edges(
        of bounds: CanvasRect,
        for axis: DimensionAxis
    ) -> (start: Double, end: Double) {
        switch axis {
        case .horizontal:
            (bounds.minX, bounds.maxX)
        case .vertical:
            (bounds.minY, bounds.maxY)
        }
    }

    private static func valid(bounds: CanvasRect) -> Bool {
        bounds.x.isFinite
            && bounds.y.isFinite
            && bounds.width.isFinite
            && bounds.height.isFinite
            && bounds.width >= 0
            && bounds.height >= 0
            && bounds.maxX.isFinite
            && bounds.maxY.isFinite
    }

    private static func finite(_ point: CanvasPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }
}

private struct BoundedElement {
    var element: CanvasElement
    var bounds: CanvasRect
}

private struct AxisInterval {
    var id: UUID
    var start: Double
    var end: Double
    var isEditable: Bool
}

private struct AxisSpan {
    var start: Double
    var end: Double
    var role: DimensionRole
    var elementIDs: [UUID]
}
