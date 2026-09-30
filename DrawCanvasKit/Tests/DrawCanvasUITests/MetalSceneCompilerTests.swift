import CoreGraphics
import DrawCanvasCore
import Metal
import XCTest
@testable import DrawCanvasUI

@MainActor
final class MetalSceneCompilerTests: XCTestCase {
    func testFreehandPaintedBoundsRespectPersistedWidthMode() throws {
        let viewport = try CanvasViewport(
            zoom: 2,
            translation: .init(x: 0, y: 0),
            viewportSize: .init(width: 128, height: 112)
        )
        for (widthMode, expectedExpansion) in [
            (CanvasInkWidthMode.canvasScaled, 3.75),
            (.screenConstant, 2.0),
        ] {
            let id = UUID()
            let geometry = preparedInkGeometry(
                samples: [
                    .init(point: .init(x: 20, y: 30), pressure: 1),
                    .init(point: .init(x: 60, y: 30), pressure: 1),
                ],
                renderKey: .committed(id: id, contentRevision: 0),
                pressureEnabled: true,
                widthMode: widthMode,
                style: .init(stroke: .black, lineWidth: 4)
            )
            let scene = preparedScene(geometry: [geometry], viewport: viewport)
            let presentation = preparedPresentation(
                scene: scene,
                committed: [.init(
                    documentIndex: 0,
                    geometry: geometry,
                    paintedBounds: geometry.bounds
                )]
            )

            let compiled = try MetalSceneCompiler().compile(presentation, displayScale: 2)
            let bounds = try XCTUnwrap(compiled.committedItems.first).paintedBounds
            XCTAssertEqual(
                bounds.minX,
                geometry.bounds.minX - expectedExpansion,
                accuracy: 1e-12
            )
        }
    }

    func testFreehandPaintedBoundsUsePressureSpecificMaximum() throws {
        for (pressureEnabled, expectedExpansion) in [(true, 2.0), (false, 1.25)] {
            let id = UUID()
            let geometry = preparedInkGeometry(
                samples: [
                    .init(point: .init(x: 20, y: 30), pressure: 1),
                    .init(point: .init(x: 60, y: 30), pressure: 1),
                ],
                renderKey: .committed(id: id, contentRevision: 0),
                pressureEnabled: pressureEnabled,
                widthMode: .screenConstant,
                style: .init(stroke: .black, lineWidth: 4)
            )
            let scene = preparedScene(
                geometry: [geometry],
                viewport: try .init(
                    zoom: 2,
                    translation: .init(x: 0, y: 0),
                    viewportSize: .init(width: 128, height: 112)
                )
            )
            let presentation = preparedPresentation(
                scene: scene,
                committed: [.init(
                    documentIndex: 0,
                    geometry: geometry,
                    paintedBounds: geometry.bounds
                )]
            )
            let compiled = try MetalSceneCompiler().compile(presentation, displayScale: 2)
            let bounds = try XCTUnwrap(compiled.committedItems.first).paintedBounds

            XCTAssertEqual(
                bounds.minX,
                geometry.bounds.minX - expectedExpansion,
                accuracy: 1e-12
            )
            XCTAssertEqual(
                bounds.maxX,
                geometry.bounds.maxX + expectedExpansion,
                accuracy: 1e-12
            )
        }
    }

    func testWarmFreehandFrameReusesCompiledCommittedLayerWithoutVisits() throws {
        let elements = (0 ..< 100).map { index in
            CanvasElement(
                id: UUID(),
                geometry: .freehand(.init(
                    samples: [
                        .init(point: .init(x: 8, y: Double(index + 8)), pressure: 1),
                        .init(point: .init(x: 112, y: Double(index + 8)), pressure: 1),
                    ],
                    pressureEnabled: true
                )),
                style: .init(stroke: .black, lineWidth: 2)
            )
        }
        let document = CanvasDocument(elements: elements)
        let viewport = try CanvasViewport.identity(size: .init(width: 128, height: 128))
        let preparer = CanvasScenePreparer()
        let compiler = MetalSceneCompiler()
        let committed = try preparer.prepare(
            document: document,
            preview: nil,
            viewport: viewport,
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        )
        let first = try compiler.compile(committed, displayScale: 2)
        let draft = CanvasFreehandDraft(
            id: UUID(),
            style: .init(stroke: .black, lineWidth: 2)
        )
        draft.append([
            .init(point: .init(x: 8, y: 120), pressure: 0.4),
            .init(point: .init(x: 16, y: 120), pressure: 0.6),
        ])
        var generation = RecognitionGeneration.zero
        generation.advance()
        var preview = CanvasRenderPreview(
            freehand: draft,
            predictedInkSamples: [],
            generation: generation
        )
        let firstLivePresentation = try preparer.prepare(
            document: document,
            preview: preview,
            viewport: viewport,
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        )
        let firstLive = try compiler.compile(firstLivePresentation, displayScale: 2)
        let visitsBeforeSecondLive = compiler.statistics.committedItemVisitCount
        generation.advance()
        draft.append([.init(point: .init(x: 24, y: 118), pressure: 0.8)])
        XCTAssertTrue(preview.update(
            freehand: draft,
            predictedInkSamples: [],
            generation: generation
        ))
        let secondLivePresentation = try preparer.prepare(
            document: document,
            preview: preview,
            viewport: viewport,
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: CanvasTheme.default.renderSnapshot
        )
        let secondLive = try compiler.compile(secondLivePresentation, displayScale: 2)

        XCTAssertTrue(first.committedLayer === firstLive.committedLayer)
        XCTAssertTrue(firstLive.committedLayer === secondLive.committedLayer)
        XCTAssertEqual(
            compiler.statistics.committedItemVisitCount,
            visitsBeforeSecondLive
        )
        XCTAssertEqual(secondLive.liveItems.count, 1)
    }

