#include <metal_stdlib>
using namespace metal;

struct CanvasRasterData {
    float4 position [[position]];
    float2 localPosition;
};

struct MetalCanvasUniforms {
    float2 viewportSize;
    float2 inverseViewportSize;
};

struct MetalLineInstance {
    float2 start;
    float2 end;
    float4 color;
    float lineWidth;
    float dashLength;
    float dashPeriod;
    float dashOffset;
};

struct MetalBoxInstance {
    float2 origin;
    float2 size;
    float4 fillColor;
    float4 strokeColor;
    float lineWidth;
    float padding0;
    float padding1;
    float padding2;
};

struct MetalArcInstance {
    float2 start;
    float2 end;
    float2 center;
    float radius;
    float geometryPadding;
    float4 color;
    float lineWidth;
    float padding0;
    float padding1;
    float padding2;
};

struct MetalCoverageSegment {
    float2 start;
    float2 end;
    float startWidth;
    float endWidth;
    float padding0;
    float padding1;
};

struct CanvasCoverageRasterData {
    float4 position [[position]];
    uint segmentIndex [[flat]];
};

struct MetalCompositeMaskParameters {
    float4 color;
};

struct MetalMaskRegionParameters {
    float4 color;
    float2 sourceOrigin;
    float2 sourceSize;
};

struct MetalTileCompositeParameters {
    float2 destinationOrigin;
    float sourceScale;
    float gutter;
};

struct MetalMeshVertex {
    float2 position;
    float2 layoutPadding;
    float4 color;
};

struct MetalStencilCoverParameters {
    float4 color;
};

struct CanvasMeshRasterData {
    float4 position [[position]];
    float4 color;
};

vertex CanvasRasterData canvasUnitQuadVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0),
    };
    CanvasRasterData output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.localPosition = positions[vertexID] * 0.5 + 0.5;
    return output;
}

vertex CanvasCoverageRasterData canvasCoverageSegmentVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    device const MetalCoverageSegment *segments [[buffer(0)]],
    constant MetalCanvasUniforms &uniforms [[buffer(1)]]
) {
    constexpr float2 corners[] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0),
    };
    MetalCoverageSegment segment = segments[instanceID];
    float expansion = max(segment.startWidth, segment.endWidth) * 0.5 + 2.0;
    float2 lower = min(segment.start, segment.end) - expansion;
    float2 upper = max(segment.start, segment.end) + expansion;
    float2 pixel = mix(lower, upper, corners[vertexID]);

    CanvasCoverageRasterData output;
    output.position = float4(
        pixel.x * uniforms.inverseViewportSize.x * 2.0 - 1.0,
        1.0 - pixel.y * uniforms.inverseViewportSize.y * 2.0,
        0.0,
        1.0
    );
    output.segmentIndex = instanceID;
    return output;
}

float canvasCoverage(float signedDistance) {
    float smoothingWidth = max(fwidth(signedDistance), 0.0001);
    return smoothstep(0.5 * smoothingWidth, -0.5 * smoothingWidth, signedDistance);
}

float canvasSegmentDistance(float2 point, float2 start, float2 end) {
    float2 segment = end - start;
    float squaredLength = dot(segment, segment);
    float parameter = squaredLength > 0.0
        ? clamp(dot(point - start, segment) / squaredLength, 0.0, 1.0)
        : 0.0;
    return length(point - (start + segment * parameter));
}

