import Foundation
import DrawCanvasCore

enum StressDocument {
    struct Metadata: Equatable, Sendable {
        let elementCount: Int
        let rectangleCount: Int
        let lineCount: Int
        let archCount: Int
        let textCount: Int
        let freehandCount: Int
        let freehandSampleCount: Int
        let minimumPressure: Double?
        let maximumPressure: Double?
    }

    struct Fingerprint: Equatable, Sendable {
        let encodedUTF8ByteCount: Int
        let encodedFNV1a64: UInt64
    }

    struct Contract: Equatable, Sendable {
        let metadata: Metadata
        let fingerprint: Fingerprint
    }

    static let expectedMetadata = Metadata(
        elementCount: 500,
        rectangleCount: 100,
        lineCount: 100,
        archCount: 100,
        textCount: 100,
        freehandCount: 100,
        freehandSampleCount: 100_000,
        minimumPressure: 0,
        maximumPressure: 1
    )

    static let expectedFingerprint = Fingerprint(
        encodedUTF8ByteCount: 4_578_977,
        encodedFNV1a64: 7_599_112_663_866_035_260
    )

    static let expectedContract = Contract(
        metadata: expectedMetadata,
        fingerprint: expectedFingerprint
    )

    static func make() throws -> CanvasDocument {
        var elements: [CanvasElement] = []
        elements.reserveCapacity(expectedMetadata.elementCount)

        for index in 0 ..< 100 {
            elements.append(rectangle(at: index))
        }
        for index in 0 ..< 100 {
            elements.append(line(at: index))
        }
        for index in 0 ..< 100 {
            elements.append(arch(at: index))
        }
        for index in 0 ..< 100 {
            elements.append(text(at: index))
        }
        for index in 0 ..< 100 {
            elements.append(freehand(at: index))
        }

        let document = CanvasDocument(
            id: fixtureID(kind: 0, index: 0),
            revision: 0,
            elements: elements,
            calibration: CanvasCalibration(millimetersPerPoint: 0.5)
        )
        try document.validate()
        _ = try audit(document)
        return document
    }

    static func metadata(for document: CanvasDocument) -> Metadata {
        var rectangleCount = 0
        var lineCount = 0
        var archCount = 0
        var textCount = 0
        var freehandCount = 0
        var freehandSampleCount = 0
        var minimumPressure: Double?
        var maximumPressure: Double?

        for element in document.elements {
            switch element.geometry {
            case .rectangle:
                rectangleCount += 1
            case .line:
                lineCount += 1
            case .arch:
                archCount += 1
            case .text:
                textCount += 1
            case .freehand(let stroke):
                freehandCount += 1
                freehandSampleCount += stroke.samples.count
                for sample in stroke.samples {
                    minimumPressure = minimumPressure.map { min($0, sample.pressure) }
                        ?? sample.pressure
                    maximumPressure = maximumPressure.map { max($0, sample.pressure) }
                        ?? sample.pressure
                }
            }
        }

        return Metadata(
            elementCount: document.elements.count,
            rectangleCount: rectangleCount,
            lineCount: lineCount,
            archCount: archCount,
            textCount: textCount,
            freehandCount: freehandCount,
            freehandSampleCount: freehandSampleCount,
            minimumPressure: minimumPressure,
            maximumPressure: maximumPressure
        )
    }

    @discardableResult
    static func audit(_ document: CanvasDocument) throws -> Contract {
        guard document.revision == 0 else {
            throw StressDocumentError.unexpectedDocumentRevision(document.revision)
        }
        guard document.elements.allSatisfy({ $0.contentRevision == 0 }) else {
            throw StressDocumentError.nonzeroElementRevision
        }
        let actual = metadata(for: document)
        guard actual == expectedMetadata else {
            throw StressDocumentError.unexpectedMetadata(actual: actual, expected: expectedMetadata)
        }
        let fingerprint = try fingerprint(for: document)
        guard fingerprint == expectedFingerprint else {
            throw StressDocumentError.unexpectedFingerprint(
                actual: fingerprint,
                expected: expectedFingerprint
            )
        }
        return Contract(metadata: actual, fingerprint: fingerprint)
    }

    static func fingerprint(for document: CanvasDocument) throws -> Fingerprint {
        let encoding = try CanvasDocumentCodec.encodeString(document)
        return Fingerprint(
            encodedUTF8ByteCount: encoding.utf8.count,
            encodedFNV1a64: stableChecksum(encoding.utf8)
        )
    }
}

