import Foundation
import DrawCanvasCore

@MainActor
public final class CanvasFreehandDraft {
    struct Statistics: Equatable {
        var appendCallCount = 0
        var appendedPointCount = 0
        var fullPathMaterializationCount = 0
    }

    let id: UUID
    let style: CanvasStyle
    let pressureEnabled: Bool
    let widthMode: CanvasInkWidthMode
    let preparedInk: CanvasPreparedInk
    private(set) var samples: [CanvasInkSample] = []
    private(set) var statistics = Statistics()
    private(set) var bounds: CanvasRect?

    var points: [CanvasPoint] { samples.map(\.point) }

    private var minimumX: Double?
    private var maximumX: Double?
    private var minimumY: Double?
    private var maximumY: Double?
    private var materializedElement: CanvasElement?

    init(
        id: UUID,
        style: CanvasStyle,
        pressureEnabled: Bool = true,
        widthMode: CanvasInkWidthMode = .canvasScaled
    ) {
        self.id = id
        self.style = style
        self.pressureEnabled = pressureEnabled
        self.widthMode = widthMode
        preparedInk = CanvasPreparedInk(
            confirmedSamples: [],
            predictedSamples: [],
            pressureEnabled: pressureEnabled,
            widthMode: widthMode,
            isFinalized: false
        )
    }

    func append(_ candidates: [CanvasInkSample]) {
        guard materializedElement == nil else { return }
        let accepted = candidates.filter {
            $0.point.x.isFinite && $0.point.y.isFinite
                && $0.pressure.isFinite && (0 ... 1).contains($0.pressure)
        }
        guard !accepted.isEmpty else { return }
        let points = accepted.map(\.point)

        samples.append(contentsOf: accepted)
        statistics.appendCallCount += 1
        statistics.appendedPointCount += accepted.count
        for point in points {
            minimumX = minimumX.map { min($0, point.x) } ?? point.x
            maximumX = maximumX.map { max($0, point.x) } ?? point.x
            minimumY = minimumY.map { min($0, point.y) } ?? point.y
            maximumY = maximumY.map { max($0, point.y) } ?? point.y
        }
        bounds = currentBounds()
    }

    func materializeElement() throws -> CanvasElement {
        if let materializedElement { return materializedElement }
        statistics.fullPathMaterializationCount += 1
        let element = CanvasElement(
            id: id,
            geometry: .freehand(.init(
                samples: samples,
                pressureEnabled: pressureEnabled,
                widthMode: widthMode
            )),
            style: style
        )
        try style.validate()
        materializedElement = element
        return element
    }

    private func currentBounds() -> CanvasRect? {
        guard let minimumX,
              let maximumX,
              let minimumY,
              let maximumY else {
            return nil
        }
        let width = maximumX - minimumX
        let height = maximumY - minimumY
        guard width.isFinite, height.isFinite, width >= 0, height >= 0 else {
            return nil
        }
        return CanvasRect(x: minimumX, y: minimumY, width: width, height: height)
    }
}