float canvasUnevenCapsuleDistance(
    float2 point,
    float2 start,
    float2 end,
    float startWidth,
    float endWidth
) {
    float startRadius = startWidth * 0.5;
    float endRadius = endWidth * 0.5;
    float2 axisVector = end - start;
    float axisLength = length(axisVector);
    if (!all(isfinite(point)) || !all(isfinite(start)) || !all(isfinite(end))
        || !isfinite(startRadius) || !isfinite(endRadius)
        || startRadius < 0.0 || endRadius < 0.0) {
        return NAN;
    }
    float radiusDifference = startRadius - endRadius;
    if (!isfinite(axisLength) || axisLength <= 0.000001
        || axisLength <= abs(radiusDifference)) {
        bool useStart = startRadius >= endRadius;
        return length(point - (useStart ? start : end))
            - (useStart ? startRadius : endRadius);
    }

    float2 axis = axisVector / axisLength;
    float2 relative = point - start;
    float2 local = float2(abs(dot(relative, float2(-axis.y, axis.x))), dot(relative, axis));
    float radiusSlope = radiusDifference / axisLength;
    float tangentScale = sqrt(max(0.0, 1.0 - radiusSlope * radiusSlope));
    float tangentCoordinate = dot(local, float2(-radiusSlope, tangentScale));
    if (tangentCoordinate < 0.0) {
        return length(local) - startRadius;
    }
    if (tangentCoordinate > tangentScale * axisLength) {
        return length(local - float2(0.0, axisLength)) - endRadius;
    }
    return dot(local, float2(tangentScale, radiusSlope)) - startRadius;
}

float canvasBoxDistance(float2 point, float2 origin, float2 size) {
    float2 halfSize = size * 0.5;
    float2 displacement = abs(point - (origin + halfSize)) - halfSize;
    return length(max(displacement, 0.0)) + min(max(displacement.x, displacement.y), 0.0);
}

float canvasPositiveAngle(float angle) {
    constexpr float fullTurn = M_PI_F * 2.0;
    float result = fmod(angle, fullTurn);
    return result >= 0.0 ? result : result + fullTurn;
}

bool canvasArcContains(float angle, float startAngle, float sweepAngle) {
    if (sweepAngle >= 0.0) {
        return canvasPositiveAngle(angle - startAngle) <= sweepAngle;
    }
    return canvasPositiveAngle(startAngle - angle) <= -sweepAngle;
}

fragment half4 canvasAnalyticLineFragment(
    CanvasRasterData input [[stage_in]],
    constant MetalLineInstance &instance [[buffer(0)]]
) {
    float distance = canvasSegmentDistance(input.position.xy, instance.start, instance.end)
        - instance.lineWidth * 0.5;
    if (instance.dashPeriod > 0.0) {
        float2 axis = instance.end - instance.start;
        float axisLength = length(axis);
        float along = axisLength > 0.0 ? dot(input.position.xy - instance.start, axis / axisLength) : 0.0;
        float centered = along - instance.dashOffset - instance.dashLength * 0.5;
        float phase = centered - instance.dashPeriod * floor(centered / instance.dashPeriod + 0.5);
        distance = max(distance, abs(phase) - instance.dashLength * 0.5);
    }
    return half4(instance.color * canvasCoverage(distance));
}

fragment half4 canvasAnalyticBoxFragment(
    CanvasRasterData input [[stage_in]],
    constant MetalBoxInstance &instance [[buffer(0)]]
) {
    float distance = canvasBoxDistance(input.position.xy, instance.origin, instance.size);
    float fillCoverage = canvasCoverage(distance);
    float strokeCoverage = instance.lineWidth > 0.0
        ? canvasCoverage(abs(distance) - instance.lineWidth * 0.5)
        : 0.0;
    float4 fill = instance.fillColor * fillCoverage;
    float4 stroke = instance.strokeColor * strokeCoverage;
    return half4(stroke + fill * (1.0 - stroke.a));
}

fragment half4 canvasAnalyticArcFragment(
    CanvasRasterData input [[stage_in]],
    constant MetalArcInstance &instance [[buffer(0)]]
) {
    float2 radial = input.position.xy - instance.center;
    float angle = atan2(radial.y, radial.x);
    float startAngle = atan2(
        instance.start.y - instance.center.y,
        instance.start.x - instance.center.x
    );
    float distance = canvasArcContains(angle, startAngle, instance.geometryPadding)
        ? abs(length(radial) - instance.radius)
        : min(length(input.position.xy - instance.start), length(input.position.xy - instance.end));
    distance -= instance.lineWidth * 0.5;
    return half4(instance.color * canvasCoverage(distance));
}

