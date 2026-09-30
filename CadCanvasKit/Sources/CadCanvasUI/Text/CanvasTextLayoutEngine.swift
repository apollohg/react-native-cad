import UIKit
import CadCanvasCore

enum CanvasTextLayoutError: Error, Equatable {
    case invalidOrigin
    case invalidFontSize
    case invalidWidth
    case invalidElement
    case invalidDelta
    case invalidViewport
    case revisionExhausted
    case unrepresentableBounds
}

enum CanvasTextResizeEdge: CaseIterable, Hashable {
    case left
    case right
}

@MainActor
package struct CanvasTextLayoutEngine {
    package init() {}

    package func resolvedFont(_ font: CanvasFont) -> UIFont {
        let pointSize = CGFloat(font.pointSize)
        return UIFont(name: font.familyName, size: pointSize)
            ?? UIFont.systemFont(ofSize: pointSize)
    }

    package func measure(
        text: String,
        font: CanvasFont,
        origin: CanvasPoint,
        width: Double
    ) -> CanvasRect? {
        guard origin.x.isFinite, origin.y.isFinite,
              width.isFinite, width > 0,
              font.pointSize.isFinite, font.pointSize > 0,
              let cgWidth = finiteCGFloat(width) else {
            return nil
        }
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: cgWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: resolvedFont(font)],
            context: nil
        )
        let height = max(Double(ceil(bounds.height)), font.pointSize)
        let frame = CanvasRect(x: origin.x, y: origin.y, width: width, height: height)
        guard frame.isFinite, frame.maxX.isFinite, frame.maxY.isFinite else { return nil }
        return frame
    }

    func frame(
        origin: CanvasPoint,
        text: String,
        font: CanvasFont,
        constrainedWidth: Double?
    ) throws -> CanvasRect {
        guard origin.x.isFinite, origin.y.isFinite else {
            throw CanvasTextLayoutError.invalidOrigin
        }
        guard font.pointSize.isFinite, font.pointSize > 0,
              let pointSize = CGFloat(exactly: font.pointSize), pointSize.isFinite else {
            throw CanvasTextLayoutError.invalidFontSize
        }
        let uiFont = UIFont(name: font.familyName, size: pointSize)
            ?? UIFont.systemFont(ofSize: pointSize)
        let value = (text.isEmpty ? " " : text) as NSString
        let naturalWidth = ceil(Double(value.size(withAttributes: [.font: uiFont]).width))
        let width = max(Double(uiFont.pointSize), constrainedWidth ?? naturalWidth)
        guard width.isFinite, width > 0, let cgWidth = CGFloat(exactly: width) else {
            throw CanvasTextLayoutError.invalidWidth
        }
        let measured = value.boundingRect(
            with: CGSize(width: cgWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: uiFont],
            context: nil
        )
        let height = max(Double(uiFont.lineHeight), ceil(Double(measured.height)))
        let result = CanvasRect(x: origin.x, y: origin.y, width: width, height: height)
        guard result.isFinite, result.maxX.isFinite, result.maxY.isFinite else {
            throw CanvasTextLayoutError.unrepresentableBounds
        }
        return result
    }

    func resizedElement(
        _ element: CanvasElement,
        edge: CanvasTextResizeEdge,
        cumulativeScreenDelta: CanvasPoint,
        viewport: CanvasViewport
    ) throws -> CanvasElement {
        guard case .text(var text) = element.geometry else {
            throw CanvasTextLayoutError.invalidElement
        }
        guard cumulativeScreenDelta.x.isFinite else {
            throw CanvasTextLayoutError.invalidDelta
        }
        guard viewport.zoom.isFinite, viewport.zoom > 0 else {
            throw CanvasTextLayoutError.invalidViewport
        }
        guard element.contentRevision < UInt64.max - 1 else {
            throw CanvasTextLayoutError.revisionExhausted
        }

        let canvasDelta = cumulativeScreenDelta.x / viewport.zoom
        guard canvasDelta.isFinite else {
            throw CanvasTextLayoutError.invalidDelta
        }
        let minimumWidth = Double(resolvedFont(text.font).pointSize)
        let width: Double
        let x: Double
        switch edge {
        case .left:
            width = max(minimumWidth, text.frame.width - canvasDelta)
            x = text.frame.maxX - width
        case .right:
            width = max(minimumWidth, text.frame.width + canvasDelta)
            x = text.frame.minX
        }
        guard width.isFinite, x.isFinite else {
            throw CanvasTextLayoutError.invalidWidth
        }

        text.frame = try frame(
            origin: .init(x: x, y: text.frame.y),
            text: text.text,
            font: text.font,
            constrainedWidth: width
        )
        var resized = element
        resized.geometry = .text(text)
        resized.contentRevision += 1
        return resized
    }
}

private func finiteCGFloat(_ value: Double) -> CGFloat? {
    let result = CGFloat(value)
    return result.isFinite ? result : nil
}
