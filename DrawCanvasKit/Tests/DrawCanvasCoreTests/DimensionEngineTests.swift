import Foundation
import XCTest
@testable import DrawCanvasCore

final class DimensionEngineTests: XCTestCase {
    func testTouchingShapesKeepIndividualMeasurementsAndOneOverall() {
        let document = CanvasDocument(elements: [
            rectangle(id: firstID, x: 0, y: 0, width: 100, height: 80),
            rectangle(id: secondID, x: 100, y: 0, width: 60, height: 80),
        ])
        let dimensions = DimensionEngine.computeStructure(document: document).horizontal

        XCTAssertEqual(dimensions.filter { $0.key.role == .element }.map(\.canvasLength), [100, 60])
        XCTAssertEqual(dimensions.filter { $0.canvasLength == 160 }.count, 1,
                       "The group and overall must not repeat the same endpoints")
        XCTAssertEqual(dimensions.last?.key.role, .overall)
    }

    func testCoincidentShapesProduceOneMeasurementNotAnIdenticalOverall() {
        let document = CanvasDocument(elements: [
            rectangle(id: firstID, x: 20, y: 10, width: 100, height: 80),
            rectangle(id: secondID, x: 20, y: 10, width: 100, height: 80),
        ])
        let structure = DimensionEngine.computeStructure(document: document)

        XCTAssertEqual(structure.horizontal.count, 1)
        XCTAssertEqual(structure.vertical.count, 1)
        XCTAssertEqual(structure.horizontal.first?.key.elementIDs, [secondID, firstID])
        XCTAssertFalse(structure.horizontal.first?.isEditable ?? true)
    }

    func testOverlappingShapesRetainTheirDistinctLengths() {
        let document = CanvasDocument(elements: [
            rectangle(id: firstID, x: 0, y: 0, width: 100, height: 80),
            rectangle(id: secondID, x: 50, y: 0, width: 120, height: 80),
        ])
        let dimensions = DimensionEngine.computeStructure(document: document).horizontal

        XCTAssertEqual(dimensions.map(\.canvasLength), [100, 120, 170])
        XCTAssertEqual(dimensions.filter(\.isEditable).count, 2)
    }