    func testCompiledCommittedLayerInvalidatesForTransformAndReset() throws {
        let id = UUID()
        let committedGeometry = CanvasPreparedGeometry(
            id: id,
            renderKey: .committed(id: id, contentRevision: 0),
            path: .immutable(.init(commands: [
                .move(.init(x: 0, y: 0)),
                .line(.init(x: 40, y: 40)),
            ])),
            bounds: .init(x: 0, y: 0, width: 40, height: 40),
            style: .default
        )
        let baseScene = preparedScene(geometry: [committedGeometry])
        let presentation = preparedPresentation(
            scene: baseScene,
            committed: [
                .init(
                    documentIndex: 0,
                    geometry: committedGeometry,
                    paintedBounds: committedGeometry.bounds
                ),
            ]
        )
        let compiler = MetalSceneCompiler()

        let first = try compiler.compile(presentation, displayScale: 1)
        let scaled = try compiler.compile(presentation, displayScale: 2)
        compiler.resetDerivedRenderCaches()
        let reset = try compiler.compile(presentation, displayScale: 2)

        XCTAssertFalse(first.committedLayer === scaled.committedLayer)
        XCTAssertFalse(scaled.committedLayer === reset.committedLayer)
    }

    func testCompilerPreparesOneInkCandidateAcrossBothCoordinateOriginPasses() throws {
        let ink = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: .init(x: 10, y: 12), pressure: 0.2),
                .init(point: .init(x: 18, y: 25), pressure: 0.6),
                .init(point: .init(x: 31, y: 19), pressure: 0.9),
            ],
            predictedSamples: [
                .init(point: .init(x: 38, y: 22), pressure: 0.7),
            ],
            pressureEnabled: true,
            isFinalized: false
        )
        let id = UUID()
        let geometry = CanvasPreparedGeometry(
            id: id,
            renderKey: .preview(id: id, generation: ink.generation),
            path: .ink(ink),
            bounds: .init(x: 10, y: 12, width: 28, height: 13),
            style: .default
        )
        let compiler = MetalSceneCompiler()

        let compiled = try compiler.compile(preparedScene(geometry: [geometry]))

        XCTAssertEqual(compiler.statistics.preparedFreehandCandidateCount, 1)
        XCTAssertEqual(compiler.statistics.validatedFreehandPointCount, 4)
        XCTAssertEqual(compiled.items.map(drawItemKind), ["freehand"])
        XCTAssertEqual(compiled.renderItems.map(drawItemKind), ["freehand"])
    }

    func testCompilerValidatesOnlyConfirmedSuffixAndReplacementPredictions() throws {
        let ink = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: .init(x: 3, y: 4), pressure: 0.2),
                .init(point: .init(x: 7, y: 9), pressure: 0.5),
                .init(point: .init(x: 12, y: 6), pressure: 0.8),
            ],
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: false
        )
        let id = UUID()
        let compiler = MetalSceneCompiler()
        func geometry() -> CanvasPreparedGeometry {
            CanvasPreparedGeometry(
                id: id,
                renderKey: .preview(id: id, generation: ink.generation),
                path: .ink(ink),
                bounds: .init(x: 3, y: 4, width: 20, height: 12),
                style: .default
            )
        }

        _ = try compiler.compile(preparedScene(geometry: [geometry()]))
        XCTAssertEqual(compiler.statistics.validatedFreehandPointCount, 3)
        XCTAssertTrue(ink.apply(
            confirmed: ink.confirmedSamples + [
                .init(point: .init(x: 17, y: 13), pressure: 0.4),
                .init(point: .init(x: 23, y: 8), pressure: 0.7),
            ],
            predicted: [
                .init(point: .init(x: 28, y: 11), pressure: 0.6),
            ],
            isFinalized: false
        ))

        _ = try compiler.compile(preparedScene(geometry: [geometry()]))
        XCTAssertEqual(compiler.statistics.preparedFreehandCandidateCount, 2)
        XCTAssertEqual(
            compiler.statistics.validatedFreehandPointCount,
            6,
            "Only two confirmed suffix points and the replacement prediction should validate"
        )

        let shiftedViewport = try! CanvasViewport(
            zoom: 2,
            translation: .init(x: -40, y: 18),
            viewportSize: .init(width: 128, height: 112)
        )
        _ = try compiler.compile(preparedScene(
            geometry: [geometry()],
            viewport: shiftedViewport
        ))
        XCTAssertEqual(
            compiler.statistics.preparedFreehandCandidateCount,
            2,
            "Viewport changes must reuse validation for unchanged ink"
        )
        XCTAssertEqual(compiler.statistics.validatedFreehandPointCount, 6)
    }

    func testCompilerReplacementInkIdentityColdValidatesAllSamples() throws {
        let id = UUID()
        let compiler = MetalSceneCompiler()
        func geometry(_ ink: CanvasPreparedInk) -> CanvasPreparedGeometry {
            CanvasPreparedGeometry(
                id: id,
                renderKey: .preview(id: id, generation: ink.generation),
                path: .ink(ink),
                bounds: .init(x: 2, y: 3, width: 8, height: 6),
                style: .default
            )
        }
        let first = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: .init(x: 2, y: 3), pressure: 0.3),
                .init(point: .init(x: 10, y: 9), pressure: 0.7),
            ],
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: false
        )
        _ = try compiler.compile(preparedScene(geometry: [geometry(first)]))

        let replacement = CanvasPreparedInk(
            confirmedSamples: first.confirmedSamples,
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: false
        )
        _ = try compiler.compile(preparedScene(geometry: [geometry(replacement)]))

        XCTAssertEqual(compiler.statistics.preparedFreehandCandidateCount, 2)
        XCTAssertEqual(compiler.statistics.validatedFreehandPointCount, 4)
    }

    func testCompilerRejectsNonfiniteInkPressureWithoutPublishingValidationState() throws {
        let ink = CanvasPreparedInk(
            confirmedSamples: [
                .init(point: .init(x: 12, y: 18), pressure: 0.4),
                .init(point: .init(x: 42, y: 36), pressure: .nan),
            ],
            predictedSamples: [],
            pressureEnabled: true,
            isFinalized: true
        )
        let id = UUID()
        let geometry = CanvasPreparedGeometry(
            id: id,
            renderKey: .preview(id: id, generation: ink.generation),
            path: .ink(ink),
            bounds: .init(x: 12, y: 18, width: 30, height: 18),
            style: .default
        )
        let compiler = MetalSceneCompiler()

        XCTAssertThrowsError(try compiler.compile(preparedScene(geometry: [geometry]))) {
            XCTAssertEqual($0 as? MetalCanvasError, .invalidNumericInput)
        }
        XCTAssertEqual(compiler.statistics.validatedFreehandPointCount, 0)
        XCTAssertEqual(compiler.statistics.preparedFreehandCandidateCount, 0)
    }

    func testCompilerPreservesBackgroundGridGeometryOverlayOrder() throws {
        let line = preparedGeometry(
            path: CanvasPath(commands: [
                .move(.init(x: 10, y: 10)),
                .line(.init(x: 30, y: 10)),
            ])
        )
        let rectangle = preparedGeometry(
            path: rectanglePath(.init(x: 40, y: 20, width: 20, height: 15))
        )
        let scene = preparedScene(
            geometry: [line, rectangle],
            gridLines: [.init(
                start: .init(x: 0, y: 5),
                end: .init(x: 100, y: 5)
            )],
            selectionBounds: .init(x: 40, y: 20, width: 20, height: 15),
            guides: [.vertical(canvasX: 75)]
        )

        let compiled = try MetalSceneCompiler().compile(scene)

        XCTAssertEqual(compiled.background, SIMD4<Float>(1, 1, 1, 1))
        XCTAssertEqual(compiled.items.map(drawItemKind), [
            "line", // grid
            "line", // first geometry
            "box",  // second geometry
            "line", "line", "line", "line", // dashed selection outline
            "box", "box", "box", "box", // selection handles
            "line", // guide
        ])
    }

    func testPresentationCompilerPartitionsCommittedLiveGridAndOverlayLayers() throws {
        let committed = [
            preparedGeometry(
                path: .init(commands: [
                    .move(.init(x: 10, y: 10)),
                    .line(.init(x: 30, y: 10)),
                ]),
                style: .init(stroke: .black, lineWidth: 4)
            ),
            preparedGeometry(path: rectanglePath(.init(x: 40, y: 20, width: 20, height: 15))),
            preparedGeometry(path: CanvasGeometry.arch(.init(
                start: .init(x: 10, y: 50),
                end: .init(x: 50, y: 50),
                sagitta: 12
            )).renderPath),
            preparedInkGeometry(
                samples: [
                    .init(point: .init(x: 12, y: 70), pressure: 0.4),
                    .init(point: .init(x: 35, y: 82), pressure: 0.8),
                ],
                renderKey: .committed(id: UUID(), contentRevision: 0)
            ),
            preparedGeometry(path: .init(commands: [
                .move(.init(x: 10_000, y: 10_000)),
                .quad(
                    control: .init(x: 10_020, y: 9_980),
                    end: .init(x: 10_040, y: 10_000)
                ),
                .line(.init(x: 10_020, y: 10_040)),
                .close,
            ])),
        ]
        let draft = preparedInkGeometry(
            samples: [
                .init(point: .init(x: 65, y: 60), pressure: 0.3),
                .init(point: .init(x: 85, y: 75), pressure: 0.7),
            ],
            renderKey: .preview(id: UUID(), generation: .zero)
        )
        let scene = preparedScene(
            geometry: [committed[0], draft],
            gridLines: [.init(
                start: .init(x: 0, y: 5),
                end: .init(x: 100, y: 5)
            )],
            selectionBounds: committed[0].bounds,
            guides: [.vertical(canvasX: 75)],
            viewport: try! .init(
                zoom: 2,
                translation: .init(x: 0, y: 0),
                viewportSize: .init(width: 128, height: 112)
            )
        )
        let presentation = preparedPresentation(
            scene: scene,
            committed: committed.enumerated().map {
                CanvasCommittedItem(
                    documentIndex: $0.offset,
                    geometry: $0.element,
                    paintedBounds: .init(x: -1, y: -1, width: 1, height: 1)
                )
            }
        )

        let compiled = try MetalSceneCompiler().compile(presentation, displayScale: 2)

        XCTAssertEqual(compiled.gridItems.map(drawItemKind), ["line"])
        XCTAssertEqual(compiled.committedItems.map(\.documentIndex), [0, 1, 2, 3, 4])
        XCTAssertEqual(compiled.committedItems.map { drawItemKind($0.item) }, [
            "line", "box", "arc", "freehand", "fallback",
        ])
        XCTAssertEqual(compiled.liveItems.map(drawItemKind), ["freehand"])
        XCTAssertEqual(compiled.overlayItems.map(drawItemKind), [
            "line", "line", "line", "line", "box", "box", "box", "box", "line",
        ])
        XCTAssertEqual(compiled.committedItems[0].paintedBounds, .init(
            x: 8.75,
            y: 8.75,
            width: 22.5,
            height: 2.5
        ))
        XCTAssertEqual(compiled.committedGeneration, presentation.committed.generation)
        XCTAssertEqual(compiled.viewportRenderPhase, .settled)
    }

    func testPresentationCompilerRepresentsReplacementAtOriginalCommittedIndex() throws {
        let originals = [
            preparedGeometry(path: rectanglePath(.init(x: 5, y: 5, width: 10, height: 10))),
            preparedGeometry(path: rectanglePath(.init(x: 20, y: 5, width: 10, height: 10))),
            preparedGeometry(path: rectanglePath(.init(x: 35, y: 5, width: 10, height: 10))),
        ]
        let replacementID = UUID()
        let replacement = preparedGeometry(
            id: replacementID,
            renderKey: .preview(id: replacementID, generation: .zero),
            path: .init(commands: [
                .move(.init(x: 20, y: 20)),
                .line(.init(x: 45, y: 30)),
            ])
        )
        let scene = preparedScene(geometry: [originals[0], replacement, originals[2]])
        let committedItems = originals.enumerated().map {
            CanvasCommittedItem(
                documentIndex: $0.offset,
                geometry: $0.element,
                paintedBounds: $0.element.bounds
            )
        }
        let presentation = preparedPresentation(
            scene: scene,
            committed: committedItems,
            replacement: .init(
                documentIndex: 1,
                originalGeometry: originals[1],
                originalPaintedBounds: originals[1].bounds,
                replacementGeometry: replacement,
                replacementPaintedBounds: replacement.bounds
            ),
            phase: .interactive
        )

        let compiled = try MetalSceneCompiler().compile(presentation)

        XCTAssertEqual(compiled.committedItems.map(\.documentIndex), [0, 1, 2])
        XCTAssertEqual(compiled.liveItems.count, 0)
        XCTAssertEqual(compiled.replacement?.documentIndex, 1)
        XCTAssertEqual(compiled.replacement.map { drawItemKind($0.original.item) }, "box")
        XCTAssertEqual(compiled.replacement.map { drawItemKind($0.replacement.item) }, "line")
        XCTAssertEqual(compiled.viewportRenderPhase, .interactive)
    }

    func testCommittedGeometryRebasesBeforeFloatConversionAtHugeCoordinates() throws {
        let base = 1_000_000_000_000.0
        let geometry = preparedGeometry(path: .init(commands: [
            .move(.init(x: base + 12, y: base + 20)),
            .line(.init(x: base + 44, y: base + 52)),
        ]))
        let presentation = preparedPresentation(
            scene: preparedScene(),
            committed: [.init(
                documentIndex: 0,
                geometry: geometry,
                paintedBounds: geometry.bounds
            )]
        )
        let compiler = MetalSceneCompiler()
        let compiled = try compiler.compile(presentation)

        let rebased = try compiler.compileCommittedItem(
            compiled.committedItems[0],
            coordinateOrigin: .init(x: base, y: base),
            zoom: 1,
            displayScale: 2
        )

        guard case .analyticLine(let line) = rebased else {
            return XCTFail("Expected analytic line")
        }
        XCTAssertEqual(line.start, SIMD2<Float>(12, 20))
        XCTAssertEqual(line.end, SIMD2<Float>(44, 52))
        XCTAssertTrue(line.start.x.isFinite)
        XCTAssertTrue(line.end.y.isFinite)
    }

    func testLineInstancesPreserveColorWidthCapsAndViewport() throws {
        let viewport = try! CanvasViewport(
            zoom: 2,
            translation: .init(x: 7, y: -3),
            viewportSize: .init(width: 120, height: 80)
        )
        let style = CanvasStyle(
            stroke: .init(red: 0.8, green: 0.4, blue: 0.2, alpha: 0.5),
            lineWidth: 6
        )
        let scene = preparedScene(
            geometry: [preparedGeometry(
                path: .init(commands: [
                    .move(.init(x: 11, y: 13)),
                    .line(.init(x: 41, y: 29)),
                ]),
                style: style
            )],
            viewport: viewport
        )

        let compiled = try MetalSceneCompiler().compile(scene)
        guard case .analyticLine(let instance) = try XCTUnwrap(compiled.items.first) else {
            return XCTFail("Expected analytic line")
        }

        XCTAssertEqual(instance.start, SIMD2<Float>(11, 13))
        XCTAssertEqual(instance.end, SIMD2<Float>(41, 29))
        XCTAssertEqual(instance.color, SIMD4<Float>(0.4, 0.2, 0.1, 0.5))
        XCTAssertEqual(instance.lineWidth, 3)
        XCTAssertEqual(compiled.viewport, viewport)
    }

    func testRectangleInstancesPreserveFillAndStroke() throws {
        let rect = CanvasRect(x: 12, y: 18, width: 34, height: 27)
        let style = CanvasStyle(
            stroke: .init(red: 1, green: 0.25, blue: 0, alpha: 0.8),
            fill: .init(red: 0, green: 0.5, blue: 1, alpha: 0.4),
            lineWidth: 5
        )

        let compiled = try MetalSceneCompiler().compile(preparedScene(
            geometry: [preparedGeometry(path: rectanglePath(rect), style: style)]
        ))
        guard case .analyticBox(let instance) = try XCTUnwrap(compiled.items.first) else {
            return XCTFail("Expected analytic box")
        }

        XCTAssertEqual(instance.origin, SIMD2<Float>(12, 18))
        XCTAssertEqual(instance.size, SIMD2<Float>(34, 27))
        XCTAssertEqual(instance.fillColor, SIMD4<Float>(0, 0.2, 0.4, 0.4))
        XCTAssertEqual(instance.strokeColor, SIMD4<Float>(0.8, 0.2, 0, 0.8))
        XCTAssertEqual(instance.lineWidth, 5)
    }

    func testArchInstancesPreserveSignedSagittaAndEndpoints() throws {
        let arch = CanvasArch(
            start: .init(x: 10, y: 40),
            end: .init(x: 90, y: 40),
            sagitta: -24
        )
        let expected = try ArchGeometry.parameters(for: arch)
        let geometry = preparedGeometry(path: CanvasGeometry.arch(arch).renderPath)

        let compiled = try MetalSceneCompiler().compile(preparedScene(geometry: [geometry]))
        guard case .analyticArc(let instance) = try XCTUnwrap(compiled.items.first) else {
            return XCTFail("Expected analytic arc")
        }

        XCTAssertEqual(instance.start, SIMD2<Float>(10, 40))
        XCTAssertEqual(instance.end, SIMD2<Float>(90, 40))
        assertEqual(instance.center, expected.center)
        XCTAssertEqual(instance.radius, Float(expected.radius), accuracy: 0.0001)
        XCTAssertEqual(instance.sweepAngle, Float(expected.sweepAngle), accuracy: 0.0001)
        XCTAssertGreaterThan(instance.sweepAngle, 0, "Negative sagitta must retain sweep sign")

        let filledPath = CanvasGeometry.arch(.init(
            start: .init(x: 14, y: 52),
            end: .init(x: 94, y: 52),
            sagitta: 26
        )).renderPath
        let filledStyle = CanvasStyle(
            stroke: .init(red: 0.8, green: 0.2, blue: 0.1, alpha: 0.75),
            fill: .init(red: 0.1, green: 0.6, blue: 0.9, alpha: 0.5),
            lineWidth: 4
        )
        let filledGeometry = preparedGeometry(path: filledPath, style: filledStyle)

        let filledCompiled = try MetalSceneCompiler().compile(preparedScene(
            geometry: [filledGeometry]
        ))
        guard case .fallback(let descriptor) = try XCTUnwrap(filledCompiled.items.first) else {
            return XCTFail("Filled canonical arcs must retain exact content for fallback rendering")
        }

        XCTAssertEqual(descriptor.geometry.id, filledGeometry.id)
        XCTAssertEqual(descriptor.geometry.renderKey, filledGeometry.renderKey)
        XCTAssertEqual(descriptor.geometry.resourceIdentity, filledGeometry.resourceIdentity)
        XCTAssertEqual(descriptor.geometry.bounds, filledGeometry.bounds)
        XCTAssertEqual(descriptor.geometry.style, filledStyle)
        guard case .immutable(let preservedPath) = descriptor.geometry.path else {
            return XCTFail("Expected the immutable canonical arc path to be retained")
        }
        XCTAssertEqual(preservedPath, filledPath)
    }

    func testSelectionAndGuideMetricsRemainScreenConstant() throws {
        let theme = CanvasThemeSnapshot(
            background: .init(red: 1, green: 1, blue: 1),
            grid: .init(red: 0.8, green: 0.8, blue: 0.8),
            stroke: .black,
            selection: .init(red: 0, green: 0.4, blue: 1),
            guides: .init(red: 1, green: 0, blue: 0),
            gridLineWidth: 1.5,
            selectionLineWidth: 3,
            handleSize: 12
        )
        let viewport = try! CanvasViewport(
            zoom: 4,
            translation: .init(x: 2, y: 3),
            viewportSize: .init(width: 100, height: 80)
        )
        let compiled = try MetalSceneCompiler().compile(preparedScene(
            selectionBounds: .init(x: 10, y: 12, width: 30, height: 20),
            guides: [.horizontal(canvasY: 25)],
            viewport: viewport,
            theme: theme
        ))

        guard case .analyticLine(let outline) = compiled.items[0],
              case .analyticBox(let firstHandle) = compiled.items[4],
              case .analyticLine(let guide) = compiled.items[8] else {
            return XCTFail("Expected selection outline, handles, then guide")
        }
        XCTAssertEqual(outline.lineWidth * Float(viewport.zoom), 3)
        XCTAssertEqual(outline.dashPeriod * Float(viewport.zoom), 7)
        XCTAssertEqual(outline.start, SIMD2<Float>(9, 11))
        XCTAssertEqual(firstHandle.size.x * Float(viewport.zoom), 12)
        XCTAssertEqual(firstHandle.size.y * Float(viewport.zoom), 12)
        XCTAssertEqual(guide.lineWidth * Float(viewport.zoom), 3)
    }

    func testCompilerClassifiesAppendOnlyAndFallbackPathsWithoutText() throws {
        let polyline = CanvasPreparedInk(points: [
            .init(x: 3, y: 4),
            .init(x: 8, y: 9),
        ])
        let appendOnly = CanvasPreparedGeometry(
            id: UUID(),
            renderKey: .preview(id: UUID(), generation: polyline.generation),
            path: .ink(polyline),
            bounds: .init(x: 3, y: 4, width: 5, height: 5),
            style: .default
        )
        let fallback = preparedGeometry(path: .init(commands: [
            .move(.init(x: 20, y: 20)),
            .quad(control: .init(x: 30, y: 5), end: .init(x: 40, y: 20)),
        ]))
        let text = CanvasElement(
            id: UUID(),
            geometry: .text(.init(
                frame: .init(x: 0, y: 0, width: 20, height: 10),
                text: "UIKit only",
                font: .init(familyName: "Helvetica", pointSize: 12),
                color: .black
            ))
        )
        let preparedTextScene = try CanvasScenePreparer().prepare(
            document: .init(elements: [text]),
            preview: nil,
            viewport: .identity(size: .init(width: 100, height: 80)),
            selectedElementID: nil,
            editingTextIDs: [],
            guides: [],
            gridSpacing: 20,
            theme: theme()
        ).scene
        XCTAssertTrue(preparedTextScene.geometry.isEmpty)

        let compiled = try MetalSceneCompiler().compile(preparedScene(
            geometry: [appendOnly, fallback]
        ))
        guard case .freehand(let freehand) = compiled.items[0],
              case .fallback(let complex) = compiled.items[1] else {
            return XCTFail("Expected future freehand and fallback descriptors")
        }
        XCTAssertEqual(freehand.geometry.id, appendOnly.id)
        XCTAssertEqual(complex.geometry.id, fallback.id)
    }

    func testCompilerRejectsInvalidNumericInputWithoutPartialOutput() throws {
        let invalid = preparedGeometry(path: .init(commands: [
            .move(.init(x: 10, y: 10)),
            .line(.init(x: .nan, y: 20)),
        ]))
        let compiler = MetalSceneCompiler()

        weak var failedPreviewPolyline: CanvasPreparedInk?
        do {
            let polyline = CanvasPreparedInk(points: [
                .init(x: 1, y: 2), .init(x: 3, y: 4),
            ])
            failedPreviewPolyline = polyline
            let id = UUID()
            let preview = CanvasPreparedGeometry(
                id: id,
                renderKey: .preview(id: id, generation: polyline.generation),
                path: .ink(polyline),
                bounds: .init(x: 1, y: 2, width: 2, height: 2),
                style: .default
            )

            XCTAssertThrowsError(try compiler.compile(preparedScene(
                geometry: [preview, invalid]
            ))) {
                XCTAssertEqual($0 as? MetalCanvasError, .invalidNumericInput)
            }
        }
        XCTAssertNil(failedPreviewPolyline)

        XCTAssertThrowsError(try compiler.compile(preparedScene(geometry: [invalid]))) {
            XCTAssertEqual($0 as? MetalCanvasError, .invalidNumericInput)
        }

        let valid = try compiler.compile(preparedScene(geometry: [preparedGeometry(
            path: .init(commands: [
                .move(.init(x: 1, y: 2)),
                .line(.init(x: 3, y: 4)),
            ])
        )]))
        XCTAssertEqual(valid.items.count, 1)
    }

    func testAnalyticOffscreenFixtureMatchesCoreGraphicsInteriorPixels() throws {
        let canvasBase = 8_388_608.5
        let viewport = try! CanvasViewport(
            zoom: 2,
            translation: .init(x: -16_777_216, y: 0),
            viewportSize: .init(width: 128, height: 112)
        )
        let scene = preparedScene(
            geometry: [
                preparedGeometry(
                    path: .init(commands: [
                        .move(.init(x: canvasBase + 6, y: 9)),
                        .line(.init(x: canvasBase + 40, y: 9)),
                    ]),
                    style: .init(
                        stroke: .init(red: 1, green: 0, blue: 0, alpha: 0.5),
                        lineWidth: 8
                    )
                ),
                preparedGeometry(
                    path: rectanglePath(.init(
                        x: canvasBase + 32,
                        y: 5,
                        width: 21,
                        height: 17
                    )),
                    style: .init(
                        stroke: .init(red: 0, green: 0, blue: 1),
                        fill: .init(red: 0, green: 1, blue: 0, alpha: 0.5),
                        lineWidth: 8
                    )
                ),
                preparedGeometry(
                    path: CanvasGeometry.arch(.init(
                        start: .init(x: canvasBase + 9, y: 46),
                        end: .init(x: canvasBase + 53, y: 46),
                        sagitta: -15
                    )).renderPath,
                    style: .init(
                        stroke: .init(red: 0.5, green: 0, blue: 0.5),
                        lineWidth: 8
                    )
                ),
            ],
            gridLines: [.init(
                start: .init(x: canvasBase, y: 4),
                end: .init(x: canvasBase + 64, y: 4)
            )],
            guides: [.vertical(canvasX: canvasBase + 60)],
            viewport: viewport
        )
        let size = CGSize(width: 128, height: 112)
        let displayScale = 2.0
        let compiled = try MetalSceneCompiler().compile(scene)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let texture = try MetalRenderEngine(device: device).renderOffscreen(
            compiled,
            size: size,
            displayScale: displayScale
        )
        let reference = try XCTUnwrap(CoreGraphicsCanvasRenderer().makeBitmap(
            scene: scene,
            bounds: CGRect(origin: .zero, size: size),
            displayScale: displayScale
        ))

        let metalPixels = bgraPixels(texture)
        let referencePixels = rgbaPixels(reference)
        for y in 0..<texture.height {
            for x in 0..<texture.width where !isInFixtureEdgeBand(x: x, y: y) {
                let actual = metalPixels[y * texture.width + x]
                let expected = referencePixels[y * reference.width + x]
                for channel in 0..<4 {
                    XCTAssertLessThanOrEqual(
                        abs(Int(actual[channel]) - Int(expected[channel])),
                        1,
                        "Interior mismatch at (\(x), \(y)) channel \(channel)"
                    )
                }
            }
        }
    }
}

