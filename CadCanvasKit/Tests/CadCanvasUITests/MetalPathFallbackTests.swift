import CoreGraphics
import CadCanvasCore
import Metal
import XCTest
@testable import CadCanvasUI

@MainActor
final class MetalPathFallbackTests: XCTestCase {
    func testQuadraticFlatteningStaysWithinQuarterDevicePixel() throws {
        let start = CanvasPoint(x: 12, y: 20)
        let control = CanvasPoint(x: 68, y: 132)
        let end = CanvasPoint(x: 124, y: 18)
        let viewport = try! CanvasViewport(
            zoom: 4,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 600, height: 600)
        )
        let mesh = try MetalPathFallback.compile(
            path: .immutable(.init(commands: [
                .move(start),
                .quad(control: control, end: end),
            ])),
            style: .init(stroke: .black, lineWidth: 2),
            viewport: viewport
        )

        let polyline = try XCTUnwrap(mesh.contours.first?.points)
        XCTAssertGreaterThan(polyline.count, 2)
        for step in 0...4_096 {
            let t = Double(step) / 4_096
            let exact = quadratic(start, control, end, t: t)
            XCTAssertLessThanOrEqual(
                distance(exact, to: polyline) * viewport.zoom,
                0.25 + 0.000_001,
                "Quadratic flattening exceeded the device-pixel tolerance at t=\(t)"
            )
        }

        let reversing = try MetalPathFallback.compile(
            path: .immutable(.init(commands: [
                .move(.init(x: 0, y: 0)),
                .quad(control: .init(x: 100, y: 0), end: .init(x: 10, y: 0)),
            ])),
            style: .init(stroke: .black, lineWidth: 2),
            viewport: viewport
        )
        let reversingPolyline = try XCTUnwrap(reversing.contours.first?.points)
        XCTAssertGreaterThan(reversingPolyline.count, 2)
        for step in 0...4_096 {
            let t = Double(step) / 4_096
            XCTAssertLessThanOrEqual(
                distance(
                    quadratic(.init(x: 0, y: 0), .init(x: 100, y: 0),
                              .init(x: 10, y: 0), t: t),
                    to: reversingPolyline
                ) * viewport.zoom,
                0.25 + 0.000_001
            )
        }

