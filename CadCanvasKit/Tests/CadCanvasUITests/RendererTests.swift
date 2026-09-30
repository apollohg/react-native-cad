import CoreGraphics
import UIKit
import XCTest
import CadCanvasCore
@testable import CadCanvasUI

@MainActor
final class RendererTests: XCTestCase {
    func testBackendNeutralProtocolConsumesPreparedSceneInItsOwnedView() throws {
        let renderer = NeutralRenderer()
        let scene = try makeScene(elements: [line()])

        renderer.update(scene, in: renderer.view)

        XCTAssertTrue(renderer.scene?.geometry.first?.id == scene.geometry.first?.id)
    }

    func testCoreGraphicsRendererUpdatesOnlyViewsItCreated() throws {
        let rendererA = CoreGraphicsCanvasRenderer()
        let rendererB = CoreGraphicsCanvasRenderer()
        let renderView = try XCTUnwrap(rendererA.makeRenderView() as? CanvasRenderView)
        let first = try makeScene(elements: [line(id: UUID())])
        let second = try makeScene(elements: [line(id: UUID())])

        rendererB.update(second, in: renderView)
        XCTAssertNil(renderView.latestScene)

        rendererA.update(first, in: renderView)
        rendererB.update(second, in: renderView)

        XCTAssertEqual(renderView.latestScene?.geometry.map(\.id), first.geometry.map(\.id))
    }

    func testCanvasRenderViewCoalescesUpdatesAndRetainsOnlyLatestScene() throws {
        let renderer = CoreGraphicsCanvasRenderer()
        var redrawCount = 0
        let view = CanvasRenderView(renderer: renderer) { redrawCount += 1 }
        let first = try makeScene(elements: [line(id: UUID())])
        let second = try makeScene(elements: [line(id: UUID())])
        let third = try makeScene(elements: [line(id: UUID())])

        view.enqueue(first)
        view.enqueue(second)
        view.enqueue(third)

        XCTAssertEqual(redrawCount, 1)
        XCTAssertTrue(view.isRedrawScheduled)
        XCTAssertEqual(view.latestScene?.geometry.map(\.id), third.geometry.map(\.id))

        view.completeDisplayPass()
        view.enqueue(first)

        XCTAssertEqual(redrawCount, 2)
        XCTAssertEqual(view.latestScene?.geometry.map(\.id), first.geometry.map(\.id))
    }

    func testRendererIgnoresOrdinaryView() throws {
        let renderer = CoreGraphicsCanvasRenderer()
        let ordinaryView = UIView()

        renderer.update(try makeScene(elements: [line()]), in: ordinaryView)

        XCTAssertTrue(ordinaryView.subviews.isEmpty)
    }

    func testPreparedLineDrawsAtViewportTransformedPixels() throws {
        let renderer = CoreGraphicsCanvasRenderer()
        let viewport = try! CanvasViewport(
            zoom: 2,
            translation: .init(x: 10, y: 6),
            viewportSize: .init(width: 100, height: 100)
        )
        let scene = try makeScene(
            elements: [line(start: .init(x: 5, y: 10), end: .init(x: 35, y: 10), lineWidth: 2)],
            viewport: viewport,
            gridSpacing: 1_000
        )

        let image = try XCTUnwrap(renderer.makeBitmap(
            scene: scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 1
        ))

        let transformedRow = image.height - 1 - 26
        XCTAssertTrue(pixelDiffersFromBackground(
            in: image,
            x: 20,
            y: transformedRow,
            background: scene.theme.background
        ))
        XCTAssertTrue(pixelDiffersFromBackground(
            in: image,
            x: 80,
            y: transformedRow,
            background: scene.theme.background
        ))
        XCTAssertFalse(pixelDiffersFromBackground(
            in: image,
            x: 20,
            y: image.height - 1 - 40,
            background: scene.theme.background
        ))
    }

    func testPreparedSceneNeverEmitsTextElementCommands() throws {
        let geometry = line()
        let text = textElement()
        let presentation = try makePresentation(
            elements: [geometry, text],
            selectedID: text.id
        )
        let scene = presentation.scene

        let commands = CoreGraphicsCanvasRenderer().renderCommands(
            scene: scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )

        XCTAssertEqual(commands.compactMap(\.elementID), [geometry.id])
        XCTAssertFalse(commands.compactMap(\.elementID).contains(text.id))
        XCTAssertEqual(presentation.textDescriptors.map(\.id), [text.id])
        XCTAssertTrue(try XCTUnwrap(presentation.textDescriptors.first).isSelected)
        XCTAssertNil(scene.selectionBounds)
        XCTAssertTrue(commands.compactMap(\.selectionBounds).isEmpty)
    }

    func testViewportOnlyUpdateReusesImmutableBackendPath() throws {
        let renderer = CoreGraphicsCanvasRenderer()
        let preparer = CanvasScenePreparer()
        let element = line(contentRevision: 7)
        let first = try makeScene(elements: [element], preparer: preparer)
        var panned = try! CanvasViewport.identity(size: .init(width: 100, height: 100))
        panned = try! panned.panned(byScreen: .init(x: 12, y: 8))
        let second = try makeScene(elements: [element], viewport: panned, preparer: preparer)

        XCTAssertEqual(
            first.geometry.first?.resourceIdentity,
            second.geometry.first?.resourceIdentity
        )

        _ = renderer.renderCommands(
            scene: first,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )
        _ = renderer.renderCommands(
            scene: second,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )

        XCTAssertEqual(renderer.pathBuildCount, 1)
        XCTAssertEqual(renderer.cachedPathCount, 1)
    }

    func testChangedImmutableKeyBuildsOnceAndPrunesAbsentKey() throws {
        let renderer = CoreGraphicsCanvasRenderer()
        let id = UUID()
        let first = try makeScene(elements: [line(id: id, contentRevision: 0)])
        let second = try makeScene(elements: [line(id: id, contentRevision: 1)])

        _ = renderer.renderCommands(
            scene: first,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )
        _ = renderer.renderCommands(
            scene: second,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )

        XCTAssertEqual(renderer.pathBuildCount, 2)
        XCTAssertEqual(renderer.cachedPathCount, 1)
    }