private extension MetalSceneCompilerTests {
    func preparedScene(
        geometry: [CanvasPreparedGeometry] = [],
        gridLines: [CanvasPreparedGridLine] = [],
        selectionBounds: CanvasRect? = nil,
        guides: [SnapGuide] = [],
        viewport: CanvasViewport = try! .identity(size: .init(width: 128, height: 112)),
        theme: CanvasThemeSnapshot? = nil
    ) -> CanvasPreparedScene {
        CanvasPreparedScene(
            geometry: geometry,
            gridLines: gridLines,
            selectionBounds: selectionBounds,
            guides: guides,
            viewport: viewport,
            theme: theme ?? self.theme(),
            previewGeneration: nil
        )
    }

    func preparedGeometry(
        id: UUID = UUID(),
        renderKey: CanvasRenderKey? = nil,
        path: CanvasPath,
        style: CanvasStyle = .default
    ) -> CanvasPreparedGeometry {
        CanvasPreparedGeometry(
            id: id,
            renderKey: renderKey ?? .committed(id: id, contentRevision: 0),
            path: .immutable(path),
            bounds: path.bounds,
            style: style
        )
    }

    func preparedInkGeometry(
        samples: [CanvasInkSample],
        renderKey: CanvasRenderKey,
        pressureEnabled: Bool = true,
        widthMode: CanvasInkWidthMode = .canvasScaled,
        style: CanvasStyle = .default
    ) -> CanvasPreparedGeometry {
        let id: UUID
        switch renderKey {
        case .committed(let value, _), .preview(let value, _):
            id = value
        }
        let ink = CanvasPreparedInk(
            confirmedSamples: samples,
            pressureEnabled: pressureEnabled,
            widthMode: widthMode
        )
        return CanvasPreparedGeometry(
            id: id,
            renderKey: renderKey,
            path: .ink(ink),
            bounds: CanvasRect(
                x: samples.map(\.point.x).min() ?? 0,
                y: samples.map(\.point.y).min() ?? 0,
                width: (samples.map(\.point.x).max() ?? 0) - (samples.map(\.point.x).min() ?? 0),
                height: (samples.map(\.point.y).max() ?? 0) - (samples.map(\.point.y).min() ?? 0)
            ),
            style: style
        )
    }