        let worldOrigin = CanvasPoint(x: 1_000_000_000_000, y: -1_000_000_000_000)
        let localStart = CanvasPoint(x: 0, y: 8)
        let localControl = CanvasPoint(x: 42, y: 92)
        let localEnd = CanvasPoint(x: 96, y: 4)
        let largeViewport = try! CanvasViewport(
            zoom: 4,
            translation: .init(x: -worldOrigin.x * 4, y: -worldOrigin.y * 4),
            viewportSize: .init(width: 600, height: 600)
        )
        let worldStart = translated(localStart, by: worldOrigin)
        let worldControl = translated(localControl, by: worldOrigin)
        let worldEnd = translated(localEnd, by: worldOrigin)
        let largePath = CanvasPath(commands: [
            .move(worldStart),
            .quad(control: worldControl, end: worldEnd),
        ])
        let large = try MetalPathFallback.compile(
            path: .immutable(largePath),
            style: .init(stroke: .black, lineWidth: 2),
            viewport: largeViewport
        )
        let largePolyline = try XCTUnwrap(large.contours.first?.points)
        for step in 0...4_096 {
            let t = Double(step) / 4_096
            XCTAssertLessThanOrEqual(
                distance(quadratic(localStart, localControl, localEnd, t: t),
                         to: largePolyline) * largeViewport.zoom,
                0.25 + 0.000_001
            )
        }
    }

    func testCubicFlatteningStaysWithinQuarterDevicePixel() throws {
        let start = CanvasPoint(x: 8, y: 96)
        let control1 = CanvasPoint(x: 34, y: -40)
        let control2 = CanvasPoint(x: 118, y: 184)
        let end = CanvasPoint(x: 148, y: 32)
        let viewport = try! CanvasViewport(
            zoom: 3,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 520, height: 520)
        )
        let mesh = try MetalPathFallback.compile(
            path: .immutable(.init(commands: [
                .move(start),
                .cubic(control1: control1, control2: control2, end: end),
            ])),
            style: .init(stroke: .black, lineWidth: 2),
            viewport: viewport
        )

        let polyline = try XCTUnwrap(mesh.contours.first?.points)
        XCTAssertGreaterThan(polyline.count, 2)
        for step in 0...8_192 {
            let t = Double(step) / 8_192
            let exact = cubic(start, control1, control2, end, t: t)
            XCTAssertLessThanOrEqual(
                distance(exact, to: polyline) * viewport.zoom,
                0.25 + 0.000_001,
                "Cubic flattening exceeded the device-pixel tolerance at t=\(t)"
            )
        }

        let reversing = try MetalPathFallback.compile(
            path: .immutable(.init(commands: [
                .move(.init(x: 0, y: 0)),
                .cubic(
                    control1: .init(x: 120, y: 0),
                    control2: .init(x: -100, y: 0),
                    end: .init(x: 12, y: 0)
                ),
            ])),
            style: .init(stroke: .black, lineWidth: 2),
            viewport: viewport
        )
        let reversingPolyline = try XCTUnwrap(reversing.contours.first?.points)
        XCTAssertGreaterThan(reversingPolyline.count, 2)
        for step in 0...8_192 {
            let t = Double(step) / 8_192
            XCTAssertLessThanOrEqual(
                distance(
                    cubic(.init(x: 0, y: 0), .init(x: 120, y: 0),
                          .init(x: -100, y: 0), .init(x: 12, y: 0), t: t),
                    to: reversingPolyline
                ) * viewport.zoom,
                0.25 + 0.000_001
            )
        }

        let worldOrigin = CanvasPoint(x: -1_000_000_000_000, y: 1_000_000_000_000)
        let localStart = CanvasPoint(x: 0, y: 44)
        let localControl1 = CanvasPoint(x: 28, y: -24)
        let localControl2 = CanvasPoint(x: 74, y: 122)
        let localEnd = CanvasPoint(x: 112, y: 30)
        let largeViewport = try! CanvasViewport(
            zoom: 3,
            translation: .init(x: -worldOrigin.x * 3, y: -worldOrigin.y * 3),
            viewportSize: .init(width: 520, height: 520)
        )
        let worldStart = translated(localStart, by: worldOrigin)
        let worldControl1 = translated(localControl1, by: worldOrigin)
        let worldControl2 = translated(localControl2, by: worldOrigin)
        let worldEnd = translated(localEnd, by: worldOrigin)
        let largePath = CanvasPath(commands: [
            .move(worldStart),
            .cubic(control1: worldControl1, control2: worldControl2, end: worldEnd),
        ])
        let large = try MetalPathFallback.compile(
            path: .immutable(largePath),
            style: .init(stroke: .black, lineWidth: 2),
            viewport: largeViewport
        )
        let largePolyline = try XCTUnwrap(large.contours.first?.points)
        for step in 0...8_192 {
            let t = Double(step) / 8_192
            XCTAssertLessThanOrEqual(
                distance(cubic(localStart, localControl1, localControl2, localEnd, t: t),
                         to: largePolyline) * largeViewport.zoom,
                0.25 + 0.000_001
            )
        }
    }

    func testStrokeMeshPreservesRoundCapsAndJoins() throws {
        let mesh = try MetalPathFallback.compile(
            path: .immutable(.init(commands: [
                .move(.init(x: 20, y: 20)),
                .line(.init(x: 60, y: 20)),
                .line(.init(x: 60, y: 60)),
            ])),
            style: .init(stroke: .black, lineWidth: 10),
            viewport: .identity(size: .init(width: 100, height: 100))
        )

        let strokeVertices = mesh.strokeIndexRange.map {
            mesh.vertices[Int(mesh.indices[$0])].position
        }
        XCTAssertFalse(strokeVertices.isEmpty)
        XCTAssertEqual(try XCTUnwrap(strokeVertices.map(\.x).min()), 15, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(strokeVertices.map(\.y).max()), 65, accuracy: 0.0001)
        XCTAssertTrue(strokeVertices.contains { vertex in
            hypot(Double(vertex.x - 60), Double(vertex.y - 20)) >= 4.99
                && vertex.x >= 60 && vertex.y <= 20
        }, "The outside corner must contain the round join arc")
        XCTAssertEqual(mesh.roundCapCount, 2)
        XCTAssertEqual(mesh.roundJoinCount, 1)

        let zoomedViewport = try! CanvasViewport(
            zoom: 4,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 100, height: 100)
        )
        let zoomed = try MetalPathFallback.compile(
            path: .immutable(.init(commands: [
                .move(.init(x: 20, y: 20)),
                .line(.init(x: 60, y: 20)),
                .line(.init(x: 60, y: 60)),
            ])),
            style: .init(stroke: .black, lineWidth: 10),
            viewport: zoomedViewport
        )
        let zoomedStrokeVertices = zoomed.strokeIndexRange.map {
            zoomed.vertices[Int(zoomed.indices[$0])].position
        }
        let zoomedMinimumX = try XCTUnwrap(zoomedStrokeVertices.map(\.x).min())
        XCTAssertEqual((20 - zoomedMinimumX) * 4, 5, accuracy: 0.0001)
    }

    func testConcaveFillUsesNonzeroWindingRule() throws {
        let mesh = try MetalPathFallback.compile(
            path: .immutable(.init(commands: [
                .move(.init(x: 10, y: 10)),
                .line(.init(x: 80, y: 10)),
                .line(.init(x: 80, y: 35)),
                .line(.init(x: 35, y: 35)),
                .line(.init(x: 35, y: 80)),
                .line(.init(x: 10, y: 80)),
                .close,
            ])),
            style: .init(
                stroke: .init(red: 0, green: 0, blue: 0, alpha: 0),
                fill: .black,
                lineWidth: 1
            ),
            viewport: .identity(size: .init(width: 100, height: 100))
        )

        XCTAssertEqual(mesh.fillStrategy, .orientedStencilWindingThenBoundsCover)
        XCTAssertNotEqual(windingNumber(.init(x: 20, y: 65), contours: mesh.contours), 0)
        XCTAssertNotEqual(windingNumber(.init(x: 65, y: 20), contours: mesh.contours), 0)
        XCTAssertEqual(windingNumber(.init(x: 60, y: 60), contours: mesh.contours), 0)
        XCTAssertEqual(mesh.fillBounds, CGRect(x: 10, y: 10, width: 70, height: 70))
    }

    func testSelfIntersectingFillUsesStencilWindingThenBoundsCover() throws {
        let mesh = try MetalPathFallback.compile(
            path: .immutable(.init(commands: [
                .move(.init(x: 12, y: 12)),
                .line(.init(x: 88, y: 88)),
                .line(.init(x: 12, y: 88)),
                .line(.init(x: 88, y: 12)),
                .close,
            ])),
            style: .init(
                stroke: .init(red: 0, green: 0, blue: 0, alpha: 0),
                fill: .black,
                lineWidth: 1
            ),
            viewport: .identity(size: .init(width: 100, height: 100))
        )

        XCTAssertEqual(mesh.fillStrategy, .orientedStencilWindingThenBoundsCover)
        XCTAssertEqual(mesh.fillIndexRange.count, 12)
        XCTAssertEqual(mesh.fillBounds, CGRect(x: 12, y: 12, width: 76, height: 76))
        XCTAssertNotEqual(windingNumber(.init(x: 50, y: 25), contours: mesh.contours), 0)
        XCTAssertNotEqual(windingNumber(.init(x: 50, y: 75), contours: mesh.contours), 0)
        XCTAssertEqual(windingNumber(.init(x: 8, y: 50), contours: mesh.contours), 0)

        var disjointCommands: [CanvasPathCommand] = []
        for index in 0..<256 {
            let x = Double(index) * 12 + 2
            disjointCommands.append(contentsOf: [
                .move(.init(x: x, y: 10)),
                .line(.init(x: x + 8, y: 10)),
                .line(.init(x: x + 8, y: 30)),
                .line(.init(x: x, y: 30)),
                .close,
            ])
        }
        let disjoint = try MetalPathFallback.compile(
            path: .immutable(.init(commands: disjointCommands)),
            style: .init(
                stroke: .init(red: 0, green: 0, blue: 0, alpha: 0),
                fill: .black,
                lineWidth: 0
            ),
            viewport: .identity(size: .init(width: 3_100, height: 40))
        )
        XCTAssertFalse(disjoint.fillIndexRange.isEmpty)

        var sawtoothCommands: [CanvasPathCommand] = [
            .move(.init(x: 2, y: 10)),
        ]
        for step in 1...512 {
            sawtoothCommands.append(.line(.init(
                x: Double(step) * 4 + 2,
                y: step.isMultiple(of: 2) ? 10 : 20
            )))
        }
        sawtoothCommands.append(contentsOf: [
            .line(.init(x: 2_050, y: 40)),
            .line(.init(x: 2, y: 40)),
            .close,
        ])
        let sawtooth = try MetalPathFallback.compile(
            path: .immutable(.init(commands: sawtoothCommands)),
            style: .init(
                stroke: .init(red: 0, green: 0, blue: 0, alpha: 0),
                fill: .black,
                lineWidth: 0
            ),
            viewport: .identity(size: .init(width: 2_100, height: 50))
        )
        XCTAssertFalse(sawtooth.fillIndexRange.isEmpty)

        var highWindingCommands: [CanvasPathCommand] = []
        var negativeHighWindingCommands: [CanvasPathCommand] = []
        var repeatedContourCommands: [CanvasPathCommand] = [
            .move(.init(x: 10, y: 10)),
        ]
        var negativeRepeatedContourCommands: [CanvasPathCommand] = [
            .move(.init(x: 10, y: 10)),
        ]
        for _ in 0..<256 {
            highWindingCommands.append(contentsOf: [
                .move(.init(x: 10, y: 10)),
                .line(.init(x: 90, y: 10)),
                .line(.init(x: 90, y: 90)),
                .line(.init(x: 10, y: 90)),
                .close,
            ])
            negativeHighWindingCommands.append(contentsOf: [
                .move(.init(x: 10, y: 10)),
                .line(.init(x: 10, y: 90)),
                .line(.init(x: 90, y: 90)),
                .line(.init(x: 90, y: 10)),
                .close,
            ])
            repeatedContourCommands.append(contentsOf: [
                .line(.init(x: 90, y: 10)),
                .line(.init(x: 90, y: 90)),
                .line(.init(x: 10, y: 90)),
                .line(.init(x: 10, y: 10)),
            ])
            negativeRepeatedContourCommands.append(contentsOf: [
                .line(.init(x: 10, y: 90)),
                .line(.init(x: 90, y: 90)),
                .line(.init(x: 90, y: 10)),
                .line(.init(x: 10, y: 10)),
            ])
        }
        repeatedContourCommands.append(.close)
        negativeRepeatedContourCommands.append(.close)
        for commands in [
            highWindingCommands,
            negativeHighWindingCommands,
            repeatedContourCommands,
            negativeRepeatedContourCommands,
        ] {
            XCTAssertThrowsError(try MetalPathFallback.compile(
                path: .immutable(.init(commands: commands)),
                style: .init(stroke: .black, fill: .black, lineWidth: 1),
                viewport: .identity(size: .init(width: 100, height: 100))
            )) {
                XCTAssertEqual($0 as? MetalCanvasError, .invalidResourceSize)
            }
        }
    }

    func testFallbackResourceKeyIncludesGeometryStyleAndScale() throws {
        let geometry = preparedGeometry(
            path: .init(commands: [
                .move(.init(x: 10, y: 20)),
                .quad(
                    control: .init(x: 30, y: 2),
                    end: .init(x: 50, y: 20)
                ),
            ]),
            style: .init(
                stroke: .init(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.75),
                lineWidth: 3
            )
        )
        let viewport = try! CanvasViewport(
            zoom: 2,
            translation: .init(x: -8, y: 6),
            viewportSize: .init(width: 120, height: 90)
        )
        let key = try MetalPathFallback.resourceKey(
            for: geometry,
            viewport: viewport,
            displayScale: 3
        )

        guard case .fallback(
            let renderKey,
            let resourceIdentity,
            let styleFingerprint,
            let viewportZoom,
            let displayScale,
            let viewportSize,
            let viewportTranslation,
            let coordinateOrigin
        ) = key else {
            return XCTFail("Expected a fallback resource key")
        }
        XCTAssertEqual(renderKey, geometry.renderKey)
        XCTAssertEqual(resourceIdentity, geometry.resourceIdentity)
        XCTAssertEqual(styleFingerprint, try MetalPathFallback.styleFingerprint(geometry.style))
        XCTAssertEqual(viewportZoom, 2)
        XCTAssertEqual(displayScale, 3)
        XCTAssertEqual(viewportSize, viewport.viewportSize)
        XCTAssertEqual(viewportTranslation, viewport.translation)
        XCTAssertEqual(coordinateOrigin, CanvasPoint(
            x: viewport.visibleCanvasRect.x,
            y: viewport.visibleCanvasRect.y
        ))
        XCTAssertNotEqual(
            key,
            try MetalPathFallback.resourceKey(
                for: geometry,
                viewport: try! CanvasViewport(
                    zoom: 3,
                    translation: viewport.translation,
                    viewportSize: viewport.viewportSize
                ),
                displayScale: 2
            )
        )
        XCTAssertNotEqual(
            key,
            try MetalPathFallback.resourceKey(
                for: geometry,
                viewport: try! CanvasViewport(
                    zoom: viewport.zoom,
                    translation: viewport.translation,
                    viewportSize: .init(width: 180, height: 90)
                ),
                displayScale: 3
            )
        )
        XCTAssertNotEqual(
            key,
            try MetalPathFallback.resourceKey(
                for: geometry,
                viewport: try! CanvasViewport(
                    zoom: viewport.zoom,
                    translation: .init(
                        x: viewport.translation.x + 1,
                        y: viewport.translation.y
                    ),
                    viewportSize: viewport.viewportSize
                ),
                displayScale: 3
            )
        )
        XCTAssertNotEqual(
            styleFingerprint,
            try MetalPathFallback.styleFingerprint(.init(stroke: .black, lineWidth: 3))
        )
        XCTAssertNotEqual(
            styleFingerprint,
            try MetalPathFallback.styleFingerprint(.init(
                stroke: geometry.style.stroke,
                fill: .black,
                lineWidth: geometry.style.lineWidth
            ))
        )
    }

    func testInvalidOrOverflowingFallbackGeometryFailsAtomically() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let resources = MetalResourceCache(device: device, budgetBytes: 128 * 1_024)
        let cache = MetalPathFallbackCache(device: device, resourceCache: resources)
        let viewport = try! CanvasViewport.identity(size: .init(width: 100, height: 100))
        let valid = preparedGeometry(path: .init(commands: [
            .move(.init(x: 10, y: 10)),
            .quad(control: .init(x: 30, y: 2), end: .init(x: 50, y: 10)),
        ]))
        _ = try cache.prepare(
            geometry: valid,
            viewport: viewport,
            displayScale: 1
        )
        let resourceCount = resources.resourceCount
        let residentBytes = resources.residentByteCount

        let invalid = preparedGeometry(path: .init(commands: [
            .move(.init(x: 10, y: 10)),
            .quad(control: .init(x: .nan, y: 2), end: .init(x: 50, y: 10)),
        ]))
        let overflowing = preparedGeometry(
            path: .init(commands: [
                .move(.init(x: 10, y: 10)),
                .cubic(
                    control1: .init(x: 20, y: 30),
                    control2: .init(x: 40, y: 30),
                    end: .init(x: 50, y: 10)
                ),
            ]),
            style: .init(stroke: .black, lineWidth: Double.greatestFiniteMagnitude)
        )
        let invalidCommands = immutableCommands(invalid)
        let overflowingCommands = immutableCommands(overflowing)

        XCTAssertThrowsError(try cache.prepare(
            geometry: invalid,
            viewport: viewport,
            displayScale: 1
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .invalidNumericInput)
        }
        XCTAssertThrowsError(try cache.prepare(
            geometry: overflowing,
            viewport: viewport,
            displayScale: 1
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .invalidNumericInput)
        }
        XCTAssertEqual(resources.resourceCount, resourceCount)
        XCTAssertEqual(resources.residentByteCount, residentBytes)
        XCTAssertEqual(immutableCommands(invalid), invalidCommands)
        XCTAssertEqual(immutableCommands(overflowing), overflowingCommands)
        XCTAssertNotNil(cache.resource(
            for: valid,
            viewport: viewport,
            displayScale: 1
        ))

        let unrepresentableRebase = preparedGeometry(path: .init(commands: [
            .move(.init(x: Double.greatestFiniteMagnitude, y: 0)),
            .quad(
                control: .init(x: Double.greatestFiniteMagnitude, y: 1),
                end: .init(x: Double.greatestFiniteMagnitude, y: 2)
            ),
        ]))
        let extremeViewport = try! CanvasViewport(
            zoom: 1,
            translation: .init(x: Double.greatestFiniteMagnitude, y: 0),
            viewportSize: .init(width: 100, height: 100)
        )
        XCTAssertThrowsError(try cache.prepare(
            geometry: unrepresentableRebase,
            viewport: extremeViewport,
            displayScale: 1
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .invalidNumericInput)
        }
        XCTAssertEqual(resources.resourceCount, resourceCount)
        XCTAssertEqual(resources.residentByteCount, residentBytes)
    }

    func testFallbackOffscreenFixtureMeetsEdgeParityThresholds() throws {
        let viewport = try! CanvasViewport(
            zoom: 2,
            translation: .init(x: -16, y: -12),
            viewportSize: .init(width: 128, height: 112)
        )
        let path = CanvasPath(commands: [
            .move(.init(x: 18, y: 18)),
            .cubic(
                control1: .init(x: 34, y: 2),
                control2: .init(x: 54, y: 2),
                end: .init(x: 70, y: 18)
            ),
            .line(.init(x: 62, y: 56)),
            .quad(control: .init(x: 44, y: 43), end: .init(x: 26, y: 56)),
            .close,
        ])
        let filledArc = CanvasGeometry.arch(.init(
            start: .init(x: 82, y: 70),
            end: .init(x: 116, y: 70),
            sagitta: -18
        )).renderPath
        let arcGeometry = preparedGeometry(
            path: filledArc,
            style: .init(
                stroke: .init(red: 0.15, green: 0.3, blue: 0.9, alpha: 0.7),
                fill: .init(red: 0.9, green: 0.65, blue: 0.1, alpha: 0.55),
                lineWidth: 4
            )
        )
        let scene = preparedScene(geometry: [preparedGeometry(
            path: path,
            style: .init(
                stroke: .init(red: 0.8, green: 0.1, blue: 0.2, alpha: 0.8),
                fill: .init(red: 0.1, green: 0.65, blue: 0.35, alpha: 0.6),
                lineWidth: 5
            )
        ), arcGeometry], viewport: viewport,
        background: .init(red: 0, green: 0, blue: 0, alpha: 0))
        let size = CGSize(width: 128, height: 112)
        let displayScale = 2.0
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let compiled = try MetalSceneCompiler().compile(scene)
        XCTAssertTrue(compiled.renderItems.contains { item in
            guard case .fallback(let descriptor) = item else { return false }
            return descriptor.geometry.id == arcGeometry.id
                && descriptor.geometry.style.fill != nil
        })
        let arcMesh = try MetalPathFallback.compile(
            path: .immutable(filledArc),
            style: arcGeometry.style,
            viewport: viewport,
            displayScale: displayScale
        )
        XCTAssertFalse(arcMesh.fillIndexRange.isEmpty)
        XCTAssertFalse(arcMesh.strokeIndexRange.isEmpty)
        let engine = try MetalRenderEngine(device: device)
        let texture = try engine.renderOffscreen(
            compiled,
            size: size,
            displayScale: displayScale
        )
        XCTAssertLessThanOrEqual(
            engine.maximumOwnedCoverageByteCount,
            CanvasMetalLimits.resourceBudgetBytes
        )
        let constrainedEngine = try MetalRenderEngine(
            device: device,
            resourceBudgetBytes: 300_000
        )
        XCTAssertThrowsError(try constrainedEngine.renderOffscreen(
            compiled,
            size: size,
            displayScale: displayScale
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .resourceBudgetExceeded)
        }
        XCTAssertEqual(constrainedEngine.outputCommandBufferCount, 0)

        let freehandPoints = [
            CanvasPoint(x: 20, y: 82),
            CanvasPoint(x: 54, y: 88),
            CanvasPoint(x: 92, y: 80),
        ]
        let freehandID = UUID()
        let freehand = CanvasPreparedGeometry(
            id: freehandID,
            renderKey: .preview(id: freehandID, generation: .zero),
            path: .ink(CanvasPreparedInk(points: freehandPoints)),
            bounds: .init(x: 20, y: 80, width: 72, height: 8),
            style: .init(
                stroke: .init(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.7),
                lineWidth: 4
            )
        )
        let fallbackOnlyScene = preparedScene(
            geometry: [scene.geometry[0]],
            viewport: viewport,
            background: .init(red: 0, green: 0, blue: 0, alpha: 0)
        )
        let fallbackProbe = try MetalRenderEngine(device: device)
        _ = try fallbackProbe.renderOffscreen(
            try MetalSceneCompiler().compile(fallbackOnlyScene),
            size: size,
            displayScale: displayScale
        )
        let estimatorResources = MetalResourceCache(
            device: device,
            budgetBytes: CanvasMetalLimits.resourceBudgetBytes
        )
        let estimatorPipelines = try MetalPipelineLibrary(device: device)
        let coverageEstimator = try MetalFreehandCoverageCache(
            device: device,
            coveragePipeline: estimatorPipelines.coverageSegment,
            resourceCache: estimatorResources
        )
        let coverageEstimate = try coverageEstimator.estimatedCoverageByteCount(
            geometry: freehand,
            viewport: viewport,
            displayScale: displayScale
        )
        let mixedBudget = fallbackProbe.maximumOwnedCoverageByteCount
            + coverageEstimate - 1
        let mixedScene = preparedScene(
            geometry: [freehand, scene.geometry[0]],
            viewport: viewport,
            background: .init(red: 0, green: 0, blue: 0, alpha: 0)
        )
        let mixedCompiled = try MetalSceneCompiler().compile(mixedScene)
        if case .freehand = mixedCompiled.renderItems[0] {} else {
            XCTFail("Expected freehand before the preflight-retained fallback")
        }
        if case .fallback = mixedCompiled.renderItems[1] {} else {
            XCTFail("Expected fallback resource to participate in mixed ownership")
        }
        let mixedEngine = try MetalRenderEngine(
            device: device,
            resourceBudgetBytes: mixedBudget
        )
        XCTAssertThrowsError(try mixedEngine.renderOffscreen(
            mixedCompiled,
            size: size,
            displayScale: displayScale
        )) {
            XCTAssertEqual($0 as? MetalCanvasError, .resourceBudgetExceeded)
        }
        XCTAssertEqual(mixedEngine.freehandCoverageCommandBufferCount, 0)

        let reference = try XCTUnwrap(CoreGraphicsCanvasRenderer().makeBitmap(
            scene: scene,
            bounds: CGRect(origin: .zero, size: size),
            displayScale: displayScale
        ))
        let actual = rgbaPixels(texture)
        let expected = rgbaPixels(reference)
        let edgeBand = try geometricEdgeBand(
            geometry: scene.geometry,
            viewport: viewport,
            width: texture.width,
            height: texture.height,
            displayScale: displayScale
        )
        var edgeAlphaDifference = 0
        var edgeAlphaMaximum = 0
        var edgePixelCount = 0
        var maximumOutsideBandDifference = 0
        for y in 0..<texture.height {
            for x in 0..<texture.width {
                let offset = y * texture.width + x
                let isEdge = edgeBand[offset]
                if isEdge {
                    let alphaDifference = abs(Int(actual[offset][3]) - Int(expected[offset][3]))
                    edgeAlphaDifference += alphaDifference
                    edgeAlphaMaximum = max(edgeAlphaMaximum, alphaDifference)
                    edgePixelCount += 1
                }
                for channel in 0..<4 {
                    let difference = abs(Int(actual[offset][channel]) - Int(expected[offset][channel]))
                    if !isEdge {
                        if difference > maximumOutsideBandDifference {
                            maximumOutsideBandDifference = difference
                        }
                    }
                }
            }
        }

        XCTAssertLessThanOrEqual(maximumOutsideBandDifference, 1)
        XCTAssertLessThanOrEqual(
            Double(edgeAlphaDifference) / Double(max(1, edgePixelCount)),
            8
        )
        XCTAssertLessThanOrEqual(edgeAlphaMaximum, 32)
        XCTAssertGreaterThan(actual.filter { $0 != [0, 0, 0, 0] }.count, 2_000)

        let largeSize = CGSize(width: 1_024, height: 768)
        let largeViewport = try! CanvasViewport.identity(
            size: .init(width: largeSize.width, height: largeSize.height)
        )
        let box = preparedGeometry(
            path: CanvasGeometry.rectangle(.init(rect: .init(
                x: 360,
                y: 280,
                width: 120,
                height: 100
            ))).renderPath,
            style: .init(
                stroke: .init(red: 0.8, green: 0.2, blue: 0.2, alpha: 1),
                fill: .init(red: 0.8, green: 0.2, blue: 0.2, alpha: 1),
                lineWidth: 2
            )
        )
        let tinyFallback = preparedGeometry(
            path: .init(commands: [
                .move(.init(x: 400, y: 300)),
                .cubic(
                    control1: .init(x: 410, y: 290),
                    control2: .init(x: 430, y: 290),
                    end: .init(x: 440, y: 300)
                ),
                .line(.init(x: 435, y: 345)),
                .quad(control: .init(x: 420, y: 335), end: .init(x: 405, y: 345)),
                .close,
            ]),
            style: .init(
                stroke: .init(red: 0.9, green: 0.8, blue: 0.1, alpha: 1),
                fill: .init(red: 0.1, green: 0.8, blue: 0.2, alpha: 1),
                lineWidth: 3
            )
        )
        let topLine = preparedGeometry(
            path: .init(commands: [
                .move(.init(x: 380, y: 320)),
                .line(.init(x: 460, y: 320)),
            ]),
            style: .init(
                stroke: .init(red: 0.1, green: 0.2, blue: 0.9, alpha: 1),
                lineWidth: 4
            )
        )
        let largeScene = preparedScene(
            geometry: [box, tinyFallback, topLine],
            viewport: largeViewport,
            background: .init(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        )
        let largeCompiled = try MetalSceneCompiler().compile(largeScene)
        XCTAssertEqual(largeCompiled.renderItems.count, 3)
        if case .analyticBox = largeCompiled.renderItems[0] {} else {
            XCTFail("Expected analytic content before the fallback")
        }
        if case .fallback = largeCompiled.renderItems[1] {} else {
            XCTFail("Expected the tiny path to use fallback")
        }
        if case .analyticLine = largeCompiled.renderItems[2] {} else {
            XCTFail("Expected analytic content after the fallback")
        }
        let largeEngine = try MetalRenderEngine(device: device)
        let largeTexture = try largeEngine.renderOffscreen(
            largeCompiled,
            size: largeSize,
            displayScale: 2
        )
        XCTAssertLessThanOrEqual(
            largeEngine.maximumOwnedCoverageByteCount,
            CanvasMetalLimits.resourceBudgetBytes
        )
        XCTAssertEqual(rgbaPixel(largeTexture, x: 40, y: 40), [26, 51, 77, 255])
        XCTAssertEqual(rgbaPixel(largeTexture, x: 740, y: 580), [204, 51, 51, 255])
        XCTAssertEqual(rgbaPixel(largeTexture, x: 840, y: 620), [25, 204, 51, 255])
        XCTAssertEqual(rgbaPixel(largeTexture, x: 840, y: 640), [25, 51, 229, 255])
    }

    func testSingleCommandFrameBudgetsFallbackSurfaceAndFreehandCopyOnWriteTogether() throws {
        try assertSynchronizedFallbackSurfaceIsReleasedBeforeFreehandCopyOnWrite()
    }
}