    func testAppendOnlyPathKeepsObjectIdentityAndAppendsOnlyNewPoints() throws {
        let renderer = CoreGraphicsCanvasRenderer()
        let polyline = CanvasPreparedInk(points: [
            .init(x: 10, y: 10),
            .init(x: 20, y: 20),
        ])
        let first = makeAppendOnlyScene(polyline)

        _ = renderer.renderCommands(
            scene: first,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )
        polyline.append([.init(x: 30, y: 10)])
        let second = makeAppendOnlyScene(polyline)
        _ = renderer.renderCommands(
            scene: second,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )

        XCTAssertEqual(renderer.pathBuildCount, 1)
        XCTAssertEqual(renderer.cachedPathCount, 1)
        XCTAssertEqual(renderer.cachedPointCount(for: polyline), 3)
    }

    func testUpdatePrunesBackendPathsAbsentFromLatestScene() throws {
        let renderer = CoreGraphicsCanvasRenderer()
        let renderView = renderer.makeRenderView()
        let populated = try makeScene(elements: [line()])
        let empty = try makeScene(elements: [])
        _ = renderer.renderCommands(
            scene: populated,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )
        XCTAssertEqual(renderer.cachedPathCount, 1)

        renderer.update(empty, in: renderView)

        XCTAssertEqual(renderer.cachedPathCount, 0)
    }

    func testInvalidDrawStillPrunesPathsAbsentFromCurrentScene() throws {
        let renderer = CoreGraphicsCanvasRenderer()
        _ = renderer.renderCommands(
            scene: try makeScene(elements: [line()]),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )
        XCTAssertEqual(renderer.cachedPathCount, 1)
        let context = try XCTUnwrap(makeContext(width: 100, height: 100))

        renderer.draw(
            scene: try makeScene(elements: []),
            in: context,
            bounds: CGRect(x: 0, y: 0, width: 0, height: 100),
            displayScale: 2
        )

        XCTAssertEqual(renderer.cachedPathCount, 0)
    }

    func testClearCacheRemovesAllBackendPaths() throws {
        let renderer = CoreGraphicsCanvasRenderer()
        _ = renderer.renderCommands(
            scene: try makeScene(elements: [line()]),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )
        XCTAssertEqual(renderer.cachedPathCount, 1)

        renderer.clearCache()

        XCTAssertEqual(renderer.cachedPathCount, 0)
    }

    func testScreenMetricsRemainConstantAcrossZoomUnderModelTransform() throws {
        let selected = line(lineWidth: 6)
        let viewport = try! CanvasViewport(
            zoom: 3,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 100, height: 100)
        )
        let scene = try makeScene(elements: [selected], viewport: viewport, selectedID: selected.id)

        let commands = CoreGraphicsCanvasRenderer().renderCommands(
            scene: scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )

        let element = try XCTUnwrap(commands.first { $0.elementID == selected.id })
        let selection = try XCTUnwrap(commands.first { $0.selectionBounds != nil })
        XCTAssertEqual(element.canvasLineWidth * viewport.zoom, 6, accuracy: 0.000_001)
        XCTAssertEqual(
            selection.canvasLineWidth * viewport.zoom,
            scene.theme.selectionLineWidth,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            selection.canvasHandleSize * viewport.zoom,
            scene.theme.handleSize,
            accuracy: 0.000_001
        )
        XCTAssertTrue(commands.filter(\.isGrid).allSatisfy {
            abs($0.canvasLineWidth * viewport.zoom - scene.theme.gridLineWidth) < 0.000_001
        })
    }

    func testFreehandWidthModeControlsCoreGraphicsCanvasWidthAtZoom() throws {
        let viewport = try CanvasViewport(
            zoom: 4,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 100, height: 100)
        )
        func command(widthMode: CanvasInkWidthMode) throws -> CoreGraphicsRenderCommand {
            let ink = CanvasPreparedInk(
                confirmedSamples: [
                    .init(point: .init(x: 10, y: 20), pressure: 0.3),
                    .init(point: .init(x: 80, y: 20), pressure: 0.3),
                ],
                pressureEnabled: true,
                widthMode: widthMode
            )
            return try XCTUnwrap(CoreGraphicsCanvasRenderer().renderCommands(
                scene: makeInkScene(ink: ink, lineWidth: 1, viewport: viewport),
                bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                displayScale: 2
            ).firstElement)
        }

        XCTAssertEqual(try command(widthMode: .canvasScaled).canvasLineWidth, 1)
        XCTAssertEqual(try command(widthMode: .screenConstant).canvasLineWidth, 0.25)
    }

    func testCoreGraphicsInkRefinesCurvesAtTwentyTimesZoom() throws {
        let points: [CanvasPoint] = [
            .init(x: 0, y: 0),
            .init(x: 20, y: 15),
            .init(x: 40, y: -15),
            .init(x: 60, y: 0),
        ]
        let pressures = [0.0, 0.3, 1.0, 0.3]
        let snapshot = inkSnapshot(
            points: points,
            pressures: pressures,
            pressureEnabled: true
        )

        let oneX = try CanvasInkOutlineBuilder.makePath(
            snapshot: snapshot,
            viewportScale: 2,
            lineWidth: 1
        )
        let twentyX = try CanvasInkOutlineBuilder.makePath(
            snapshot: snapshot,
            viewportScale: 40,
            lineWidth: 1
        )
        let centerlineBounds = try CanvasInkCurve.bounds(stroke: .init(
            samples: zip(points, pressures).map {
                CanvasInkSample(point: $0.0, pressure: $0.1)
            },
            pressureEnabled: true
        ))
        let maximumRadius = CanvasInkCurve.maximumWidthFactor(pressureEnabled: true) / 2

        XCTAssertGreaterThan(
            closedSubpathCount(in: twentyX),
            closedSubpathCount(in: oneX)
        )
        XCTAssertGreaterThanOrEqual(twentyX.boundingBox.minX, centerlineBounds.minX - maximumRadius)
        XCTAssertLessThanOrEqual(twentyX.boundingBox.maxX, centerlineBounds.maxX + maximumRadius)
        XCTAssertGreaterThanOrEqual(twentyX.boundingBox.minY, centerlineBounds.minY - maximumRadius)
        XCTAssertLessThanOrEqual(twentyX.boundingBox.maxY, centerlineBounds.maxY + maximumRadius)
    }

    func testSelectionGridAndGuidesStayInModelSpace() throws {
        let selected = line(start: .init(x: 10, y: 20), end: .init(x: 30, y: 40))
        let scene = try makeScene(
            elements: [selected],
            selectedID: selected.id,
            guides: [.vertical(canvasX: 25), .horizontal(canvasY: 35)]
        )

        let commands = CoreGraphicsCanvasRenderer().renderCommands(
            scene: scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )

        let outset = scene.theme.selectionOutset / scene.viewport.zoom
        XCTAssertEqual(commands.compactMap(\.selectionBounds), [.init(
            x: selected.bounds.x - outset, y: selected.bounds.y - outset,
            width: selected.bounds.width + outset * 2, height: selected.bounds.height + outset * 2
        )])
        XCTAssertEqual(commands.compactMap(\.snapGuide), scene.guides)
        XCTAssertFalse(commands.filter(\.isGrid).isEmpty)
    }

    func testFreehandPolylineProducesBitmapPixels() throws {
        let points = [
            CanvasPoint(x: 10, y: 10),
            CanvasPoint(x: 30, y: 10),
            CanvasPoint(x: 40, y: 30),
            CanvasPoint(x: 50, y: 10),
            CanvasPoint(x: 60, y: 0),
            CanvasPoint(x: 70, y: 20),
            CanvasPoint(x: 80, y: 10),
        ]
        let element = CanvasElement(
            id: UUID(),
            geometry: .freehand(.init(
                samples: points.map { .init(point: $0, pressure: 1) },
                pressureEnabled: true
            )),
            style: .init(
                stroke: .black,
                fill: CanvasColor(red: 1, green: 0, blue: 0),
                lineWidth: 2
            )
        )
        let scene = try makeScene(elements: [element], gridSpacing: 1_000)

        let image = try XCTUnwrap(CoreGraphicsCanvasRenderer().makeBitmap(
            scene: scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        ))

        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 200)
        XCTAssertTrue(imageContainsNonBackgroundPixel(image, background: scene.theme.background))
    }

    func testInkOutlineUsesExactExternalTangentsForUnequalRadii() throws {
        let snapshot = CanvasPreparedInkSnapshot(
            confirmed: [
                .init(point: .init(x: 20, y: 30), pressure: 0),
                .init(point: .init(x: 60, y: 30), pressure: 1),
            ],
            predicted: [],
            pressureEnabled: true,
            finalizedConfirmedSampleCount: 2
        )

        let path = try CanvasInkOutlineBuilder.makePath(
            snapshot: snapshot,
            viewportScale: 1,
            lineWidth: 20
        )
        let hull = firstClosedPolygon(in: path)
        let flattened = try CanvasInkCurve.flatten(
            stroke: .init(samples: snapshot.confirmed, pressureEnabled: true),
            maximumError: 0.25,
            maximumWidthError: 0.025
        )
        let start = flattened[0]
        let end = flattened[1]
        let startRadius = start.widthFactor * 10
        let endRadius = end.widthFactor * 10
        let distance = end.point.x - start.point.x
        let normalX = -(endRadius - startRadius) / distance
        let normalY = sqrt(1 - normalX * normalX)
        let expected = [
            CGPoint(x: start.point.x + normalX * startRadius, y: 30 - normalY * startRadius),
            CGPoint(x: end.point.x + normalX * endRadius, y: 30 - normalY * endRadius),
            CGPoint(x: end.point.x + normalX * endRadius, y: 30 + normalY * endRadius),
            CGPoint(x: start.point.x + normalX * startRadius, y: 30 + normalY * startRadius),
        ]

        XCTAssertEqual(hull.count, 4)
        for (actual, expected) in zip(hull, expected) {
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.000_001)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.000_001)
        }
        XCTAssertNotEqual(hull[0].x, 20, "Unequal circles must not use perpendicular offsets")
        XCTAssertNotEqual(hull[1].x, end.point.x, "Unequal circles must not use perpendicular offsets")
    }

    func testLowPressureVerticalInkHasOnePhysicalPixelOutlineInBothDirections() throws {
        for points in [
            [CanvasPoint(x: 40, y: 20), CanvasPoint(x: 40, y: 80)],
            [CanvasPoint(x: 40, y: 80), CanvasPoint(x: 40, y: 20)],
        ] {
            let path = try CanvasInkOutlineBuilder.makePath(
                snapshot: inkSnapshot(
                    points: points,
                    pressures: [0, 0],
                    pressureEnabled: true
                ),
                viewportScale: 2,
                lineWidth: 1
            )

            XCTAssertEqual(
                path.boundingBoxOfPath.width * 2,
                1,
                accuracy: 0.000_001
            )
        }
    }

    func testFirmPressureInkUsesOnePointSevenFiveNominalWidth() throws {
        let path = try CanvasInkOutlineBuilder.makePath(
            snapshot: inkSnapshot(
                points: [.init(x: 40, y: 20), .init(x: 40, y: 80)],
                pressures: [1, 1],
                pressureEnabled: true
            ),
            viewportScale: 2,
            lineWidth: 1
        )

        XCTAssertEqual(path.boundingBoxOfPath.width, 1.75, accuracy: 1e-9)
    }

    func testInkOutlineHullAndEllipsesUseTheSameSignedOrientation() throws {
        let path = try CanvasInkOutlineBuilder.makePath(
            snapshot: inkSnapshot(
                points: [.init(x: 20, y: 30), .init(x: 60, y: 30)],
                pressureEnabled: false
            ),
            viewportScale: 1,
            lineWidth: 20
        )
        let orientations = closedSubpaths(in: path).map(signedArea)

        XCTAssertEqual(orientations.count, 3)
        XCTAssertTrue(orientations.allSatisfy { $0 > 0 }, "All compound components must wind like Core Graphics ellipses")
    }

    func testUniformCapsuleInteriorHasNoNonzeroWindingCancellationHoles() throws {
        let ink = CanvasPreparedInk(points: [.init(x: 20, y: 50), .init(x: 60, y: 50)])
        let scene = makeInkScene(ink: ink, lineWidth: 20)
        let image = try XCTUnwrap(CoreGraphicsCanvasRenderer().makeBitmap(
            scene: scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        ))

        for canvasX in 21...59 {
            for canvasY in 42...58 {
                XCTAssertTrue(pixelDiffersFromBackground(
                    in: image,
                    x: canvasX * 2,
                    y: image.height - 1 - canvasY * 2,
                    background: scene.theme.background
                ), "Cancellation hole at (\(canvasX), \(canvasY))")
            }
        }
    }

    func testInkOutlineLimitsTaperBeforeLargerCircleContainsSmaller() throws {
        let snapshot = CanvasPreparedInkSnapshot(
            confirmed: [
                .init(point: .init(x: 20, y: 30), pressure: 0),
                .init(point: .init(x: 21, y: 30), pressure: 1),
            ],
            predicted: [],
            pressureEnabled: true,
            finalizedConfirmedSampleCount: 2
        )

        let path = try CanvasInkOutlineBuilder.makePath(
            snapshot: snapshot,
            viewportScale: 1,
            lineWidth: 20
        )
        let flattened = try CanvasInkCurve.flatten(
            stroke: .init(samples: snapshot.confirmed, pressureEnabled: true),
            maximumError: 0.25,
            maximumWidthError: 0.025
        )
        let visible = try CanvasInkVisibilityPolicy.apply(
            to: flattened,
            lineWidth: 20,
            pixelsPerCanvasUnit: 1,
            pressureEnabled: true
        )
        let limited = CanvasInkTaperLimiter.limit(visible, lineWidth: 20)

        XCTAssertEqual(closedSubpathCount(in: path), limited.count * 2 - 1)
    }

    func testSingleSampleAndPressureDisabledInkHaveRoundUniformBounds() throws {
        let dot = try CanvasInkOutlineBuilder.makePath(
            snapshot: inkSnapshot(points: [.init(x: 20, y: 30)], pressureEnabled: false),
            viewportScale: 1,
            lineWidth: 10
        )
        let uniform = try CanvasInkOutlineBuilder.makePath(
            snapshot: inkSnapshot(
                points: [.init(x: 10, y: 20), .init(x: 50, y: 20)],
                pressures: [0, 1],
                pressureEnabled: false
            ),
            viewportScale: 1,
            lineWidth: 10
        )

        XCTAssertEqual(dot.boundingBoxOfPath, CGRect(x: 15, y: 25, width: 10, height: 10))
        XCTAssertEqual(uniform.boundingBoxOfPath, CGRect(x: 5, y: 15, width: 50, height: 10))
    }

    func testVariableInkWidthsStayWithinOnePhysicalPixelAtOneTwoAndFourX() throws {
        let samples = (0..<9).map { index in
            CanvasInkSample(
                point: .init(x: Double(20 + index * 20), y: 50),
                pressure: [0, 0, 0, 1, 1, 1, 0, 0, 0][index]
            )
        }
        let scene = makeInkScene(
            ink: CanvasPreparedInk(
                confirmedSamples: samples,
                predictedSamples: [],
                pressureEnabled: true,
                isFinalized: true
            ),
            lineWidth: 20,
            viewport: try! .identity(size: .init(width: 200, height: 100))
        )

        for scale in [1.0, 2.0, 4.0] {
            let image = try XCTUnwrap(CoreGraphicsCanvasRenderer().makeBitmap(
                scene: scene,
                bounds: CGRect(x: 0, y: 0, width: 200, height: 100),
                displayScale: scale
            ))
            XCTAssertEqual(
                verticalInkSpan(in: image, canvasX: 20, displayScale: scale),
                4 * scale,
                accuracy: 1
            )
            XCTAssertEqual(
                verticalInkSpan(in: image, canvasX: 100, displayScale: scale),
                35 * scale,
                accuracy: 1
            )
            XCTAssertEqual(
                verticalInkSpan(in: image, canvasX: 180, displayScale: scale),
                4 * scale,
                accuracy: 1
            )
        }
    }

    func testTranslucentUniformInkAppliesSourceOverOnlyOnceAtSelfIntersection() throws {
        let ink = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: .init(x: 20, y: 50), pressure: 1),
                .init(point: .init(x: 80, y: 50), pressure: 1),
                .init(point: .init(x: 50, y: 20), pressure: 1),
                .init(point: .init(x: 50, y: 80), pressure: 1),
                .init(point: .init(x: 20, y: 50), pressure: 1),
            ],
            pressureEnabled: false
        )
        let scene = makeInkScene(
            ink: ink,
            lineWidth: 16,
            stroke: CanvasColor(red: 0, green: 0, blue: 0, alpha: 0.5),
            background: CanvasColor(red: 0, green: 0, blue: 0, alpha: 0)
        )

        let image = try XCTUnwrap(CoreGraphicsCanvasRenderer().makeBitmap(
            scene: scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        ))

        XCTAssertEqual(pixelAlpha(in: image, x: 40, canvasY: 100), 128, accuracy: 2)
    }

    func testUniformInkUsesCenterlineStrokeAndConservativePhysicalScaleBuckets() throws {
        let renderer = CoreGraphicsCanvasRenderer()
        let ink = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: .init(x: 10, y: 20), pressure: 1),
                .init(point: .init(x: 30, y: 40), pressure: 1),
                .init(point: .init(x: 60, y: 20), pressure: 1),
            ],
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: true
        )
        let scene = makeInkScene(ink: ink, lineWidth: 10)

        let first = try XCTUnwrap(renderer.renderCommands(
            scene: scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 1.1
        ).firstElement)
        guard case .element(_, _, _, let firstFill, let firstLineWidth) = first else {
            return XCTFail("Expected an element command")
        }
        XCTAssertNil(firstFill)
        XCTAssertEqual(firstLineWidth, 17.5)
        XCTAssertEqual(renderer.inkOutlineBuildCount, 1)

        let exactBoundary = try XCTUnwrap(renderer.renderCommands(
            scene: scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        ).firstElement)
        XCTAssertEqual(
            renderer.inkOutlineBuildCount,
            1,
            "The bucket's inclusive upper boundary must reuse one centerline"
        )
        XCTAssertEqual(exactBoundary.canvasLineWidth, 17.5)

        let changedWidth = makeInkScene(ink: ink, lineWidth: 12)
        let widthUpdated = try XCTUnwrap(renderer.renderCommands(
            scene: changedWidth,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        ).firstElement)
        XCTAssertEqual(renderer.inkOutlineBuildCount, 1)
        XCTAssertEqual(widthUpdated.canvasLineWidth, 21)

        _ = renderer.renderCommands(
            scene: scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2.0.nextUp
        )
        XCTAssertEqual(renderer.inkOutlineBuildCount, 2)
    }

    func testUniformInkCenterlineMatchesLegacyCompoundWithinOnePhysicalPixel() throws {
        let snapshot = CanvasPreparedInkSnapshot(
            confirmed: [
                .init(point: .init(x: 12, y: 58), pressure: 1),
                .init(point: .init(x: 30, y: 24), pressure: 1),
                .init(point: .init(x: 52, y: 62), pressure: 1),
                .init(point: .init(x: 76, y: 30), pressure: 1),
            ],
            predicted: [],
            pressureEnabled: true,
            finalizedConfirmedSampleCount: 4
        )
        let ink = CanvasPreparedInk(
            confirmedSamples: snapshot.confirmed,
            predictedSamples: snapshot.predicted,
            pressureEnabled: snapshot.pressureEnabled,
            isFinalized: true
        )
        let bounds = CGRect(x: 0, y: 0, width: 90, height: 80)
        let scene = makeInkScene(
            ink: ink,
            lineWidth: 12,
            viewport: try! .identity(size: .init(width: 90, height: 80))
        )

        for scale in [1.0, 2.0, 4.0] {
            let fastPath = try XCTUnwrap(CoreGraphicsCanvasRenderer().makeBitmap(
                scene: scene,
                bounds: bounds,
                displayScale: scale
            ))
            let compoundOracle = try XCTUnwrap(makeLegacyCompoundInkBitmap(
                snapshot: snapshot,
                lineWidth: 12,
                bounds: bounds,
                displayScale: scale
            ))
            assertForegroundMasksWithinOnePixel(
                fastPath,
                compoundOracle,
                file: #filePath,
                line: #line
            )
        }
    }

    func testUniformInkRejectsOverflowingPhysicalScaleBucket() {
        let renderer = CoreGraphicsCanvasRenderer()
        let ink = CanvasPreparedInk(points: [.init(x: 10, y: 20), .init(x: 40, y: 20)])
        let scene = makeInkScene(
            ink: ink,
            lineWidth: 10,
            viewport: try! CanvasViewport(
                zoom: 2,
                translation: .init(x: 0, y: 0),
                viewportSize: .init(width: 100, height: 100)
            )
        )

        let commands = renderer.renderCommands(
            scene: scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: Double.greatestFiniteMagnitude
        )

        XCTAssertNil(commands.firstElement)
        XCTAssertEqual(renderer.inkOutlineBuildCount, 0)
    }

    func testInkOutlineCacheInvalidatesForGenerationAndPhysicalScaleButNotPan() {
        let renderer = CoreGraphicsCanvasRenderer()
        let ink = CanvasPreparedInk(points: [.init(x: 10, y: 20), .init(x: 40, y: 20)])
        let scene = makeInkScene(ink: ink, lineWidth: 10)
        _ = renderer.renderCommands(
            scene: scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )
        var pannedViewport = scene.viewport
        pannedViewport = try! pannedViewport.panned(byScreen: .init(x: 8, y: 3))
        let panned = replacingViewport(in: scene, with: pannedViewport)
        _ = renderer.renderCommands(
            scene: panned,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )
        XCTAssertEqual(renderer.inkOutlineBuildCount, 1)

        ink.replacePredicted([.init(point: .init(x: 70, y: 20), pressure: 1)])
        _ = renderer.renderCommands(
            scene: panned,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )
        XCTAssertEqual(renderer.inkOutlineBuildCount, 2)

        _ = renderer.renderCommands(
            scene: panned,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 4
        )
        XCTAssertEqual(renderer.inkOutlineBuildCount, 3)
        XCTAssertEqual(renderer.cachedPathCount, 1)
    }

    func testCompoundInkOutlineCacheIncludesLineWidthAndPreparedResourceIdentity() {
        let renderer = CoreGraphicsCanvasRenderer()
        let samples = [
            CanvasInkSample(point: .init(x: 10, y: 20), pressure: 0),
            CanvasInkSample(point: .init(x: 40, y: 20), pressure: 1),
        ]
        let ink = CanvasPreparedInk(
            confirmedSamples: samples,
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: true
        )
        let first = makeInkScene(ink: ink, lineWidth: 10)
        _ = renderer.renderCommands(
            scene: first,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )

        let changedWidth = makeInkScene(ink: ink, lineWidth: 12)
        _ = renderer.renderCommands(
            scene: changedWidth,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )
        XCTAssertEqual(renderer.inkOutlineBuildCount, 2)

        let rebuiltResource = makeInkScene(
            ink: CanvasPreparedInk(
                confirmedSamples: samples,
                predictedSamples: [],
                pressureEnabled: true,
                isFinalized: true
            ),
            lineWidth: 12
        )
        _ = renderer.renderCommands(
            scene: rebuiltResource,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 2
        )
        XCTAssertEqual(renderer.inkOutlineBuildCount, 3)
        XCTAssertEqual(renderer.cachedPathCount, 1)
    }

    func testInkFinalRekeyUsesOneIndexedLookupWithManyCachedStrokes() {
        let renderer = CoreGraphicsCanvasRenderer()
        let inks = (0..<128).map { index in
            CanvasPreparedInk(points: [
                .init(x: Double(index), y: 10),
                .init(x: Double(index + 1), y: 11),
            ])
        }
        let populated = makeInkScene(inks: inks, lineWidth: 4)
        _ = renderer.renderCommands(
            scene: populated,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            displayScale: 2
        )
        let buildsBeforeRekey = renderer.inkOutlineBuildCount
        let probesBeforeRekey = renderer.inkSourceIndexProbeCount
        let rekeyed = makeInkScene(ink: inks[64], lineWidth: 4)

        _ = renderer.renderCommands(
            scene: rekeyed,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            displayScale: 2
        )

        XCTAssertEqual(renderer.inkOutlineBuildCount, buildsBeforeRekey)
        XCTAssertEqual(renderer.inkSourceIndexProbeCount - probesBeforeRekey, 1)
        XCTAssertEqual(renderer.cachedPathCount, 1)
    }

    func testFortyTwoPointHandwritingRendersSmoothlyAtOneTwoAndFourXZoom() throws {
        var samples: [CanvasInkSample] = []
        for index in 0..<42 {
            let parameter = Double(index)
            let point = CanvasPoint(
                x: 5 + parameter,
                y: 18 + sin(parameter * 0.47) * 5
            )
            let pressureStep = Double((index * 7) % 11) / 10
            samples.append(CanvasInkSample(
                point: point,
                pressure: 0.2 + 0.8 * pressureStep
            ))
        }
        let ink = CanvasPreparedInk(
            confirmedSamples: samples,
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: true
        )

        for zoom in [1.0, 2.0, 4.0] {
            let scene = makeInkScene(
                ink: ink,
                lineWidth: 12,
                viewport: try! CanvasViewport(
                    zoom: zoom,
                    translation: .init(x: 0, y: 0),
                    viewportSize: .init(width: 200, height: 120)
                )
            )
            let image = try XCTUnwrap(CoreGraphicsCanvasRenderer().makeBitmap(
                scene: scene,
                bounds: CGRect(x: 0, y: 0, width: 200, height: 120),
                displayScale: 1
            ))
            for sample in samples.enumerated() where sample.offset.isMultiple(of: 7) {
                XCTAssertTrue(neighborhoodDiffersFromBackground(
                    in: image,
                    x: Int((sample.element.point.x * zoom).rounded()),
                    y: image.height - 1 - Int((sample.element.point.y * zoom).rounded()),
                    background: scene.theme.background
                ), "Missing sample \(sample.offset) at \(zoom)x")
            }
        }
    }

    func testFlatteningAboveTwoHundredFiftyThousandXKeepsQuarterPixelError() throws {
        let viewportScale = 300_000.0
        let strictError = 0.25 / viewportScale
        var selected: (samples: [CanvasInkSample], strictCount: Int, flooredCount: Int)?
        for step in 1...2_000 {
            let amplitude = pow(1.01, Double(step - 1)) * 0.000_001
            let samples = [
                CanvasInkSample(point: .init(x: 0, y: 0), pressure: 1),
                CanvasInkSample(point: .init(x: 1, y: amplitude), pressure: 1),
                CanvasInkSample(point: .init(x: 2, y: -amplitude), pressure: 1),
                CanvasInkSample(point: .init(x: 3, y: 0), pressure: 1),
            ]
            let stroke = CanvasInkStroke(samples: samples, pressureEnabled: false)
            let strict = try CanvasInkCurve.flatten(stroke: stroke, maximumError: strictError)
            let floored = try CanvasInkCurve.flatten(stroke: stroke, maximumError: 1e-6)
            if strict.count > floored.count {
                selected = (samples, strict.count, floored.count)
                break
            }
        }
        let fixture = try XCTUnwrap(selected, "Fixture must distinguish strict tolerance from the old floor")
        let path = try CanvasInkOutlineBuilder.makePath(
            snapshot: CanvasPreparedInkSnapshot(
                confirmed: fixture.samples,
                predicted: [],
                pressureEnabled: false,
                finalizedConfirmedSampleCount: fixture.samples.count
            ),
            viewportScale: viewportScale,
            lineWidth: 0.000_000_001
        )

        XCTAssertGreaterThan(fixture.strictCount, fixture.flooredCount)
        XCTAssertEqual(closedSubpathCount(in: path), fixture.strictCount * 2 - 1)
    }

    func testUnsatisfiableExtremeFlatteningPropagatesTypedCurveFailure() {
        let snapshot = inkSnapshot(
            points: [
                .init(x: 0, y: 0),
                .init(x: 1, y: 1),
                .init(x: 2, y: -1),
                .init(x: 3, y: 0),
            ],
            pressureEnabled: false
        )

        XCTAssertThrowsError(try CanvasInkOutlineBuilder.makePath(
            snapshot: snapshot,
            viewportScale: .greatestFiniteMagnitude,
            lineWidth: 1
        )) { error in
            XCTAssertEqual(error as? CanvasInkCurveError, .outputLimitExceeded)
        }
    }

    func testReplacingPredictionsRemovesOldPredictedPixels() throws {
        let renderer = CoreGraphicsCanvasRenderer()
        let ink = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: .init(x: 20, y: 50), pressure: 1),
                .init(point: .init(x: 40, y: 50), pressure: 1),
            ],
            predictedSamples: [.init(point: .init(x: 80, y: 50), pressure: 1)],
            pressureEnabled: false,
            isFinalized: false
        )
        let scene = makeInkScene(ink: ink, lineWidth: 10)
        let predicted = try XCTUnwrap(renderer.makeBitmap(
            scene: scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 1
        ))
        XCTAssertTrue(pixelDiffersFromBackground(
            in: predicted,
            x: 80,
            y: predicted.height - 1 - 50,
            background: scene.theme.background
        ))

        ink.replacePredicted([])
        let replaced = try XCTUnwrap(renderer.makeBitmap(
            scene: scene,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 1
        ))
        XCTAssertFalse(pixelDiffersFromBackground(
            in: replaced,
            x: 80,
            y: replaced.height - 1 - 50,
            background: scene.theme.background
        ))
    }

    func testInvalidBoundsAndDisplayScaleAreRejected() throws {
        let renderer = CoreGraphicsCanvasRenderer()
        let scene = try makeScene(elements: [line()])
        let invalidBounds = [
            CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: 0),
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
        ]

        for bounds in invalidBounds {
            XCTAssertTrue(renderer.renderCommands(scene: scene, bounds: bounds, displayScale: 2).isEmpty)
            XCTAssertNil(renderer.makeBitmap(scene: scene, bounds: bounds, displayScale: 2))
        }
        for scale in [0, -1, Double.leastNonzeroMagnitude, .nan, .infinity] {
            XCTAssertTrue(renderer.renderCommands(
                scene: scene,
                bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                displayScale: scale
            ).isEmpty)
            XCTAssertNil(renderer.makeBitmap(
                scene: scene,
                bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                displayScale: scale
            ))
        }
    }

    func testDrawRestoresCallerGraphicsState() throws {
        let renderer = CoreGraphicsCanvasRenderer()
        let scene = try makeScene(elements: [line()])
        let context = try XCTUnwrap(makeContext(width: 100, height: 100))
        context.translateBy(x: 7, y: 11)
        let originalTransform = context.ctm

        renderer.draw(
            scene: scene,
            in: context,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayScale: 1
        )

        XCTAssertEqual(context.ctm, originalTransform)
    }
}