    func preparedPresentation(
        scene: CanvasPreparedScene,
        committed: [CanvasCommittedItem],
        replacement: CanvasCommittedReplacement? = nil,
        phase: CanvasViewportRenderPhase = .settled
    ) -> CanvasPreparedPresentation {
        CanvasPreparedPresentation(
            scene: scene,
            textDescriptors: [],
            committed: .init(
                generation: .init(
                    documentRevision: 7,
                    replacementGeneration: .zero
                ),
                items: committed,
                replacement: replacement
            ),
            viewportRenderPhase: phase
        )
    }

    func rectanglePath(_ rect: CanvasRect) -> CanvasPath {
        CanvasGeometry.rectangle(.init(rect: rect)).renderPath
    }

    func theme() -> CanvasThemeSnapshot {
        CanvasThemeSnapshot(
            background: .init(red: 1, green: 1, blue: 1),
            grid: .init(red: 0.75, green: 0.75, blue: 0.75),
            stroke: .black,
            selection: .init(red: 0, green: 0.4, blue: 1),
            guides: .init(red: 1, green: 0, blue: 0),
            gridLineWidth: 1,
            selectionLineWidth: 2,
            handleSize: 8
        )
    }

    func drawItemKind(_ item: MetalDrawItem) -> String {
        switch item {
        case .analyticLine: "line"
        case .analyticBox: "box"
        case .analyticArc: "arc"
        case .freehand: "freehand"
        case .fallback: "fallback"
        case .committedTile: "tile"
        }
    }

