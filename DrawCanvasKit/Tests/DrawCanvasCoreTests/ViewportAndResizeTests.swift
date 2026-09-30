import XCTest
@testable import DrawCanvasCore

final class ViewportAndResizeTests: XCTestCase {
    func testInvalidViewportCandidatesLeaveOriginalUnchanged() throws {
        let original = try CanvasViewport.identity(size: .init(width: 100, height: 100))

        XCTAssertThrowsError(try original.panned(byScreen: .init(x: .infinity, y: 0)))
        XCTAssertThrowsError(try original.zoomed(by: 2, anchoredAtScreen: .init(x: .nan, y: 0)))
        XCTAssertEqual(original, try .identity(size: .init(width: 100, height: 100)))
    }

    func testViewportRoundTripAndAnchoredZoom() throws {
        var viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 30, y: -10),
            viewportSize: .init(width: 1024, height: 768)
        )
        let canvas = CanvasPoint(x: 100, y: 50)
        let roundTrip = viewport.canvasPoint(fromScreen: viewport.screenPoint(fromCanvas: canvas))
        XCTAssertEqual(roundTrip.x, canvas.x, accuracy: 0.000_001)
        XCTAssertEqual(roundTrip.y, canvas.y, accuracy: 0.000_001)

        let anchor = CanvasPoint(x: 400, y: 300)
        let before = viewport.canvasPoint(fromScreen: anchor)
        viewport = try viewport.zoomed(by: 1.5, anchoredAtScreen: anchor)
        let after = viewport.canvasPoint(fromScreen: anchor)
        XCTAssertEqual(after.x, before.x, accuracy: 0.000_001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.000_001)
    }

    func testViewportIdentityVisibleRectRelativePanAndZoomClamping() throws {
        var viewport = try CanvasViewport.identity(size: .init(width: 800, height: 600))
        XCTAssertEqual(viewport.visibleCanvasRect, CanvasRect(x: 0, y: 0, width: 800, height: 600))

        viewport = try viewport.panned(byScreen: .init(x: 30, y: -10))
        viewport = try viewport.panned(byScreen: .init(x: 100, y: 25))
        XCTAssertEqual(viewport.translation, CanvasPoint(x: 130, y: 15))

        let anchor = CanvasPoint(x: 200, y: 150)
        let fixedPoint = viewport.canvasPoint(fromScreen: anchor)
        viewport = try viewport.zoomed(by: 100, anchoredAtScreen: anchor)
        XCTAssertEqual(viewport.zoom, CanvasViewport.zoomRange.upperBound)
        XCTAssertEqual(viewport.canvasPoint(fromScreen: anchor).x, fixedPoint.x, accuracy: 0.000_001)
        XCTAssertEqual(viewport.canvasPoint(fromScreen: anchor).y, fixedPoint.y, accuracy: 0.000_001)

        viewport = try viewport.zoomed(by: 0.000_1, anchoredAtScreen: anchor)
        XCTAssertEqual(viewport.zoom, CanvasViewport.zoomRange.lowerBound)
        XCTAssertEqual(viewport.canvasPoint(fromScreen: anchor).x, fixedPoint.x, accuracy: 0.000_001)
        XCTAssertEqual(viewport.canvasPoint(fromScreen: anchor).y, fixedPoint.y, accuracy: 0.000_001)
    }

    func testViewportZoomInvariantAcrossInitializationAndCandidates() throws {
        for (requestedZoom, expectedZoom) in [
            (0.5, CanvasViewport.zoomRange.lowerBound),
            (21, CanvasViewport.zoomRange.upperBound),
        ] {
            let viewport = try CanvasViewport(
                zoom: requestedZoom,
                translation: .init(x: 0, y: 0),
                viewportSize: .init(width: 800, height: 600)
            )
            XCTAssertEqual(viewport.zoom, expectedZoom, "requested zoom: \(requestedZoom)")
        }
        for requestedZoom in [0, Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try CanvasViewport(
                zoom: requestedZoom,
                translation: .init(x: 0, y: 0),
                viewportSize: .init(width: 800, height: 600)
            ))
        }

        var viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 800, height: 600)
        )
        for factor in [0.5, 21] {
            viewport = try viewport.zoomed(by: factor, anchoredAtScreen: .init(x: 100, y: 100))
            XCTAssertTrue(viewport.zoom.isFinite, "factor: \(factor)")
            XCTAssertTrue(CanvasViewport.zoomRange.contains(viewport.zoom), "factor: \(factor)")
        }
        for factor: Double in [0, .nan, .infinity, -.infinity] {
            let before = viewport
            XCTAssertThrowsError(
                try viewport.zoomed(by: factor, anchoredAtScreen: .init(x: 100, y: 100))
            )
            XCTAssertEqual(viewport, before)
        }
    }

    func testTenIncrementalResizeEventsProduceFullCumulativeDelta() throws {
        let original = CanvasRect(x: 0, y: 0, width: 100, height: 80)
        var result = original
        for event in 1...10 {
            result = ResizeEngine.resizedBounds(
                original: original,
                handle: .bottomRight,
                cumulativeDelta: .init(x: Double(event * 10), y: Double(event * 5)),
                minimumSize: 10
            )
        }
        XCTAssertEqual(result, CanvasRect(x: 0, y: 0, width: 200, height: 130))
    }

    func testLeftHandleClampKeepsRightEdgeFixed() throws {
        let original = CanvasRect(x: 0, y: 0, width: 100, height: 80)
        let result = ResizeEngine.resizedBounds(
            original: original,
            handle: .left,
            cumulativeDelta: .init(x: 150, y: 0),
            minimumSize: 10
        )
        XCTAssertEqual(result, CanvasRect(x: 90, y: 0, width: 10, height: 80))
        XCTAssertEqual(result.maxX, original.maxX)
    }

    func testTopLeftClampKeepsOppositeCornerFixed() {
        let original = CanvasRect(x: 20, y: 30, width: 100, height: 80)
        let result = ResizeEngine.resizedBounds(
            original: original,
            handle: .topLeft,
            cumulativeDelta: .init(x: 200, y: 200),
            minimumSize: 10
        )
        XCTAssertEqual(result, CanvasRect(x: 110, y: 100, width: 10, height: 10))
        XCTAssertEqual(result.maxX, original.maxX)
        XCTAssertEqual(result.maxY, original.maxY)
    }

    func testEdgeHandlesOnlyResizeTheirOwnAxis() {
        let original = CanvasRect(x: 20, y: 30, width: 100, height: 80)
        XCTAssertEqual(
            ResizeEngine.resizedBounds(
                original: original,
                handle: .right,
                cumulativeDelta: .init(x: 25, y: 999),
                minimumSize: 10
            ),
            CanvasRect(x: 20, y: 30, width: 125, height: 80)
        )
        XCTAssertEqual(
            ResizeEngine.resizedBounds(
                original: original,
                handle: .bottom,
                cumulativeDelta: .init(x: 999, y: 25),
                minimumSize: 10
            ),
            CanvasRect(x: 20, y: 30, width: 100, height: 105)
        )
    }

    func testGeometryKindsBoundsAndRenderPathsAreDerivedExhaustively() {
        let line = CanvasGeometry.line(.init(start: .init(x: 10, y: 20), end: .init(x: -5, y: 40)))
        XCTAssertEqual(line.kind, .line)
        XCTAssertEqual(line.bounds, CanvasRect(x: -5, y: 20, width: 15, height: 20))
        XCTAssertEqual(
            line.renderPath,
            CanvasPath(commands: [.move(.init(x: 10, y: 20)), .line(.init(x: -5, y: 40))])
        )

        let rectangle = CanvasGeometry.rectangle(.init(rect: .init(x: 2, y: 3, width: 40, height: 50)))
        XCTAssertEqual(rectangle.kind, .rectangle)
        XCTAssertEqual(rectangle.bounds, CanvasRect(x: 2, y: 3, width: 40, height: 50))
        XCTAssertEqual(rectangle.renderPath.commands.count, 5)

        let freehandStroke = inkStroke([
            .init(x: 1, y: 1),
            .init(x: 30, y: 5),
        ])
        let freehand = CanvasGeometry.freehand(freehandStroke)
        XCTAssertEqual(freehand.kind, .freehand)
        XCTAssertEqual(freehand.bounds, CanvasRect(x: 1, y: 1, width: 29, height: 4))
        XCTAssertEqual(
            freehand.renderPath,
            CanvasPath(commands: [.move(.init(x: 1, y: 1)), .line(.init(x: 30, y: 5))])
        )

        let text = CanvasGeometry.text(
            .init(
                frame: .init(x: 12, y: 34, width: 24, height: 12),
                text: "OAQS",
                font: .init(familyName: "Portable", pointSize: 10),
                color: .black
            )
        )
        XCTAssertEqual(text.kind, .text)
        XCTAssertEqual(text.bounds, CanvasRect(x: 12, y: 34, width: 24, height: 12))
        XCTAssertTrue(text.renderPath.commands.isEmpty)

        let arch = CanvasGeometry.arch(
            .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 50), sagitta: 25)
        )
        XCTAssertEqual(arch.kind, .arch)
        XCTAssertTrue(arch.bounds.isFinite)
        XCTAssertFalse(arch.renderPath.commands.isEmpty)
    }

    func testPathBoundsAreEmptySafeAndConservativelyIncludeCurveControls() {
        XCTAssertEqual(CanvasPath(commands: []).bounds, CanvasRect(x: 0, y: 0, width: 0, height: 0))

        let path = CanvasPath(commands: [
            .move(.init(x: 5, y: 10)),
            .cubic(
                control1: .init(x: -20, y: 30),
                control2: .init(x: 50, y: -40),
                end: .init(x: 25, y: 15)
            ),
        ])
        XCTAssertEqual(path.bounds, CanvasRect(x: -20, y: -40, width: 70, height: 70))
    }

    func testHitTestingUsesCanvasToleranceAndSuppliedTextBounds() {
        let line = CanvasGeometry.line(.init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0)))
        XCTAssertTrue(line.hitTest(.init(x: 50, y: 4), tolerance: 5, textBounds: nil))
        XCTAssertFalse(line.hitTest(.init(x: 50, y: 6), tolerance: 5, textBounds: nil))

        let rectangle = CanvasGeometry.rectangle(.init(rect: .init(x: 10, y: 20, width: 30, height: 40)))
        XCTAssertTrue(rectangle.hitTest(.init(x: 20, y: 30), tolerance: 0, textBounds: nil))
        XCTAssertTrue(rectangle.hitTest(.init(x: 8, y: 30), tolerance: 2, textBounds: nil))
        XCTAssertFalse(rectangle.hitTest(.init(x: 7, y: 30), tolerance: 2, textBounds: nil))

        let text = CanvasGeometry.text(
            .init(
                frame: .init(x: 0, y: 0, width: 24, height: 12),
                text: "wide",
                font: .init(familyName: "Portable", pointSize: 10),
                color: .black
            )
        )
        let measuredBounds = CanvasRect(x: 100, y: 200, width: 80, height: 25)
        XCTAssertTrue(text.hitTest(.init(x: 170, y: 210), tolerance: 0, textBounds: measuredBounds))
        XCTAssertFalse(text.hitTest(.init(x: 10, y: 5), tolerance: 0, textBounds: measuredBounds))
        XCTAssertFalse(text.hitTest(.init(x: 10, y: 5), tolerance: 0, textBounds: nil))
    }

    func testFreehandAndArchHitTestingFollowTheirRenderPaths() {
        let freehand = CanvasGeometry.freehand(
            inkStroke([.init(x: 0, y: 0), .init(x: 100, y: 100)])
        )
        XCTAssertTrue(freehand.hitTest(.init(x: 50, y: 52), tolerance: 2, textBounds: nil))
        XCTAssertFalse(freehand.hitTest(.init(x: 50, y: 54), tolerance: 2, textBounds: nil))

        let arch = CanvasGeometry.arch(
            .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: 25)
        )
        XCTAssertTrue(arch.hitTest(.init(x: 50, y: 25), tolerance: 1, textBounds: nil))
        XCTAssertFalse(arch.hitTest(.init(x: 50, y: 35), tolerance: 1, textBounds: nil))
    }

    func testLargeQuadraticHitTestingAdaptsToCanvasTolerance() {
        let quadratic = CanvasPath(commands: [
            .move(.init(x: 0, y: 0)),
            .quad(control: .init(x: 500_000, y: 1_000_000), end: .init(x: 1_000_000, y: 0)),
        ])

        XCTAssertTrue(
            quadratic.hitTest(
                .init(x: 510_000, y: 499_800),
                tolerance: 0.5
            )
        )
        XCTAssertTrue(quadratic.hitTest(.init(x: 0, y: 0), tolerance: 0))
        XCTAssertFalse(quadratic.hitTest(.init(x: 0, y: 0), tolerance: .nan))
    }

    func testLargeCubicHitTestingAdaptsToCanvasTolerance() {
        let cubic = CanvasPath(commands: [
            .move(.init(x: 0, y: 0)),
            .cubic(
                control1: .init(x: 0, y: 1_000_000),
                control2: .init(x: 1_000_000, y: 1_000_000),
                end: .init(x: 1_000_000, y: 0)
            ),
        ])

        XCTAssertTrue(
            cubic.hitTest(
                .init(x: 514_998, y: 749_700),
                tolerance: 0.5
            )
        )
    }

    func testQuadraticAndCubicInteriorPointsHitAtZeroTolerance() {
        let quadratic = CanvasPath(commands: [
            .move(.init(x: 0, y: 0)),
            .quad(control: .init(x: 50, y: 100), end: .init(x: 100, y: 0)),
        ])
        let cubic = CanvasPath(commands: [
            .move(.init(x: 0, y: 0)),
            .cubic(
                control1: .init(x: 0, y: 90),
                control2: .init(x: 90, y: 90),
                end: .init(x: 90, y: 0)
            ),
        ])

        XCTAssertTrue(quadratic.hitTest(.init(x: 50, y: 50), tolerance: 0))
        XCTAssertTrue(cubic.hitTest(.init(x: 45, y: 67.5), tolerance: 0))
    }


    func testMovedTranslatesGeometryPreservesIdentityAndAdvancesContentRevision() throws {
        let id = UUID()
        let element = CanvasElement(
            id: id,
            contentRevision: 7,
            geometry: .freehand(
                inkStroke([.init(x: 1, y: 2), .init(x: 7, y: 8)])
            )
        )

        let moved = try element.moved(by: .init(x: 10, y: -2))

        XCTAssertEqual(moved.id, id)
        XCTAssertEqual(moved.contentRevision, 8)
        XCTAssertEqual(moved.bounds, CanvasRect(x: 11, y: 0, width: 6, height: 6))
        XCTAssertEqual(element.bounds, CanvasRect(x: 1, y: 2, width: 6, height: 6))
    }

    func testMovedRevisionBoundaryIsTypedAndAtomic() throws {
        let movable = CanvasElement(
            id: UUID(),
            contentRevision: .max - 2,
            geometry: .rectangle(.init(rect: .init(x: 1, y: 2, width: 3, height: 4)))
        )
        let moved = try movable.moved(by: .init(x: 10, y: 20))
        XCTAssertEqual(moved.contentRevision, .max - 1)
        XCTAssertEqual(moved.bounds, .init(x: 11, y: 22, width: 3, height: 4))

        var exhausted = movable
        exhausted.contentRevision = .max - 1
        XCTAssertThrowsError(try exhausted.moved(by: .init(x: 10, y: 20))) { error in
            XCTAssertEqual(error as? CanvasGeometryError, .revisionOverflow)
        }
        assertSameElement(exhausted, as: {
            var expected = movable
            expected.contentRevision = .max - 1
            return expected
        }())
    }

    func testReplacingBoundsRevisionBoundaryIsTypedAndAtomic() throws {
        let resizable = CanvasElement(
            id: UUID(),
            contentRevision: .max - 2,
            geometry: .rectangle(.init(rect: .init(x: 1, y: 2, width: 3, height: 4)))
        )
        let resized = try resizable.replacingBounds(.init(x: 10, y: 20, width: 30, height: 40))
        XCTAssertEqual(resized.contentRevision, .max - 1)
        XCTAssertEqual(resized.bounds, .init(x: 10, y: 20, width: 30, height: 40))

        var exhausted = resizable
        exhausted.contentRevision = .max - 1
        XCTAssertThrowsError(
            try exhausted.replacingBounds(.init(x: 10, y: 20, width: 30, height: 40))
        ) { error in
            XCTAssertEqual(error as? CanvasGeometryError, .revisionOverflow)
        }
        assertSameElement(exhausted, as: {
            var expected = resizable
            expected.contentRevision = .max - 1
            return expected
        }())
    }

    func testReplacingBoundsPreservesIdentityAndIncrementsRevisionExactlyOnce() throws {
        let id = UUID()
        let original = CanvasElement.rectangle(
            id: id,
            rect: .init(x: 0, y: 0, width: 100, height: 80)
        )
        let resized = try ResizeEngine.resize(
            original: original,
            handle: .bottomRight,
            cumulativeDelta: .init(x: 100, y: 50),
            minimumSize: 10
        )

        XCTAssertEqual(resized.id, id)
        XCTAssertEqual(resized.contentRevision, original.contentRevision + 1)
        XCTAssertEqual(resized.bounds, CanvasRect(x: 0, y: 0, width: 200, height: 130))
        XCTAssertEqual(original.bounds, CanvasRect(x: 0, y: 0, width: 100, height: 80))
    }

    func testReplacingBoundsAffineMapsLineArchAndFreehand() throws {
        let line = CanvasElement(
            id: UUID(),
            geometry: .line(.init(start: .init(x: 10, y: 20), end: .init(x: 30, y: 40)))
        )
        XCTAssertEqual(
            try line.replacingBounds(.init(x: 100, y: 200, width: 40, height: 80)).bounds,
            CanvasRect(x: 100, y: 200, width: 40, height: 80)
        )

        let arch = CanvasElement(
            id: UUID(),
            geometry: .arch(.init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 0), sagitta: 25))
        )
        let resizedArch = try arch.replacingBounds(.init(x: 10, y: 20, width: 200, height: 100))
        XCTAssertEqual(resizedArch.bounds.x, 10, accuracy: 0.000_001)
        XCTAssertEqual(resizedArch.bounds.y, 20, accuracy: 0.000_001)
        XCTAssertEqual(resizedArch.bounds.width, 200, accuracy: 0.000_001)
        XCTAssertEqual(resizedArch.bounds.height, 100, accuracy: 0.000_001)

        let freehand = CanvasElement(
            id: UUID(),
            geometry: .freehand(
                inkStroke([.init(x: 0, y: 0), .init(x: 10, y: 20)])
            )
        )
        XCTAssertEqual(
            try freehand.replacingBounds(.init(x: 5, y: 10, width: 20, height: 60)).bounds,
            CanvasRect(x: 5, y: 10, width: 20, height: 60)
        )
    }

    func testFreehandTransformsPreserveWidthMode() throws {
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(.init(
                samples: [
                    .init(point: .init(x: 10, y: 20), pressure: 0.3),
                    .init(point: .init(x: 30, y: 40), pressure: 1),
                ],
                pressureEnabled: true,
                widthMode: .screenConstant
            )),
            style: .default
        )

        for transformed in [
            try element.moved(by: .init(x: 5, y: 6)),
            try element.replacingBounds(.init(x: 5, y: 10, width: 40, height: 60)),
        ] {
            guard case .freehand(let stroke) = transformed.geometry else {
                return XCTFail("Expected freehand geometry")
            }
            XCTAssertEqual(stroke.widthMode, .screenConstant)
        }
    }

    func testReplacingObliqueArchRejectsNonuniformScaling() {
        let arch = CanvasElement(
            id: UUID(),
            geometry: .arch(
                .init(start: .init(x: 0, y: 0), end: .init(x: 100, y: 50), sagitta: 25)
            )
        )

        XCTAssertThrowsError(
            try arch.replacingBounds(.init(x: 10, y: 20, width: 200, height: 100))
        ) { error in
            XCTAssertEqual(error as? CanvasGeometryError, .unsupportedResize(.arch))
        }
    }

    func testReplacingBoundsRejectsUnsafeOrInvalidGeometry() {
        let text = CanvasElement(
            id: UUID(),
            geometry: .text(
                .init(
                    frame: .init(x: 0, y: 0, width: 28.8, height: 14.4),
                    text: "OAQS",
                    font: .init(familyName: "Portable", pointSize: 12),
                    color: .black
                )
            )
        )
        XCTAssertEqual(
            try text.replacingBounds(.init(x: 0, y: 0, width: 100, height: 40)).bounds,
            CanvasRect(x: 0, y: 0, width: 100, height: 40)
        )

        let flatPath = CanvasElement(
            id: UUID(),
            geometry: .freehand(inkStroke([.init(x: 0, y: 0), .init(x: 10, y: 0)]))
        )
        XCTAssertThrowsError(try flatPath.replacingBounds(.init(x: 0, y: 0, width: 20, height: 10)))
        XCTAssertThrowsError(try flatPath.replacingBounds(.init(x: 0, y: 0, width: .infinity, height: 0)))
    }

    private func assertSameElement(
        _ actual: CanvasElement,
        as expected: CanvasElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.contentRevision, expected.contentRevision, file: file, line: line)
        XCTAssertEqual(actual.geometry, expected.geometry, file: file, line: line)
        XCTAssertEqual(actual.style, expected.style, file: file, line: line)
    }

    private func inkStroke(_ points: [CanvasPoint]) -> CanvasInkStroke {
        CanvasInkStroke(
            samples: points.map { CanvasInkSample(point: $0, pressure: 1) },
            pressureEnabled: false
        )
    }
}