@MainActor
private final class NeutralRenderer: CanvasRenderer {
    let view = UIView()
    private(set) var scene: CanvasPreparedScene?

    func makeRenderView() -> UIView { view }

    func update(_ scene: CanvasPreparedScene, in renderView: UIView) {
        guard renderView === view else { return }
        self.scene = scene
    }
}

@MainActor
private extension RendererTests {
    func makePresentation(
        elements: [CanvasElement],
        viewport: CanvasViewport = try! .identity(size: .init(width: 100, height: 100)),
        selectedID: UUID? = nil,
        guides: [SnapGuide] = [],
        gridSpacing: Double = 25,
        preparer: CanvasScenePreparer = CanvasScenePreparer()
    ) throws -> CanvasPreparedPresentation {
        try preparer.prepare(
            document: .init(elements: elements),
            preview: nil,
            viewport: viewport,
            selectedElementID: selectedID,
            editingTextIDs: [],
            guides: guides,
            gridSpacing: gridSpacing,
            theme: Self.theme()
        )
    }

    func makeScene(
        elements: [CanvasElement],
        viewport: CanvasViewport = try! .identity(size: .init(width: 100, height: 100)),
        selectedID: UUID? = nil,
        guides: [SnapGuide] = [],
        gridSpacing: Double = 25,
        preparer: CanvasScenePreparer = CanvasScenePreparer()
    ) throws -> CanvasPreparedScene {
        try makePresentation(
            elements: elements,
            viewport: viewport,
            selectedID: selectedID,
            guides: guides,
            gridSpacing: gridSpacing,
            preparer: preparer
        ).scene
    }