    func testStructuralDimensionsProjectToLegacyLayout() throws {
        let document = CanvasDocument(elements: [
            .rectangle(id: UUID(), rect: .init(x: 10, y: 20, width: 30, height: 40)),
        ])
        let viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 5, y: 7),
            viewportSize: .init(width: 200, height: 200)
        )

        XCTAssertEqual(
            DimensionEngine.project(
                structure: DimensionEngine.computeStructure(document: document),
                viewport: viewport
            ),
            DimensionEngine.compute(document: document, viewport: viewport)
        )
    }
    private let viewport = try! CanvasViewport.identity(size: .init(width: 1_024, height: 768))
    private let firstID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    func testEmptyDocumentProducesEmptyLayout() {
        let layout = DimensionEngine.compute(document: .empty(), viewport: viewport)

        XCTAssertTrue(layout.horizontal.isEmpty)
        XCTAssertTrue(layout.vertical.isEmpty)
        XCTAssertTrue(layout.all.isEmpty)
    }

    func testSingleRectangleProducesCalibratedElementDimensionsInScreenSpace() throws {
        let element = rectangle(id: firstID, x: 10, y: 20, width: 100, height: 80)
        let document = CanvasDocument(
            elements: [element],
            calibration: .init(millimetersPerPoint: 2.5)
        )
        let transformedViewport = try CanvasViewport(
            zoom: 3,
            translation: .init(x: 200, y: -50),
            viewportSize: .init(width: 1_024, height: 768)
        )

        let layout = DimensionEngine.compute(document: document, viewport: transformedViewport)
        let horizontal = try XCTUnwrap(layout.horizontal.only)
        let vertical = try XCTUnwrap(layout.vertical.only)

        XCTAssertEqual(horizontal.key.role, .element)
        XCTAssertEqual(horizontal.key.axis, .horizontal)
        XCTAssertEqual(horizontal.key.elementIDs, [firstID])
        XCTAssertEqual(horizontal.canvasLength, 100, accuracy: 0.000_001)
        XCTAssertEqual(horizontal.millimeters, 250, accuracy: 0.000_001)
        XCTAssertEqual(horizontal.screenStart, CanvasPoint(x: 230, y: -50))
        XCTAssertEqual(horizontal.screenEnd, CanvasPoint(x: 530, y: -50))
        XCTAssertTrue(horizontal.isEditable)

        XCTAssertEqual(vertical.key.role, .element)
        XCTAssertEqual(vertical.key.axis, .vertical)
        XCTAssertEqual(vertical.canvasLength, 80, accuracy: 0.000_001)
        XCTAssertEqual(vertical.millimeters, 200, accuracy: 0.000_001)
        XCTAssertEqual(vertical.screenStart, CanvasPoint(x: 200, y: 10))
        XCTAssertEqual(vertical.screenEnd, CanvasPoint(x: 200, y: 250))
        XCTAssertTrue(vertical.isEditable)
    }

    func testKeysRemainStableAcrossViewportChanges() throws {
        let element = rectangle(id: firstID, x: 10, y: 20, width: 100, height: 80)
        let document = CanvasDocument(elements: [element])
        let first = DimensionEngine.compute(document: document, viewport: viewport)
        let second = DimensionEngine.compute(
            document: document,
            viewport: try .init(
                zoom: 3,
                translation: .init(x: 200, y: -50),
                viewportSize: .init(width: 1_024, height: 768)
            )
        )

        XCTAssertEqual(Set(first.all.map(\.key)), Set(second.all.map(\.key)))
        XCTAssertNotEqual(first.horizontal.first?.screenStart, second.horizontal.first?.screenStart)
    }

    func testDimensionKeySortsUUIDsAndQuantizesEdgesToOneMillionthOfAPoint() {
        let first = DimensionKey(
            axis: .horizontal,
            role: .merged,
            elementIDs: [firstID, secondID],
            startEdge: 10.000_000_41,
            endEdge: 20.000_000_41
        )
        let second = DimensionKey(
            axis: .horizontal,
            role: .merged,
            elementIDs: [secondID, firstID],
            startEdge: 10.000_000_49,
            endEdge: 20.000_000_49
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.elementIDs, [secondID, firstID])
        XCTAssertEqual(first.startEdge, 10, accuracy: 0.000_000_000_1)
        XCTAssertEqual(first.endEdge, 20, accuracy: 0.000_000_000_1)
    }

    func testDimensionKeyPreservesSortingAndQuantizationAfterMutation() {
        var key = DimensionKey(
            axis: .horizontal,
            role: .element,
            elementIDs: [secondID],
            startEdge: 0,
            endEdge: 1
        )

        key.elementIDs = [firstID, secondID]
        key.startEdge = 10.000_000_41
        key.endEdge = 20.000_000_41

        XCTAssertEqual(key.elementIDs, [secondID, firstID])
        XCTAssertEqual(key.startEdge, 10, accuracy: 0.000_000_000_1)
        XCTAssertEqual(key.endEdge, 20, accuracy: 0.000_000_000_1)
    }

    func testSeparatedRectanglesProduceElementGapElementAndOverallSpans() {
        let layout = DimensionEngine.compute(document: separatedRectangles(), viewport: viewport)

        XCTAssertEqual(layout.horizontal.map(\.key.role), [.element, .gap, .element, .overall])
        XCTAssertEqual(layout.horizontal.map(\.key.startEdge), [0, 100, 200, 0])
        XCTAssertEqual(layout.horizontal.map(\.key.endEdge), [100, 200, 300, 300])
        XCTAssertEqual(layout.horizontal[1].key.elementIDs, [secondID, firstID])
        XCTAssertTrue(layout.horizontal[1].isGap)
        XCTAssertTrue(layout.horizontal[3].isOverall)
    }

    func testTouchingNonGapSpansMergeWithDeterministicIdentity() throws {
        let document = CanvasDocument(elements: [
            rectangle(id: firstID, x: 0, y: 0, width: 100, height: 80),
            rectangle(id: secondID, x: 100, y: 0, width: 100, height: 80),
            rectangle(id: UUID(), x: 300, y: 0, width: 50, height: 80),
        ])

        let layout = DimensionEngine.compute(document: document, viewport: viewport)
        let merged = try XCTUnwrap(layout.horizontal.first { $0.isMerged })

        XCTAssertEqual(merged.key.startEdge, 0)
        XCTAssertEqual(merged.key.endEdge, 200)
        XCTAssertEqual(merged.key.elementIDs, [secondID, firstID])
        XCTAssertEqual(merged.canvasLength, 200, accuracy: 0.000_001)
        XCTAssertFalse(merged.isEditable)
    }

    func testOnlySingleElementNonGapDimensionsAreEditable() {
        let layout = DimensionEngine.compute(document: separatedRectangles(), viewport: viewport)

        XCTAssertTrue(layout.all.filter { $0.key.role == .element }.allSatisfy(\.isEditable))
        XCTAssertTrue(layout.all.filter(\.isMerged).allSatisfy { !$0.isEditable })
        XCTAssertTrue(layout.all.filter(\.isGap).allSatisfy { !$0.isEditable })
        XCTAssertTrue(layout.all.filter(\.isOverall).allSatisfy { !$0.isEditable })
    }

    func testTextDimensionsAreNotEditableAndResizeReturnsTypedError() throws {
        let text = CanvasElement(
            id: firstID,
            geometry: .text(
                .init(
                    frame: .init(x: 10, y: 20, width: 28.8, height: 14.4),
                    text: "OAQS",
                    font: .init(familyName: "Portable", pointSize: 12),
                    color: .black
                )
            )
        )
        let document = CanvasDocument(elements: [text])
        let dimensions = DimensionEngine.compute(document: document, viewport: viewport).all

        XCTAssertFalse(dimensions.isEmpty)
        XCTAssertTrue(dimensions.allSatisfy { !$0.isEditable })
        for dimension in dimensions {
            XCTAssertThrowsError(
                try DimensionEngine.resizeCommand(for: dimension, newMillimeters: 100, in: document)
            ) {
                XCTAssertEqual($0 as? DimensionEngineError, .dimensionNotEditable)
            }
        }
    }

    func testDegenerateArchDimensionIsNotEditableAndResizeReturnsTypedError() throws {
        let arch = CanvasElement(
            id: firstID,
            geometry: .arch(
                .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: 0)
            )
        )
        let document = CanvasDocument(elements: [arch])
        let dimension = try XCTUnwrap(
            DimensionEngine.compute(document: document, viewport: viewport).horizontal.only
        )

        XCTAssertFalse(dimension.isEditable)
        XCTAssertThrowsError(
            try DimensionEngine.resizeCommand(for: dimension, newMillimeters: 150, in: document)
        ) {
            XCTAssertEqual($0 as? DimensionEngineError, .dimensionNotEditable)
        }
    }

    func testObliqueArchDimensionsAreNotEditableAndResizeReturnsTypedError() throws {
        let arch = CanvasElement(
            id: firstID,
            geometry: .arch(
                .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 50), sagitta: 25)
            )
        )
        let document = CanvasDocument(elements: [arch])
        let dimensions = DimensionEngine.compute(document: document, viewport: viewport).all

        XCTAssertFalse(dimensions.isEmpty)
        XCTAssertTrue(dimensions.allSatisfy { !$0.isEditable })
        for dimension in dimensions {
            XCTAssertThrowsError(
                try DimensionEngine.resizeCommand(for: dimension, newMillimeters: 150, in: document)
            ) {
                XCTAssertEqual($0 as? DimensionEngineError, .dimensionNotEditable)
            }
        }
    }

    func testSupportedGeometryTypesRetainEditableDimensions() throws {
        let elements = [
            rectangle(id: firstID, x: 0, y: 0, width: 100, height: 80),
            CanvasElement(
                id: firstID,
                geometry: .line(.init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 80)))
            ),
            CanvasElement(
                id: firstID,
                geometry: .freehand(
                    .init(
                        samples: [
                            .init(point: .init(x: 0, y: 0), pressure: 1),
                            .init(point: .init(x: 100, y: 80), pressure: 1),
                        ],
                        pressureEnabled: true
                    )
                )
            ),
            CanvasElement(
                id: firstID,
                geometry: .arch(
                    .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: 25)
                )
            ),
        ]

        for element in elements {
            let document = CanvasDocument(elements: [element])
            let dimensions = DimensionEngine.compute(document: document, viewport: viewport).all
            XCTAssertFalse(dimensions.isEmpty)
            XCTAssertTrue(dimensions.allSatisfy(\.isEditable), "Expected \(element.geometry.kind) to be editable")
            for dimension in dimensions {
                XCTAssertNoThrow(
                    try DimensionEngine.resizeCommand(
                        for: dimension,
                        newMillimeters: dimension.millimeters * 1.25,
                        in: document
                    )
                )
            }
        }
    }

    func testPreparedBoundsAvoidTraversingLongFreehandGeometry() {
        let samples = (0..<20_000).map { index in
            CanvasInkSample(
                point: .init(x: Double(index), y: Double(index % 100)),
                pressure: 0.5
            )
        }
        let document = CanvasDocument(elements: [
            CanvasElement(
                id: firstID,
                geometry: .freehand(.init(samples: samples, pressureEnabled: true))
            ),
        ])
        let start = ProcessInfo.processInfo.systemUptime

        let structure = DimensionEngine.computeStructure(document: document) { _ in
            CanvasRect(x: 0, y: 0, width: 19_999, height: 99)
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertTrue(structure.all.allSatisfy(\.isEditable))
        XCTAssertLessThan(elapsed, 0.1)
    }

    func testResizeRejectsForgedElementKeyForCurrentlyMergedGeometry() throws {
        let document = CanvasDocument(elements: [
            rectangle(id: firstID, x: 0, y: 0, width: 100, height: 80),
            rectangle(id: secondID, x: 0, y: 0, width: 100, height: 80),
        ])
        var forged = try XCTUnwrap(
            DimensionEngine.compute(document: document, viewport: viewport)
                .horizontal.first(where: \.isMerged)
        )
        forged.key.role = .element
        forged.key.elementIDs = [firstID]
        forged.isEditable = true

        XCTAssertThrowsError(
            try DimensionEngine.resizeCommand(for: forged, newMillimeters: 150, in: document)
        ) {
            XCTAssertEqual($0 as? DimensionEngineError, .dimensionNotEditable)
        }
    }

    func testCalibratedLengthUnderflowIsOmitted() {
        let document = CanvasDocument(
            elements: [rectangle(id: firstID, x: 0, y: 0, width: 0.25, height: 1)],
            calibration: .init(millimetersPerPoint: .leastNonzeroMagnitude)
        )

        let layout = DimensionEngine.compute(document: document, viewport: viewport)

        XCTAssertTrue(layout.horizontal.isEmpty)
        XCTAssertEqual(layout.vertical.count, 1)
        XCTAssertEqual(layout.vertical[0].millimeters, .leastNonzeroMagnitude)
    }

    func testZeroWidthElementDoesNotSplitOrReclassifyRealElementWidth() throws {
        let document = CanvasDocument(elements: [
            rectangle(id: firstID, x: 0, y: 0, width: 100, height: 80),
            rectangle(id: secondID, x: 50, y: 0, width: 0, height: 80),
        ])

        let horizontal = DimensionEngine.compute(document: document, viewport: viewport).horizontal
        let dimension = try XCTUnwrap(horizontal.only)

        XCTAssertEqual(dimension.key.role, .element)
        XCTAssertEqual(dimension.key.elementIDs, [firstID])
        XCTAssertEqual(dimension.key.startEdge, 0)
        XCTAssertEqual(dimension.key.endEdge, 100)
        XCTAssertTrue(dimension.isEditable)
    }

    func testDimensionEditAnchorsOppositeHorizontalEdgeAndUndoRestoresGeometry() throws {
        let original = rectangle(id: firstID, x: 20, y: 10, width: 100, height: 80)
        var document = CanvasDocument(
            elements: [original],
            calibration: .init(millimetersPerPoint: 5)
        )
        var history = CanvasHistory()
        let layout = DimensionEngine.compute(document: document, viewport: viewport)
        let widthDimension = try XCTUnwrap(layout.horizontal.first(where: \.isEditable))

        let command = try DimensionEngine.resizeCommand(
            for: widthDimension,
            newMillimeters: 750,
            in: document
        )
        try history.perform(command, on: &document)

        XCTAssertEqual(document.elements[0].geometry.bounds.minX, 20, accuracy: 0.000_001)
        XCTAssertEqual(document.elements[0].geometry.bounds.width, 150, accuracy: 0.000_001)
        try history.undo(on: &document)
        XCTAssertEqual(document.elements[0].geometry, original.geometry)
    }

    func testDimensionEditAnchorsOppositeVerticalEdge() throws {
        let original = rectangle(id: firstID, x: 20, y: 10, width: 100, height: 80)
        let document = CanvasDocument(
            elements: [original],
            calibration: .init(millimetersPerPoint: 2)
        )
        let heightDimension = try XCTUnwrap(
            DimensionEngine.compute(document: document, viewport: viewport)
                .vertical.first(where: \.isEditable)
        )

        let replacement = try replacementElement(
            from: DimensionEngine.resizeCommand(for: heightDimension, newMillimeters: 100, in: document)
        )

        XCTAssertEqual(replacement.bounds.minY, 10, accuracy: 0.000_001)
        XCTAssertEqual(replacement.bounds.height, 50, accuracy: 0.000_001)
        XCTAssertEqual(replacement.bounds.width, 100, accuracy: 0.000_001)
    }

    func testResizeRejectsZeroMeasurement() throws {
        let (dimension, document) = editableHorizontalDimension()
        XCTAssertThrowsError(try DimensionEngine.resizeCommand(for: dimension, newMillimeters: 0, in: document)) {
            XCTAssertEqual($0 as? DimensionEngineError, .invalidMeasurement)
        }
    }

    func testResizeRejectsNegativeMeasurement() throws {
        let (dimension, document) = editableHorizontalDimension()
        XCTAssertThrowsError(try DimensionEngine.resizeCommand(for: dimension, newMillimeters: -1, in: document)) {
            XCTAssertEqual($0 as? DimensionEngineError, .invalidMeasurement)
        }
    }

    func testResizeRejectsNaNMeasurement() throws {
        let (dimension, document) = editableHorizontalDimension()
        XCTAssertThrowsError(try DimensionEngine.resizeCommand(for: dimension, newMillimeters: .nan, in: document)) {
            XCTAssertEqual($0 as? DimensionEngineError, .invalidMeasurement)
        }
    }

    func testResizeRejectsInfiniteMeasurement() throws {
        let (dimension, document) = editableHorizontalDimension()
        XCTAssertThrowsError(try DimensionEngine.resizeCommand(for: dimension, newMillimeters: .infinity, in: document)) {
            XCTAssertEqual($0 as? DimensionEngineError, .invalidMeasurement)
        }
    }

    func testResizeRejectsDivisionOverflow() throws {
        var (dimension, document) = editableHorizontalDimension()
        document.calibration = .init(millimetersPerPoint: .leastNonzeroMagnitude)

        XCTAssertThrowsError(
            try DimensionEngine.resizeCommand(
                for: dimension,
                newMillimeters: .greatestFiniteMagnitude,
                in: document
            )
        ) {
            XCTAssertEqual($0 as? DimensionEngineError, .measurementOverflow)
        }
    }

    func testResizeRejectsAnchoredEdgeOverflow() throws {
        let document = CanvasDocument(elements: [
            rectangle(
                id: firstID,
                x: .greatestFiniteMagnitude / 2,
                y: 0,
                width: .greatestFiniteMagnitude / 4,
                height: 80
            ),
        ])
        let dimension = try XCTUnwrap(
            DimensionEngine.compute(document: document, viewport: viewport)
                .horizontal.first(where: \.isEditable)
        )

        XCTAssertThrowsError(
            try DimensionEngine.resizeCommand(
                for: dimension,
                newMillimeters: .greatestFiniteMagnitude,
                in: document
            )
        ) {
            XCTAssertEqual($0 as? DimensionEngineError, .measurementOverflow)
        }
    }

    func testExtremeRectangleUsesSafeShrinkProbeAndRemainsEditable() throws {
        let start = Double.greatestFiniteMagnitude / 2
        let originalWidth = Double.greatestFiniteMagnitude / 2
        let requestedWidth = Double.greatestFiniteMagnitude / 4
        let document = CanvasDocument(elements: [
            rectangle(
                id: firstID,
                x: start,
                y: 0,
                width: originalWidth,
                height: 80
            ),
        ])
        let dimension = try XCTUnwrap(
            DimensionEngine.compute(document: document, viewport: viewport).horizontal.only
        )

        XCTAssertTrue(dimension.isEditable)
        let replacement = try replacementElement(
            from: DimensionEngine.resizeCommand(
                for: dimension,
                newMillimeters: requestedWidth,
                in: document
            )
        )
        XCTAssertEqual(replacement.bounds.minX, start)
        XCTAssertEqual(replacement.bounds.width, requestedWidth)
    }

    func testResizeRejectsGapDimension() throws {
        let document = separatedRectangles()
        let dimension = try XCTUnwrap(
            DimensionEngine.compute(document: document, viewport: viewport).horizontal.first(where: \.isGap)
        )

        XCTAssertThrowsError(try DimensionEngine.resizeCommand(for: dimension, newMillimeters: 50, in: document)) {
            XCTAssertEqual($0 as? DimensionEngineError, .dimensionNotEditable)
        }
    }

    func testResizeRejectsMergedDimension() throws {
        let document = CanvasDocument(elements: [
            rectangle(id: firstID, x: 0, y: 0, width: 100, height: 80),
            rectangle(id: secondID, x: 0, y: 0, width: 100, height: 80),
        ])
        let dimension = try XCTUnwrap(
            DimensionEngine.compute(document: document, viewport: viewport).horizontal.first(where: \.isMerged)
        )

        XCTAssertThrowsError(try DimensionEngine.resizeCommand(for: dimension, newMillimeters: 50, in: document)) {
            XCTAssertEqual($0 as? DimensionEngineError, .dimensionNotEditable)
        }
    }

    func testResizeRejectsOverallDimension() throws {
        let document = separatedRectangles()
        let dimension = try XCTUnwrap(
            DimensionEngine.compute(document: document, viewport: viewport).horizontal.first(where: \.isOverall)
        )

        XCTAssertThrowsError(try DimensionEngine.resizeCommand(for: dimension, newMillimeters: 50, in: document)) {
            XCTAssertEqual($0 as? DimensionEngineError, .dimensionNotEditable)
        }
    }

    func testResizeRejectsMissingElement() throws {
        var (dimension, document) = editableHorizontalDimension()
        document.elements.removeAll()

        XCTAssertThrowsError(try DimensionEngine.resizeCommand(for: dimension, newMillimeters: 50, in: document)) {
            XCTAssertEqual($0 as? DimensionEngineError, .elementNotFound(firstID))
        }
    }

    func testResizeRejectsDimensionStaleAfterElementMove() throws {
        var (dimension, document) = editableHorizontalDimension()
        document.elements[0] = try document.elements[0].moved(by: .init(x: 10, y: 0))

        XCTAssertThrowsError(try DimensionEngine.resizeCommand(for: dimension, newMillimeters: 50, in: document)) {
            XCTAssertEqual($0 as? DimensionEngineError, .staleDimension)
        }
    }

    func testResizeRejectsDimensionStaleAfterElementResize() throws {
        var (dimension, document) = editableHorizontalDimension()
        document.elements[0] = try document.elements[0].replacingBounds(
            .init(x: 0, y: 0, width: 200, height: 80)
        )

        XCTAssertThrowsError(try DimensionEngine.resizeCommand(for: dimension, newMillimeters: 50, in: document)) {
            XCTAssertEqual($0 as? DimensionEngineError, .staleDimension)
        }
    }

    func testResizeRejectsInvalidCalibrationValues() throws {
        let invalidValues: [Double] = [0, -1, .nan, .infinity]

        for value in invalidValues {
            var (dimension, document) = editableHorizontalDimension()
            document.calibration = .init(millimetersPerPoint: value)

            XCTAssertThrowsError(
                try DimensionEngine.resizeCommand(for: dimension, newMillimeters: 50, in: document),
                "Expected calibration \(value) to be rejected"
            ) {
                XCTAssertEqual($0 as? DimensionEngineError, .invalidCalibration)
            }
        }
    }

    func testComputeReturnsEmptyLayoutForInvalidCalibration() {
        for value in [0.0, -1, .nan, .infinity] {
            let document = CanvasDocument(
                elements: [rectangle(id: firstID, x: 0, y: 0, width: 100, height: 80)],
                calibration: .init(millimetersPerPoint: value)
            )

            XCTAssertTrue(DimensionEngine.compute(document: document, viewport: viewport).all.isEmpty)
        }
    }

    func testComputeOmitsDimensionsWhoseCanvasOrMillimeterLengthsOverflow() {
        let overflowingBounds = CanvasDocument(elements: [
            rectangle(id: firstID, x: .greatestFiniteMagnitude, y: 0, width: .greatestFiniteMagnitude, height: 80),
        ])
        let overflowingCalibration = CanvasDocument(
            elements: [rectangle(id: firstID, x: 0, y: 0, width: .greatestFiniteMagnitude, height: 80)],
            calibration: .init(millimetersPerPoint: 2)
        )

        XCTAssertTrue(DimensionEngine.compute(document: overflowingBounds, viewport: viewport).horizontal.isEmpty)
        XCTAssertTrue(DimensionEngine.compute(document: overflowingCalibration, viewport: viewport).horizontal.isEmpty)
    }

    private func rectangle(
        id: UUID,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> CanvasElement {
        .rectangle(id: id, rect: .init(x: x, y: y, width: width, height: height))
    }

    private func separatedRectangles() -> CanvasDocument {
        CanvasDocument(elements: [
            rectangle(id: firstID, x: 0, y: 0, width: 100, height: 80),
            rectangle(id: secondID, x: 200, y: 0, width: 100, height: 80),
        ])
    }

    private func editableHorizontalDimension(x: Double = 0) -> (ProjectedDimension, CanvasDocument) {
        let document = CanvasDocument(elements: [
            rectangle(id: firstID, x: x, y: 0, width: 100, height: 80),
        ])
        let dimension = DimensionEngine.compute(document: document, viewport: viewport).horizontal[0]
        return (dimension, document)
    }

    private func replacementElement(from command: CanvasCommand) throws -> CanvasElement {
        guard case .setGeometry(let id, let geometry) = command else {
            return try XCTUnwrap(nil as CanvasElement?, "Expected setGeometry command")
        }
        return CanvasElement(id: id, geometry: geometry)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
