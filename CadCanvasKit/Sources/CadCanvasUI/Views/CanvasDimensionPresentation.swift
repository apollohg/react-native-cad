import Foundation
import UIKit
import CadCanvasCore

package struct PresentedDimension: Identifiable, Sendable {
    package let id: DimensionKey
    package let dimension: CanvasDimensionSpan
    package let clippedStart: CanvasPoint
    package let clippedEnd: CanvasPoint
    package let labelPosition: CanvasPoint?
    package let labelText: String
    package let labelSize: CanvasSize
    package let showsStartTick: Bool
    package let showsEndTick: Bool
    package let extensionLines: [CanvasDimensionLine]

    package var labelFrame: CanvasRect? {
        guard let labelPosition else { return nil }
        return .init(
            x: labelPosition.x - labelSize.width / 2,
            y: labelPosition.y - labelSize.height / 2,
            width: labelSize.width, height: labelSize.height
        )
    }

    package var dimensionLines: [CanvasDimensionLine] {
        guard let frame = labelFrame else {
            return [.init(start: clippedStart, end: clippedEnd)]
        }
        let labelCrossesLine = id.axis == .horizontal
            ? frame.minY <= clippedStart.y && frame.maxY >= clippedStart.y
            : frame.minX <= clippedStart.x && frame.maxX >= clippedStart.x
        guard labelCrossesLine else { return [.init(start: clippedStart, end: clippedEnd)] }
        if id.axis == .horizontal {
            return [
                CanvasDimensionLine(start: clippedStart, end: .init(x: min(clippedEnd.x, max(clippedStart.x, frame.minX)), y: clippedStart.y)),
                CanvasDimensionLine(start: .init(x: max(clippedStart.x, min(clippedEnd.x, frame.maxX)), y: clippedEnd.y), end: clippedEnd),
            ].filter { $0.start != $0.end }
        }
        return [
            CanvasDimensionLine(start: clippedStart, end: .init(x: clippedStart.x, y: min(clippedEnd.y, max(clippedStart.y, frame.minY)))),
            CanvasDimensionLine(start: .init(x: clippedEnd.x, y: max(clippedStart.y, min(clippedEnd.y, frame.maxY))), end: clippedEnd),
        ].filter { $0.start != $0.end }
    }

    package var projectedDimension: ProjectedDimension {
        ProjectedDimension(
            key: dimension.key,
            canvasLength: dimension.canvasLength,
            millimeters: dimension.millimeters,
            screenStart: clippedStart,
            screenEnd: clippedEnd,
            isEditable: dimension.isEditable
        )
    }
}

package struct CanvasDimensionLine: Equatable, Sendable {
    package let start: CanvasPoint
    package let end: CanvasPoint
}

package struct CanvasDimensionPresentationMetrics: Equatable, Sendable {
    package fileprivate(set) var structureBuildCount = 0
    package fileprivate(set) var elementBoundsBuildCount = 0
}

package struct DimensionStructureKey: Hashable, Sendable {
    let documentID: UUID
    let documentRevision: UInt64
    let replacementGeneration: CanvasGeneration
    let previewRevision: CanvasGeneration
    let calibration: CanvasCalibration
}