    func makeAppendOnlyScene(_ polyline: CanvasPreparedInk) -> CanvasPreparedScene {
        CanvasPreparedScene(
            geometry: [CanvasPreparedGeometry(
                id: UUID(),
                renderKey: .preview(id: UUID(), generation: polyline.generation),
                path: .ink(polyline),
                bounds: .init(x: 10, y: 10, width: 20, height: 10),
                style: .default
            )],
            gridLines: [],
            selectionBounds: nil,
            guides: [],
            viewport: try! .identity(size: .init(width: 100, height: 100)),
            theme: Self.theme(),
            previewGeneration: polyline.generation
        )
    }

    func makeInkScene(
        ink: CanvasPreparedInk,
        lineWidth: Double,
        stroke: CanvasColor = .black,
        background: CanvasColor = CanvasColor(red: 1, green: 1, blue: 1),
        viewport: CanvasViewport = try! .identity(size: .init(width: 100, height: 100))
    ) -> CanvasPreparedScene {
        CanvasPreparedScene(
            geometry: [CanvasPreparedGeometry(
                id: UUID(),
                renderKey: .preview(id: UUID(), generation: ink.generation),
                path: .ink(ink),
                bounds: .init(x: 0, y: 0, width: 100, height: 100),
                style: .init(stroke: stroke, lineWidth: lineWidth)
            )],
            gridLines: [],
            selectionBounds: nil,
            guides: [],
            viewport: viewport,
            theme: CanvasThemeSnapshot(
                background: background,
                grid: background,
                stroke: .black,
                selection: .black,
                guides: .black,
                gridLineWidth: 1,
                selectionLineWidth: 2,
                handleSize: 8
            ),
            previewGeneration: ink.generation
        )
    }