private extension MetalPathFallbackTests {
    func translated(_ point: CanvasPoint, by origin: CanvasPoint) -> CanvasPoint {
        .init(x: point.x + origin.x, y: point.y + origin.y)
    }

    func preparedGeometry(
        path: CanvasPath,
        style: CanvasStyle = .default
    ) -> CanvasPreparedGeometry {
        CanvasPreparedGeometry(
            id: UUID(),
            renderKey: .committed(id: UUID(), contentRevision: 0),
            path: .immutable(path),
            bounds: path.bounds,
            style: style
        )
    }

    func preparedScene(
        geometry: [CanvasPreparedGeometry],
        viewport: CanvasViewport,
        background: CanvasColor = .init(red: 1, green: 1, blue: 1)
    ) -> CanvasPreparedScene {
        CanvasPreparedScene(
            geometry: geometry,
            gridLines: [],
            selectionBounds: nil,
            guides: [],
            viewport: viewport,
            theme: .init(
                background: background,
                grid: .init(red: 0.75, green: 0.75, blue: 0.75),
                stroke: .black,
                selection: .init(red: 0, green: 0.4, blue: 1),
                guides: .init(red: 1, green: 0, blue: 0),
                gridLineWidth: 1,
                selectionLineWidth: 2,
                handleSize: 8
            ),
            previewGeneration: nil
        )
    }