@MainActor
package final class CanvasDimensionPresenter {
    private struct BoundsCacheScope: Equatable {
        let documentID: UUID
        let replacementGeneration: CanvasGeneration
    }

    private enum ElementBoundsIdentity: Hashable {
        case line(UUID, CanvasLine)
        case rectangle(UUID, CanvasRectangle)
        case arch(UUID, CanvasArch)
        case freehand(UUID, UInt64)
        case text(UUID, CanvasRect)

        init(_ element: CanvasElement) {
            switch element.geometry {
            case .line(let line):
                self = .line(element.id, line)
            case .rectangle(let rectangle):
                self = .rectangle(element.id, rectangle)
            case .arch(let arch):
                self = .arch(element.id, arch)
            case .freehand:
                self = .freehand(element.id, element.contentRevision)
            case .text(let text):
                self = .text(element.id, text.frame)
            }
        }
    }

    package private(set) var metrics = CanvasDimensionPresentationMetrics()

    private var cachedKey: DimensionStructureKey?
    private var cachedStructure: CanvasDimensionStructure?
    private var boundsCacheScope: BoundsCacheScope?
    private var cachedElementBounds: [ElementBoundsIdentity: CanvasRect] = [:]

    package func structure(
        document: CanvasDocument,
        replacementGeneration: CanvasGeneration,
        previewRevision: CanvasGeneration,
        committedFreehandHandoff: CanvasCommittedFreehandHandoff? = nil
    ) -> CanvasDimensionStructure {
        let key = DimensionStructureKey(
            documentID: document.id,
            documentRevision: document.revision,
            replacementGeneration: replacementGeneration,
            previewRevision: previewRevision,
            calibration: document.calibration
        )
        if cachedKey == key, let cachedStructure { return cachedStructure }
        let scope = BoundsCacheScope(
            documentID: document.id,
            replacementGeneration: replacementGeneration
        )
        if boundsCacheScope != scope {
            boundsCacheScope = scope
            cachedElementBounds.removeAll(keepingCapacity: true)
        }
        if let (identity, bounds) = reusableBounds(
            from: committedFreehandHandoff,
            in: document
        ) {
            cachedElementBounds[identity] = bounds
        }
        var retainedIdentities = Set<ElementBoundsIdentity>()
        let structure = DimensionEngine.computeStructure(
            document: document,
            boundsForElement: { [self] element in
                let identity = ElementBoundsIdentity(element)
                retainedIdentities.insert(identity)
                if let bounds = cachedElementBounds[identity] {
                    return bounds
                }
                metrics.elementBoundsBuildCount += 1
                let bounds = element.bounds
                cachedElementBounds[identity] = bounds
                return bounds
            }
        )
        cachedElementBounds = cachedElementBounds.filter {
            retainedIdentities.contains($0.key)
        }
        cachedKey = key
        cachedStructure = structure
        metrics.structureBuildCount += 1
        return structure
    }

    private func reusableBounds(
        from handoff: CanvasCommittedFreehandHandoff?,
        in document: CanvasDocument
    ) -> (ElementBoundsIdentity, CanvasRect)? {
        guard let handoff,
              handoff.documentRevision == document.revision,
              document.elements.indices.contains(handoff.documentIndex) else {
            return nil
        }
        let element = document.elements[handoff.documentIndex]
        guard element.id == handoff.elementID,
              element.contentRevision == handoff.contentRevision,
              case .freehand(let stroke) = element.geometry,
              stroke.samples.count == handoff.draft.samples.count,
              handoff.draft.preparedInk.confirmedSamples.count <= stroke.samples.count else {
            return nil
        }
        let remainingSamples = handoff.draft.samples.dropFirst(
            handoff.draft.preparedInk.confirmedSamples.count
        )
        guard let candidate = try? handoff.draft.preparedInk.makeIncrementalCandidate(
            appendingConfirmed: Array(remainingSamples),
            predicted: [],
            isFinalized: true
        ) else {
            return nil
        }
        return (ElementBoundsIdentity(element), candidate.confirmedBounds)
    }

    package func present(
        document: CanvasDocument,
        replacementGeneration: CanvasGeneration,
        previewRevision: CanvasGeneration,
        committedFreehandHandoff: CanvasCommittedFreehandHandoff? = nil,
        viewport: CanvasViewport,
        hiddenKeys: Set<DimensionKey>,
        availableSize: CanvasSize,
        labelFontSize: Double = CanvasDimensionStyle().labelFontSize,
        measurements: CanvasMeasurementsConfiguration = .init(),
        style: CanvasDimensionStyle = .init(),
        locale: Locale = .current
    ) -> [PresentedDimension] {
        project(
            structure(
                document: document,
                replacementGeneration: replacementGeneration,
                previewRevision: previewRevision,
                committedFreehandHandoff: committedFreehandHandoff
            ),
            viewport: viewport,
            hiddenKeys: hiddenKeys,
            availableSize: availableSize,
            labelFontSize: labelFontSize,
            measurements: measurements,
            style: style,
            locale: locale
        )
    }

    package func project(
        _ structure: CanvasDimensionStructure,
        viewport: CanvasViewport,
        hiddenKeys: Set<DimensionKey>,
        availableSize: CanvasSize,
        labelFontSize: Double = CanvasDimensionStyle().labelFontSize,
        measurements: CanvasMeasurementsConfiguration = .init(),
        style: CanvasDimensionStyle = .init(),
        locale: Locale = .current
    ) -> [PresentedDimension] {
        guard availableSize.width.isFinite, availableSize.height.isFinite,
              availableSize.width > 0, availableSize.height > 0,
              labelFontSize.isFinite, labelFontSize > 0 else { return [] }
        let style = style.resolved
        let font = UIFont.monospacedDigitSystemFont(ofSize: labelFontSize, weight: .regular)
        let textHeight = ceil(font.lineHeight) + style.labelPadding * 2
        let candidates = structure.all
            .filter { !hiddenKeys.contains($0.key) && measurements.axes.contains($0.key.axis) && measurements.roles.contains($0.key.role) }
            .compactMap { span -> ProjectionCandidate? in
                let start = viewport.screenPoint(fromCanvas: span.canvasStart)
                let end = viewport.screenPoint(fromCanvas: span.canvasEnd)
                guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else {
                    return nil
                }
                let lower: Double
                let upper: Double
                let limit: Double
                switch span.key.axis {
                case .horizontal:
                    lower = min(start.x, end.x)
                    upper = max(start.x, end.x)
                    limit = availableSize.width
                case .vertical:
                    lower = min(start.y, end.y)
                    upper = max(start.y, end.y)
                    limit = availableSize.height
                }
                guard upper > 0, lower < limit else { return nil }
                let text = (span.millimeters / measurements.unit.millimetersPerUnit).formatted(
                    .number.locale(locale).precision(.fractionLength(0 ... measurements.fractionDigits))
                ) + " " + measurements.unit.symbol
                let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
                    + style.labelPadding * 2
                return ProjectionCandidate(
                    span: span,
                    lower: max(0, lower),
                    upper: min(limit, upper),
                    showsStartTick: lower >= 0,
                    showsEndTick: upper <= limit,
                    text: text,
                    textWidth: textWidth
                )
            }
            .sorted {
                if $0.span.key.axis != $1.span.key.axis {
                    return $0.span.key.axis.rawValue < $1.span.key.axis.rawValue
                }
                if ($0.span.key.role == .overall) != ($1.span.key.role == .overall) {
                    return $1.span.key.role == .overall
                }
                if $0.span.canvasLength != $1.span.canvasLength {
                    return $0.span.canvasLength < $1.span.canvasLength
                }
                if $0.lower != $1.lower { return $0.lower < $1.lower }
                return stableKey($0.span.key) < stableKey($1.span.key)
            }

        var result: [PresentedDimension] = []
        var labelFrames: [CanvasRect] = []
        for axis in [DimensionAxis.horizontal, .vertical] {
            let axisCandidates = candidates.filter { $0.span.key.axis == axis }
            let axisLimit = axis == .horizontal ? availableSize.width : availableSize.height
            let crossLimit = axis == .horizontal ? availableSize.height : availableSize.width
            let outerBaseline = crossLimit - style.edgeInset - textHeight / 2
            let tickClearance = style.terminatorHalfLength + style.labelGap
            let raisedOffset = textHeight / 2 + tickClearance
            let hasRaisedLabels = axisCandidates.contains { $0.textWidth + tickClearance * 2 > $0.upper - $0.lower }
            let inwardExtent = hasRaisedLabels ? textHeight + tickClearance : textHeight / 2
            let spacing = inwardExtent + textHeight / 2 + style.laneGap
            let maximumLanes = Int(min(Double(axisCandidates.count), max(0, floor((outerBaseline - inwardExtent) / spacing) + 1)))
            let hasOverall = axisCandidates.contains { $0.span.key.role == .overall }
            var lanes: [[DimensionLaneOccupancy]] = []
            var placements: [(candidate: ProjectionCandidate, lane: Int, midpoint: Double)] = []
            for candidate in axisCandidates {
                let halfWidth = candidate.textWidth / 2
                let midpoint = min(max(
                    candidate.lower + (candidate.upper - candidate.lower) / 2,
                    halfWidth + style.edgeInset
                ), axisLimit - halfWidth - style.edgeInset)
                let occupied = DimensionLaneOccupancy(
                    line: candidate.lower...candidate.upper,
                    label: (midpoint - halfWidth - style.labelGap)
                        ... (midpoint + halfWidth + style.labelGap)
                )
                let lane = candidate.span.key.role == .overall ? lanes.count : lanes.firstIndex { intervals in
                    !intervals.contains { $0.collides(with: occupied) }
                } ?? lanes.count
                let laneLimit = candidate.span.key.role == .overall ? maximumLanes : maximumLanes - (hasOverall ? 1 : 0)
                guard lane < laneLimit else { continue }
                if lane == lanes.count { lanes.append([]) }
                lanes[lane].append(occupied)
                placements.append((candidate, lane, midpoint))
            }
            for (candidate, lane, midpoint) in placements {
                let baseline = outerBaseline - Double(lanes.count - 1 - lane) * spacing
                let raised = candidate.textWidth + tickClearance * 2 > candidate.upper - candidate.lower
                let labelBaseline = raised ? baseline - raisedOffset : baseline
                let start = axis == .horizontal
                    ? CanvasPoint(x: candidate.lower, y: baseline)
                    : CanvasPoint(x: baseline, y: candidate.lower)
                let end = axis == .horizontal
                    ? CanvasPoint(x: candidate.upper, y: baseline)
                    : CanvasPoint(x: baseline, y: candidate.upper)
                let label = axis == .horizontal
                    ? CanvasPoint(x: midpoint, y: labelBaseline)
                    : CanvasPoint(x: labelBaseline, y: midpoint)
                let size = axis == .horizontal
                    ? CanvasSize(width: candidate.textWidth, height: textHeight)
                    : CanvasSize(width: textHeight, height: candidate.textWidth)
                let frame = CanvasRect(
                    x: label.x - size.width / 2, y: label.y - size.height / 2,
                    width: size.width, height: size.height
                )
                let fits = frame.minX >= 0 && frame.minY >= 0
                    && frame.maxX <= availableSize.width && frame.maxY <= availableSize.height
                    && !labelFrames.contains { other in
                        other.minX < frame.maxX && frame.minX < other.maxX
                            && other.minY < frame.maxY && frame.minY < other.maxY
                    }
                if fits { labelFrames.append(frame) }
                var extensions: [CanvasDimensionLine] = []
                for (origin, endpoint, showsTick) in [
                    (candidate.span.extensionStart, start, candidate.showsStartTick),
                    (candidate.span.extensionEnd, end, candidate.showsEndTick),
                ] {
                    guard measurements.showsExtensionLines, showsTick, let origin else { continue }
                    let projected = viewport.screenPoint(fromCanvas: origin)
                    let coordinate = axis == .horizontal ? projected.y : projected.x
                    guard coordinate.isFinite else { continue }
                    let direction = coordinate < baseline ? 1.0 : -1.0
                    let from = coordinate + direction * style.extensionGap
                    let to = baseline + direction * style.extensionOvershoot
                    guard abs(coordinate - baseline) > style.extensionGap else { continue }
                    let clippedFrom = min(max(from, 0), crossLimit)
                    let clippedTo = min(max(to, 0), crossLimit)
                    extensions.append(.init(
                        start: axis == .horizontal ? .init(x: endpoint.x, y: clippedFrom) : .init(x: clippedFrom, y: endpoint.y),
                        end: axis == .horizontal ? .init(x: endpoint.x, y: clippedTo) : .init(x: clippedTo, y: endpoint.y)
                    ))
                }
                result.append(PresentedDimension(
                    id: candidate.span.key,
                    dimension: candidate.span,
                    clippedStart: start,
                    clippedEnd: end,
                    labelPosition: fits ? label : nil,
                    labelText: candidate.text,
                    labelSize: size,
                    showsStartTick: candidate.showsStartTick,
                    showsEndTick: candidate.showsEndTick,
                    extensionLines: extensions
                ))
            }
        }
        return result
    }
}