extension StressDocument {
    enum StressDocumentError: LocalizedError {
        case unexpectedDocumentRevision(UInt64)
        case nonzeroElementRevision
        case unexpectedMetadata(actual: Metadata, expected: Metadata)
        case unexpectedFingerprint(actual: Fingerprint, expected: Fingerprint)

        var errorDescription: String? {
            switch self {
            case .unexpectedDocumentRevision(let revision):
                "Stress document revision was \(revision), expected zero."
            case .nonzeroElementRevision:
                "Every stress element must have content revision zero."
            case .unexpectedMetadata(let actual, let expected):
                "Stress document metadata was \(actual), expected \(expected)."
            case .unexpectedFingerprint(let actual, let expected):
                "Stress document fingerprint was \(actual), expected \(expected)."
            }
        }
    }
}

private extension StressDocument {
    static let outline = CanvasStyle(
        stroke: CanvasColor(red: 0.08, green: 0.27, blue: 0.58),
        fill: nil,
        lineWidth: 2
    )

    static let filled = CanvasStyle(
        stroke: CanvasColor(red: 0.12, green: 0.38, blue: 0.62),
        fill: CanvasColor(red: 0.72, green: 0.86, blue: 0.98, alpha: 0.35),
        lineWidth: 1.5
    )

    static func rectangle(at index: Int) -> CanvasElement {
        let column = index % 10
        let row = index / 10
        return CanvasElement.rectangle(
            id: fixtureID(kind: 1, index: index),
            rect: CanvasRect(
                x: Double(column * 76),
                y: Double(row * 58),
                width: 48 + Double(index % 4),
                height: 32 + Double(index % 5)
            ),
            style: filled
        )
    }

    static func line(at index: Int) -> CanvasElement {
        let column = index % 10
        let row = index / 10
        let start = CanvasPoint(x: 820 + Double(column * 72), y: Double(row * 58))
        let end = CanvasPoint(x: start.x + 44, y: start.y + 28 + Double(index % 6))
        return CanvasElement(
            id: fixtureID(kind: 2, index: index),
            geometry: .line(CanvasLine(start: start, end: end)),
            style: outline
        )
    }

    static func arch(at index: Int) -> CanvasElement {
        let column = index % 10
        let row = index / 10
        let start = CanvasPoint(x: 1_580 + Double(column * 72), y: Double(row * 58))
        let end = CanvasPoint(x: start.x + 48, y: start.y)
        return CanvasElement(
            id: fixtureID(kind: 3, index: index),
            geometry: .arch(
                CanvasArch(start: start, end: end, sagitta: 18 + Double(index % 7))
            ),
            style: outline
        )
    }

    static func text(at index: Int) -> CanvasElement {
        let column = index % 10
        let row = index / 10
        return CanvasElement(
            id: fixtureID(kind: 4, index: index),
            geometry: .text(
                CanvasText(
                    frame: CanvasRect(
                        x: 2_340 + Double(column * 88),
                        y: 20 + Double(row * 58),
                        width: 96,
                        height: 20
                    ),
                    text: "Fixture \(index)",
                    font: CanvasFont(familyName: "Helvetica", pointSize: 16),
                    color: CanvasColor(red: 0.16, green: 0.18, blue: 0.22)
                )
            ),
            style: outline
        )
    }

    static func freehand(at index: Int) -> CanvasElement {
        var samples: [CanvasInkSample] = []
        samples.reserveCapacity(1_000)

        for pointIndex in 0 ..< 1_000 {
            let point = CanvasPoint(
                x: Double(pointIndex) * 1.25,
                y: 700 + Double(index * 12) + Double((pointIndex * 17 + index * 13) % 19) * 0.4
            )
            let pressure = Double((index * 1_000 + pointIndex) % 101) / 100
            samples.append(CanvasInkSample(point: point, pressure: pressure))
        }

        return CanvasElement(
            id: fixtureID(kind: 5, index: index),
            geometry: .freehand(CanvasInkStroke(samples: samples, pressureEnabled: true)),
            style: CanvasStyle(
                stroke: CanvasColor(red: 0.48, green: 0.18, blue: 0.58),
                lineWidth: 1.25
            )
        )
    }

    static func fixtureID(kind: UInt8, index: Int) -> UUID {
        UUID(
            uuid: (
                0x44, 0x52, 0x41, 0x57,
                0x43, 0x41, 0x4e, 0x56,
                0x41, 0x53, 0x00, kind,
                0x00, 0x00, 0x00, UInt8(index)
            )
        )
    }

    static func stableChecksum(_ bytes: String.UTF8View) -> UInt64 {
        bytes.reduce(UInt64(14_695_981_039_346_656_037)) { checksum, byte in
            (checksum ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