    func makeInkScene(inks: [CanvasPreparedInk], lineWidth: Double) -> CanvasPreparedScene {
        CanvasPreparedScene(
            geometry: inks.enumerated().map { index, ink in
                CanvasPreparedGeometry(
                    id: UUID(),
                    renderKey: .preview(id: UUID(), generation: ink.generation),
                    path: .ink(ink),
                    bounds: .init(x: Double(index), y: 0, width: 2, height: 20),
                    style: .init(stroke: .black, lineWidth: lineWidth)
                )
            },
            gridLines: [],
            selectionBounds: nil,
            guides: [],
            viewport: try! .identity(size: .init(width: 200, height: 100)),
            theme: Self.theme(),
            previewGeneration: nil
        )
    }

    func replacingViewport(
        in scene: CanvasPreparedScene,
        with viewport: CanvasViewport
    ) -> CanvasPreparedScene {
        CanvasPreparedScene(
            geometry: scene.geometry,
            gridLines: scene.gridLines,
            selectionBounds: scene.selectionBounds,
            guides: scene.guides,
            viewport: viewport,
            theme: scene.theme,
            previewGeneration: scene.previewGeneration
        )
    }

    func inkSnapshot(
        points: [CanvasPoint],
        pressures: [Double]? = nil,
        pressureEnabled: Bool
    ) -> CanvasPreparedInkSnapshot {
        CanvasPreparedInkSnapshot(
            confirmed: points.enumerated().map { index, point in
                CanvasInkSample(point: point, pressure: pressures?[index] ?? 1)
            },
            predicted: [],
            pressureEnabled: pressureEnabled,
            finalizedConfirmedSampleCount: points.count
        )
    }