    func assertEqual(
        _ actual: SIMD2<Float>,
        _ expected: CanvasPoint,
        accuracy: Float = 0.0001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, Float(expected.x), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, Float(expected.y), accuracy: accuracy, file: file, line: line)
    }

    func bgraPixels(_ texture: any MTLTexture) -> [[UInt8]] {
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

    func rgbaPixels(_ image: CGImage) -> [[UInt8]] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map { index in
            Array(bytes[index..<(index + 4)])
        }
    }

    func isInFixtureEdgeBand(x: Int, y: Int) -> Bool {
        let point = CanvasPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
        let gridDistance = segmentDistance(
            point,
            start: .init(x: 2, y: 16),
            end: .init(x: 258, y: 16)
        )
        if abs(gridDistance - 1) <= 1 { return true }

        let lineDistance = segmentDistance(
            point,
            start: .init(x: 26, y: 36),
            end: .init(x: 162, y: 36)
        )
        if abs(lineDistance - 8) <= 1 { return true }

        let rect = CanvasRect(x: 130, y: 20, width: 84, height: 68)
        let boxDistance = signedBoxDistance(point, rect: rect)
        if abs(abs(boxDistance) - 8) <= 1 { return true }

        let arch = CanvasArch(
            start: .init(x: 38, y: 184),
            end: .init(x: 214, y: 184),
            sagitta: -60
        )
        let parameters = try! ArchGeometry.parameters(for: arch)
        let radialDistance = point.distance(to: parameters.center)
        let angle = atan2(
            point.y - parameters.center.y,
            point.x - parameters.center.x
        )
        let arcDistance = parameters.contains(angle: angle)
            ? abs(radialDistance - parameters.radius)
            : min(point.distance(to: arch.start), point.distance(to: arch.end))
        if abs(arcDistance - 8) <= 1 { return true }

        let guideDistance = abs(point.x - 242)
        return abs(guideDistance - 2) <= 1
    }

    func segmentDistance(
        _ point: CanvasPoint,
        start: CanvasPoint,
        end: CanvasPoint
    ) -> Double {
        let delta = CanvasPoint(x: end.x - start.x, y: end.y - start.y)
        let squaredLength = delta.x * delta.x + delta.y * delta.y
        let parameter = min(1, max(0,
            ((point.x - start.x) * delta.x + (point.y - start.y) * delta.y)
                / squaredLength
        ))
        return hypot(
            point.x - (start.x + delta.x * parameter),
            point.y - (start.y + delta.y * parameter)
        )
    }

    func signedBoxDistance(_ point: CanvasPoint, rect: CanvasRect) -> Double {
        let center = CanvasPoint(
            x: rect.x + rect.width / 2,
            y: rect.y + rect.height / 2
        )
        let dx = abs(point.x - center.x) - rect.width / 2
        let dy = abs(point.y - center.y) - rect.height / 2
        return hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0)
    }
}