    func immutableCommands(_ geometry: CanvasPreparedGeometry) -> [CanvasPathCommand] {
        guard case .immutable(let path) = geometry.path else { return [] }
        return path.commands
    }

    func quadratic(
        _ start: CanvasPoint,
        _ control: CanvasPoint,
        _ end: CanvasPoint,
        t: Double
    ) -> CanvasPoint {
        let inverse = 1 - t
        return .init(
            x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
            y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
        )
    }

    func cubic(
        _ start: CanvasPoint,
        _ control1: CanvasPoint,
        _ control2: CanvasPoint,
        _ end: CanvasPoint,
        t: Double
    ) -> CanvasPoint {
        let inverse = 1 - t
        return .init(
            x: inverse * inverse * inverse * start.x
                + 3 * inverse * inverse * t * control1.x
                + 3 * inverse * t * t * control2.x
                + t * t * t * end.x,
            y: inverse * inverse * inverse * start.y
                + 3 * inverse * inverse * t * control1.y
                + 3 * inverse * t * t * control2.y
                + t * t * t * end.y
        )
    }

    func distance(_ point: CanvasPoint, to polyline: [CanvasPoint]) -> Double {
        zip(polyline, polyline.dropFirst()).map { start, end in
            let delta = CanvasPoint(x: end.x - start.x, y: end.y - start.y)
            let squaredLength = delta.x * delta.x + delta.y * delta.y
            guard squaredLength > 0 else { return point.distance(to: start) }
            let parameter = min(1, max(0,
                ((point.x - start.x) * delta.x + (point.y - start.y) * delta.y)
                    / squaredLength
            ))
            return hypot(
                point.x - start.x - parameter * delta.x,
                point.y - start.y - parameter * delta.y
            )
        }.min() ?? .infinity
    }