fragment half canvasCoverageSegmentFragment(
    CanvasCoverageRasterData input [[stage_in]],
    device const MetalCoverageSegment *segments [[buffer(0)]]
) {
    MetalCoverageSegment segment = segments[input.segmentIndex];
    float distance = canvasUnevenCapsuleDistance(
        input.position.xy,
        segment.start,
        segment.end,
        segment.startWidth,
        segment.endWidth
    );
    if (!isfinite(distance)) {
        return half(0.0h);
    }
    return half(canvasCoverage(distance));
}

fragment half4 canvasCompositeMaskFragment(
    CanvasRasterData input [[stage_in]],
    constant MetalCompositeMaskParameters &parameters [[buffer(0)]],
    texture2d<half, access::read> coverageTexture [[texture(0)]]
) {
    uint2 coordinate = uint2(input.position.xy);
    half coverage = coverageTexture.read(coordinate).r;
    return half4(parameters.color) * coverage;
}

fragment half4 canvasCompositeMaskRegionFragment(
    CanvasRasterData input [[stage_in]],
    constant MetalMaskRegionParameters &parameters [[buffer(0)]],
    texture2d<half> coverageTexture [[texture(0)]]
) {
    float2 sourcePosition = input.position.xy + parameters.sourceOrigin;
    if (any(sourcePosition < 0.0) || any(sourcePosition >= parameters.sourceSize)) {
        return half4(0.0h);
    }
    constexpr sampler coverageSampler(
        coord::normalized,
        address::clamp_to_edge,
        filter::linear
    );
    half coverage = coverageTexture.sample(
        coverageSampler,
        sourcePosition / parameters.sourceSize
    ).r;
    return half4(parameters.color) * coverage;
}

fragment half4 canvasCompositeColorFragment(
    CanvasRasterData input [[stage_in]],
    constant uint2 &destinationOrigin [[buffer(0)]],
    texture2d<half, access::read> colorTexture [[texture(0)]]
) {
    constexpr uint scale = 4;
    uint2 origin = (uint2(input.position.xy) - destinationOrigin) * scale;
    half4 color = half4(0.0h);
    for (uint y = 0; y < scale; ++y) {
        for (uint x = 0; x < scale; ++x) {
            color += colorTexture.read(origin + uint2(x, y));
        }
    }
    return color / half(scale * scale);
}

fragment half4 canvasCompositeTileFragment(
    CanvasRasterData input [[stage_in]],
    constant MetalTileCompositeParameters &parameters [[buffer(0)]],
    texture2d<half> colorTexture [[texture(0)]]
) {
    constexpr sampler tileSampler(
        coord::normalized,
        address::clamp_to_edge,
        filter::linear
    );
    float2 sourcePosition = (input.position.xy - parameters.destinationOrigin)
        * parameters.sourceScale + parameters.gutter;
    float2 textureSize = float2(colorTexture.get_width(), colorTexture.get_height());
    return colorTexture.sample(tileSampler, sourcePosition / textureSize);
}

vertex CanvasMeshRasterData canvasMeshVertex(
    const device MetalMeshVertex *vertices [[buffer(0)]],
    constant float4 &cropTransform [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    CanvasMeshRasterData output;
    float2 position = vertices[vertexID].position * cropTransform.xy
        + cropTransform.zw;
    output.position = float4(position, 0.0, 1.0);
    output.color = vertices[vertexID].color;
    return output;
}

fragment half4 canvasMeshFragment(CanvasMeshRasterData input [[stage_in]]) {
    return half4(input.color);
}

fragment half4 canvasStencilCoverFragment(
    CanvasRasterData input [[stage_in]],
    constant MetalStencilCoverParameters &parameters [[buffer(0)]]
) {
    return half4(parameters.color);
}
