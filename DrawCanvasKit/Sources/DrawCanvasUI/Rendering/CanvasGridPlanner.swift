import Foundation
import DrawCanvasCore

struct CanvasGridPlan: Equatable {
    let baseSpacing: Double
    let visualSpacing: Double
    let verticalCoordinates: [Double]
    let horizontalCoordinates: [Double]
}

enum CanvasGridPlannerError: Error, Equatable {
    case invalidVisibleRect
    case invalidSpacing
    case invalidLineBudget
}

enum CanvasGridPlanner {
    static func plan(
        visibleRect: CanvasRect,
        baseSpacing: Double,
        maximumLineCount: Int
    ) throws -> CanvasGridPlan {
        guard visibleRect.isFinite,
              visibleRect.width >= 0,
              visibleRect.height >= 0,
              visibleRect.maxX.isFinite,
              visibleRect.maxY.isFinite else {
            throw CanvasGridPlannerError.invalidVisibleRect
        }
        guard baseSpacing.isFinite, baseSpacing.isNormal, baseSpacing > 0 else {
            throw CanvasGridPlannerError.invalidSpacing
        }
        guard maximumLineCount > 0 else {
            throw CanvasGridPlannerError.invalidLineBudget
        }

        var multiplier = 1.0
        while true {
            let visualSpacing = baseSpacing * multiplier
            guard visualSpacing.isFinite, visualSpacing.isNormal else {
                throw CanvasGridPlannerError.invalidSpacing
            }

            if let lineCount = estimatedCount(in: visibleRect, spacing: visualSpacing),
               lineCount <= maximumLineCount {
                return CanvasGridPlan(
                    baseSpacing: baseSpacing,
                    visualSpacing: visualSpacing,
                    verticalCoordinates: coordinates(
                        minimum: visibleRect.minX,
                        maximum: visibleRect.maxX,
                        spacing: visualSpacing
                    ),
                    horizontalCoordinates: coordinates(
                        minimum: visibleRect.minY,
                        maximum: visibleRect.maxY,
                        spacing: visualSpacing
                    )
                )
            }

            multiplier *= 2
            guard multiplier.isFinite else {
                throw CanvasGridPlannerError.invalidSpacing
            }
        }
    }

    private static func coordinates(
        minimum: Double,
        maximum: Double,
        spacing: Double
    ) -> [Double] {
        guard let indexRange = coordinateIndexRange(
            minimum: minimum,
            maximum: maximum,
            spacing: spacing
        ) else {
            return []
        }

        var result: [Double] = []
        result.reserveCapacity(indexRange.count)
        for offset in 0..<indexRange.count {
            let coordinate = (indexRange.first + Double(offset)) * spacing
            guard coordinate.isFinite,
                  coordinate >= minimum,
                  coordinate < maximum else {
                continue
            }
            result.append(coordinate)
        }
        return result
    }

    private static func estimatedCount(in rect: CanvasRect, spacing: Double) -> Int? {
        guard let verticalCount = coordinateCount(
            minimum: rect.minX,
            maximum: rect.maxX,
            spacing: spacing
        ), let horizontalCount = coordinateCount(
            minimum: rect.minY,
            maximum: rect.maxY,
            spacing: spacing
        ) else {
            return nil
        }

        let (total, overflow) = verticalCount.addingReportingOverflow(horizontalCount)
        return overflow ? nil : total
    }

    private static func coordinateCount(
        minimum: Double,
        maximum: Double,
        spacing: Double
    ) -> Int? {
        coordinateIndexRange(
            minimum: minimum,
            maximum: maximum,
            spacing: spacing
        )?.count
    }

    private static func coordinateIndexRange(
        minimum: Double,
        maximum: Double,
        spacing: Double
    ) -> (first: Double, count: Int)? {
        guard minimum < maximum else {
            return minimum == maximum ? (first: 0, count: 0) : nil
        }
        guard let firstVisibleIndex = firstIndex(atOrAbove: minimum, spacing: spacing),
              let lastExclusiveIndex = firstIndex(atOrAbove: maximum, spacing: spacing) else {
            return nil
        }

        let count = lastExclusiveIndex - firstVisibleIndex
        guard count.isFinite,
              count >= 0,
              count < Double(Int.max) else {
            return nil
        }
        return (first: firstVisibleIndex, count: Int(count))
    }

    private static func firstIndex(atOrAbove boundary: Double, spacing: Double) -> Double? {
        var index = ceil(boundary / spacing)
        guard index.isFinite else { return nil }

        if index * spacing < boundary {
            let nextIndex = index + 1
            guard nextIndex.isFinite, nextIndex > index else { return nil }
            index = nextIndex
        } else {
            let previousIndex = index - 1
            if previousIndex < index,
               previousIndex * spacing >= boundary {
                index = previousIndex
            }
        }
        return index
    }
}