    func firstClosedPolygon(in path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        var isComplete = false
        path.applyWithBlock { elementPointer in
            guard !isComplete else { return }
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                points.append(element.points[0])
            case .closeSubpath:
                isComplete = true
            case .addQuadCurveToPoint, .addCurveToPoint:
                break
            @unknown default:
                break
            }
        }
        return points
    }

    func closedSubpathCount(in path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { elementPointer in
            if elementPointer.pointee.type == .closeSubpath { count += 1 }
        }
        return count
    }

    func closedSubpaths(in path: CGPath) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                current = [element.points[0]]
            case .addLineToPoint:
                current.append(element.points[0])
            case .addQuadCurveToPoint:
                current.append(element.points[1])
            case .addCurveToPoint:
                current.append(element.points[2])
            case .closeSubpath:
                result.append(current)
                current = []
            @unknown default:
                break
            }
        }
        return result
    }

    func signedArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 2 else { return 0 }
        return points.indices.reduce(into: 0) { area, index in
            let next = points[(index + 1) % points.count]
            area += points[index].x * next.y - next.x * points[index].y
        } / 2
    }

    func verticalInkSpan(in image: CGImage, canvasX: Double, displayScale: Double) -> Double {
        let x = Int((canvasX * displayScale).rounded())
        let foregroundRows = (0..<image.height).filter { y in
            pixelRGB(in: image, x: x, y: y) != (255, 255, 255)
        }
        guard let first = foregroundRows.first, let last = foregroundRows.last else { return 0 }
        return Double(last - first + 1)
    }

    func pixelAlpha(in image: CGImage, x: Int, canvasY: Int) -> UInt8 {
        let y = image.height - 1 - canvasY
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              x >= 0, x < image.width, y >= 0, y < image.height else { return 0 }
        let index = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return bytes[index + 3]
    }

    func pixelRGB(in image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              x >= 0, x < image.width, y >= 0, y < image.height else { return (0, 0, 0) }
        let index = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (bytes[index], bytes[index + 1], bytes[index + 2])
    }

    func makeLegacyCompoundInkBitmap(
        snapshot: CanvasPreparedInkSnapshot,
        lineWidth: Double,
        bounds: CGRect,
        displayScale: Double
    ) -> CGImage? {
        let width = Int(ceil(bounds.width * displayScale))
        let height = Int(ceil(bounds.height * displayScale))
        guard let context = makeContext(width: width, height: height),
              let path = try? CanvasInkOutlineBuilder.makePath(
                snapshot: snapshot,
                viewportScale: displayScale,
                lineWidth: lineWidth
              ) else {
            return nil
        }
        context.scaleBy(x: displayScale, y: displayScale)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath(using: .winding)
        return context.makeImage()
    }

    func assertForegroundMasksWithinOnePixel(
        _ first: CGImage,
        _ second: CGImage,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(first.width, second.width, file: file, line: line)
        XCTAssertEqual(first.height, second.height, file: file, line: line)
        for y in 0..<min(first.height, second.height) {
            for x in 0..<min(first.width, second.width) {
                let firstForeground = pixelRGB(in: first, x: x, y: y) != (255, 255, 255)
                let secondForeground = pixelRGB(in: second, x: x, y: y) != (255, 255, 255)
                guard firstForeground != secondForeground else { continue }
                let other = firstForeground ? second : first
                let hasNeighbor = (max(0, y - 1)...min(other.height - 1, y + 1)).contains { candidateY in
                    (max(0, x - 1)...min(other.width - 1, x + 1)).contains { candidateX in
                        pixelRGB(in: other, x: candidateX, y: candidateY) != (255, 255, 255)
                    }
                }
                XCTAssertTrue(
                    hasNeighbor,
                    "Foreground masks differ by more than one physical pixel at (\(x), \(y))",
                    file: file,
                    line: line
                )
                if !hasNeighbor { return }
            }
        }
    }

    static func theme() -> CanvasThemeSnapshot {
        CanvasThemeSnapshot(
            background: CanvasColor(red: 1, green: 1, blue: 1),
            grid: CanvasColor(red: 0.8, green: 0.8, blue: 0.8),
            stroke: .black,
            selection: CanvasColor(red: 0, green: 0.4, blue: 1),
            guides: CanvasColor(red: 1, green: 0, blue: 0),
            gridLineWidth: 1,
            selectionLineWidth: 2,
            handleSize: 8
        )
    }

    func line(
        id: UUID = UUID(),
        contentRevision: UInt64 = 0,
        start: CanvasPoint = .init(x: 10, y: 10),
        end: CanvasPoint = .init(x: 80, y: 80),
        lineWidth: Double = 2
    ) -> CanvasElement {
        CanvasElement(
            id: id,
            contentRevision: contentRevision,
            geometry: .line(.init(start: start, end: end)),
            style: .init(stroke: .black, lineWidth: lineWidth)
        )
    }

    func textElement() -> CanvasElement {
        CanvasElement(
            id: UUID(),
            geometry: .text(.init(
                frame: .init(x: 10, y: 10, width: 80, height: 40),
                text: "UIKit only",
                font: .init(familyName: "Helvetica", pointSize: 16),
                color: .black
            ))
        )
    }

    func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    func pixelDiffersFromBackground(
        in image: CGImage,
        x: Int,
        y: Int,
        background: CanvasColor
    ) -> Bool {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              x >= 0,
              x < image.width,
              y >= 0,
              y < image.height else {
            return false
        }
        let expected = [background.red, background.green, background.blue].map {
            UInt8((min(1, max(0, $0)) * 255).rounded())
        }
        let bytesPerPixel = image.bitsPerPixel / 8
        let index = y * image.bytesPerRow + x * bytesPerPixel
        return bytes[index] != expected[0]
            || bytes[index + 1] != expected[1]
            || bytes[index + 2] != expected[2]
    }

    func imageContainsNonBackgroundPixel(_ image: CGImage, background: CanvasColor) -> Bool {
        for y in 0..<image.height {
            for x in 0..<image.width where pixelDiffersFromBackground(
                in: image,
                x: x,
                y: y,
                background: background
            ) {
                return true
            }
        }
        return false
    }

    func neighborhoodDiffersFromBackground(
        in image: CGImage,
        x: Int,
        y: Int,
        background: CanvasColor
    ) -> Bool {
        for candidateY in (y - 1)...(y + 1) {
            for candidateX in (x - 1)...(x + 1) where pixelDiffersFromBackground(
                in: image,
                x: candidateX,
                y: candidateY,
                background: background
            ) {
                return true
            }
        }
        return false
    }
}

private extension CoreGraphicsRenderCommand {
    var elementID: UUID? {
        if case .element(let id, _, _, _, _) = self { id } else { nil }
    }

    var selectionBounds: CanvasRect? {
        if case .selection(let bounds, _, _, _) = self { bounds } else { nil }
    }

    var snapGuide: SnapGuide? {
        if case .guide(let guide, _, _) = self { guide } else { nil }
    }

    var canvasLineWidth: Double {
        switch self {
        case .background:
            0
        case .grid(_, _, let lineWidth),
             .guide(_, _, let lineWidth),
             .element(_, _, _, _, let lineWidth),
             .selection(_, _, let lineWidth, _):
            lineWidth
        }
    }

    var canvasHandleSize: Double {
        if case .selection(_, _, _, let handleSize) = self { handleSize } else { 0 }
    }

    var isGrid: Bool {
        if case .grid = self { true } else { false }
    }
}

private extension Array where Element == CoreGraphicsRenderCommand {
    var firstElement: CoreGraphicsRenderCommand? {
        first(where: {
            if case .element = $0 { true } else { false }
        })
    }
}