    func windingNumber(_ point: CanvasPoint, contours: [MetalFallbackContour]) -> Int {
        var result = 0
        for contour in contours where contour.isClosed {
            for (start, end) in zip(contour.points, contour.points.dropFirst()) {
                if start.y <= point.y, end.y > point.y,
                   cross(start: start, end: end, point: point) > 0 {
                    result += 1
                } else if start.y > point.y, end.y <= point.y,
                          cross(start: start, end: end, point: point) < 0 {
                    result -= 1
                }
            }
        }
        return result
    }

    func cross(start: CanvasPoint, end: CanvasPoint, point: CanvasPoint) -> Double {
        (end.x - start.x) * (point.y - start.y)
            - (point.x - start.x) * (end.y - start.y)
    }

    func rgbaPixels(_ texture: any MTLTexture) -> [[UInt8]] {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return stride(from: 0, to: bytes.count, by: 4).map { index in
            [bytes[index + 2], bytes[index + 1], bytes[index], bytes[index + 3]]
        }
    }

    func assertSynchronizedFallbackSurfaceIsReleasedBeforeFreehandCopyOnWrite() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let size = CGSize(width: 128, height: 128)
        let displayScale = 1.0
        let viewport = try! CanvasViewport.identity(
            size: .init(width: size.width, height: size.height)
        )
        let fallback = preparedGeometry(
            path: .init(commands: [
                .move(.init(x: 12, y: 18)),
                .cubic(
                    control1: .init(x: 34, y: 2),
                    control2: .init(x: 78, y: 5),
                    end: .init(x: 106, y: 24)
                ),
                .line(.init(x: 92, y: 72)),
                .quad(control: .init(x: 54, y: 52), end: .init(x: 20, y: 76)),
                .close,
            ]),
            style: .init(
                stroke: .black,
                fill: .init(red: 0.3, green: 0.6, blue: 0.9),
                lineWidth: 3
            )
        )
        let polyline = CanvasPreparedInk(points: [
            .init(x: 18, y: 96),
            .init(x: 46, y: 104),
            .init(x: 76, y: 94),
        ])
        let freehandID = UUID()
        func freehandGeometry() -> CanvasPreparedGeometry {
            CanvasPreparedGeometry(
                id: freehandID,
                renderKey: .preview(id: freehandID, generation: .zero),
                path: .ink(polyline),
                bounds: .init(x: 18, y: 94, width: 58, height: 10),
                style: .init(stroke: .black, lineWidth: 4)
            )
        }
        func destinationTexture() throws -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: Int(size.width),
                height: Int(size.height),
                mipmapped: false
            )
            descriptor.usage = .renderTarget
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }

        let compiler = MetalSceneCompiler()
        let fallbackCompiled = try compiler.compile(preparedScene(
            geometry: [fallback],
            viewport: viewport,
            background: .init(red: 0, green: 0, blue: 0, alpha: 0)
        ))
        let fallbackProbe = try MetalRenderEngine(device: device)
        try fallbackProbe.render(
            fallbackCompiled,
            into: destinationTexture(),
            size: size,
            displayScale: displayScale
        )

        let estimatorResources = MetalResourceCache(
            device: device,
            budgetBytes: CanvasMetalLimits.resourceBudgetBytes
        )
        let estimatorPipelines = try MetalPipelineLibrary(device: device)
        let coverageEstimator = try MetalFreehandCoverageCache(
            device: device,
            coveragePipeline: estimatorPipelines.coverageSegment,
            resourceCache: estimatorResources
        )
        let coverageEstimate = try coverageEstimator.estimatedCoverageByteCount(
            geometry: freehandGeometry(),
            viewport: viewport,
            displayScale: displayScale
        )
        let budget = fallbackProbe.maximumOwnedCoverageByteCount * 2
            + coverageEstimate * 2
        XCTAssertLessThanOrEqual(budget, CanvasMetalLimits.resourceBudgetBytes)

        let engine = try MetalRenderEngine(
            device: device,
            resourceBudgetBytes: budget
        )
        var firstCommandBuffer: (any MTLCommandBuffer)?
        var secondCommandBuffer: (any MTLCommandBuffer)?
        defer {
            firstCommandBuffer?.waitUntilCompleted()
            secondCommandBuffer?.waitUntilCompleted()
        }
        let initialScene = try compiler.compile(preparedScene(
            geometry: [fallback, freehandGeometry()],
            viewport: viewport,
            background: .init(red: 0, green: 0, blue: 0, alpha: 0)
        ))
        let firstDestination = try destinationTexture()
        try engine.render(
            initialScene,
            into: firstDestination,
            size: size,
            displayScale: displayScale,
            configureFinalOutputCommandBuffer: { commandBuffer in
                firstCommandBuffer = commandBuffer
            }
        )
        XCTAssertEqual(engine.inFlightResourceLeaseCount, 1)
        XCTAssertEqual(engine.outputCommandBufferCount, 1)
        XCTAssertEqual(engine.synchronousOutputWaitCount, 0)

        polyline.append([
            .init(x: 98, y: 105),
            .init(x: 112, y: 92),
        ])
        let grownScene = try compiler.compile(preparedScene(
            geometry: [fallback, freehandGeometry()],
            viewport: viewport,
            background: .init(red: 0, green: 0, blue: 0, alpha: 0)
        ))
        let secondDestination = try destinationTexture()
        try engine.render(
            grownScene,
            into: secondDestination,
            size: size,
            displayScale: displayScale,
            configureFinalOutputCommandBuffer: { secondCommandBuffer = $0 }
        )
        XCTAssertEqual(engine.outputCommandBufferCount, 2)
        XCTAssertEqual(engine.synchronousOutputWaitCount, 0)
        XCTAssertLessThanOrEqual(engine.maximumOwnedCoverageByteCount, budget)
    }

    func rgbaPixel(_ texture: any MTLTexture, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(
            &bytes,
            bytesPerRow: 4,
            from: MTLRegionMake2D(x, y, 1, 1),
            mipmapLevel: 0
        )
        return [bytes[2], bytes[1], bytes[0], bytes[3]]
    }

    func rgbaPixels(_ image: CGImage) -> [[UInt8]] {
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: bytes.count, by: 4).map { index in
            Array(bytes[index..<(index + 4)])
        }
    }

    /// Builds an independent raster boundary band from 4x binary fill and stroke masks.
    /// Fine-grid coverage transitions identify output pixel squares intersected by the
    /// geometric boundary. A 3x3 output-pixel square structuring element then performs a
    /// rigorously defined one-device-pixel morphological dilation. The oracle never inspects
    /// the colored reference image.
    func geometricEdgeBand(
        geometry: [CanvasPreparedGeometry],
        viewport: CanvasViewport,
        width: Int,
        height: Int,
        displayScale: Double
    ) throws -> [Bool] {
        let maskScale = 4
        let maskWidth = width * maskScale
        let maskHeight = height * maskScale
        var band = [Bool](repeating: false, count: width * height)
        for item in geometry {
            guard case .immutable(let path) = item.path else { continue }
            if item.style.fill?.alpha ?? 0 > 0 {
                addBoundaryBand(
                    mask: try geometryMask(
                        path: path,
                        viewport: viewport,
                        width: maskWidth,
                        height: maskHeight,
                        displayScale: displayScale * Double(maskScale),
                        strokeWidth: nil
                    ),
                    maskWidth: maskWidth,
                    maskHeight: maskHeight,
                    outputWidth: width,
                    outputHeight: height,
                    maskScale: maskScale,
                    to: &band
                )
            }
            if item.style.stroke.alpha > 0, item.style.lineWidth > 0 {
                addBoundaryBand(
                    mask: try geometryMask(
                        path: path,
                        viewport: viewport,
                        width: maskWidth,
                        height: maskHeight,
                        displayScale: displayScale * Double(maskScale),
                        strokeWidth: item.style.lineWidth / viewport.zoom
                    ),
                    maskWidth: maskWidth,
                    maskHeight: maskHeight,
                    outputWidth: width,
                    outputHeight: height,
                    maskScale: maskScale,
                    to: &band
                )
            }
        }
        return band
    }

    func geometryMask(
        path: CanvasPath,
        viewport: CanvasViewport,
        width: Int,
        height: Int,
        displayScale: Double,
        strokeWidth: Double?
    ) throws -> [Bool] {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)
        context.scaleBy(x: displayScale, y: displayScale)
        context.concatenate(CGAffineTransform(
            a: viewport.zoom,
            b: 0,
            c: 0,
            d: viewport.zoom,
            tx: viewport.translation.x,
            ty: viewport.translation.y
        ))
        context.addPath(cgPath(path))
        context.setFillColor(gray: 1, alpha: 1)
        context.setStrokeColor(gray: 1, alpha: 1)
        if let strokeWidth {
            context.setLineWidth(strokeWidth)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.strokePath()
        } else {
            context.fillPath(using: .winding)
        }
        let image = try XCTUnwrap(context.makeImage())
        let pixels = rgbaPixels(image)
        return pixels.map { $0[0] >= 128 }
    }

    func cgPath(_ path: CanvasPath) -> CGPath {
        let result = CGMutablePath()
        for command in path.commands {
            switch command {
            case .move(let point):
                result.move(to: .init(x: point.x, y: point.y))
            case .line(let point):
                result.addLine(to: .init(x: point.x, y: point.y))
            case .quad(let control, let end):
                result.addQuadCurve(
                    to: .init(x: end.x, y: end.y),
                    control: .init(x: control.x, y: control.y)
                )
            case .cubic(let control1, let control2, let end):
                result.addCurve(
                    to: .init(x: end.x, y: end.y),
                    control1: .init(x: control1.x, y: control1.y),
                    control2: .init(x: control2.x, y: control2.y)
                )
            case .close:
                result.closeSubpath()
            }
        }
        return result
    }

    func addBoundaryBand(
        mask: [Bool],
        maskWidth: Int,
        maskHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        maskScale: Int,
        to band: inout [Bool]
    ) {
        var boundary = [Bool](repeating: false, count: outputWidth * outputHeight)
        func markOutputPixel(maskX: Int, maskY: Int) {
            let outputX = min(outputWidth - 1, maskX / maskScale)
            let outputY = min(outputHeight - 1, maskY / maskScale)
            boundary[outputY * outputWidth + outputX] = true
        }
        for y in 0..<maskHeight {
            for x in 0..<maskWidth {
                let offset = y * maskWidth + x
                if x + 1 < maskWidth, mask[offset] != mask[offset + 1] {
                    markOutputPixel(maskX: x, maskY: y)
                    markOutputPixel(maskX: x + 1, maskY: y)
                }
                if y + 1 < maskHeight,
                   mask[offset] != mask[offset + maskWidth] {
                    markOutputPixel(maskX: x, maskY: y)
                    markOutputPixel(maskX: x, maskY: y + 1)
                }
                if (x == 0 || x == maskWidth - 1
                    || y == 0 || y == maskHeight - 1), mask[offset] {
                    markOutputPixel(maskX: x, maskY: y)
                }
            }
        }
        for y in 0..<outputHeight {
            for x in 0..<outputWidth where boundary[y * outputWidth + x] {
                for dilatedY in max(0, y - 1)...min(outputHeight - 1, y + 1) {
                    for dilatedX in max(0, x - 1)...min(outputWidth - 1, x + 1) {
                        band[dilatedY * outputWidth + dilatedX] = true
                    }
                }
            }
        }
    }
}