private struct ProjectionCandidate {
    let span: CanvasDimensionSpan
    let lower: Double
    let upper: Double
    let showsStartTick: Bool
    let showsEndTick: Bool
    let text: String
    let textWidth: Double
}

private struct DimensionLaneOccupancy {
    let line: ClosedRange<Double>
    let label: ClosedRange<Double>

    func collides(with other: Self) -> Bool {
        (line.lowerBound < other.line.upperBound && other.line.lowerBound < line.upperBound)
            || (label.lowerBound < other.label.upperBound && other.label.lowerBound < label.upperBound)
    }
}


private func stableKey(_ key: DimensionKey) -> String {
    "\(key.axis.rawValue)-\(key.role)-\(key.startEdge)-\(key.endEdge)-\(key.elementIDs.map(\.uuidString).joined())"
}

/// Architectural slash terminators. A short diagonal stroke through the
/// dimension end stays readable where adjacent dimension lines meet, which a
/// square tick does not.
package enum CanvasDimensionTerminator {
    package static let halfLength = CanvasDimensionStyle().terminatorHalfLength

    package static func slash(
        at point: CanvasPoint,
        axis: DimensionAxis,
        halfLength: Double = halfLength
    ) -> (start: CanvasPoint, end: CanvasPoint) {
        let offset = halfLength / 2.squareRoot()
        switch axis {
        case .horizontal:
            return (
                .init(x: point.x - offset, y: point.y + offset),
                .init(x: point.x + offset, y: point.y - offset)
            )
        case .vertical:
            return (
                .init(x: point.x - offset, y: point.y - offset),
                .init(x: point.x + offset, y: point.y + offset)
            )
        }
    }
}
