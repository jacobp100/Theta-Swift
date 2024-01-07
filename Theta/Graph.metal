#include <metal_stdlib>

[[visible]] float eq(float x, float y);

using namespace metal;

vertex float4 graphVertex(uint vertexID [[vertex_id]]) {
    float3 vertices[6] = {
        float3(-1.0, -1.0, 0.0),
        float3(1.0, -1.0, 0.0),
        float3(-1.0, 1.0, 0.0),
        float3(1.0, -1.0, 0.0),
        float3(1.0, 1.0, 0.0),
        float3(-1.0, 1.0, 0.0),
    };

    float3 position = vertices[vertexID];

    return float4(position, 1.0);
}

fragment half4 graphFragment(float4 position [[position]],
                             constant float2 &offset [[buffer(1)]],
                             constant float2 &size [[buffer(2)]]) {
    float scale = 50;
    float thicknessAndMode = 2;
    half4 currentColor = half4(0.0, 0.0, 1.0, 1.0);

    float2 coords = float2(position.x, position.y) - offset;

    float x = (coords.x - size.x * 0.5) / scale;
    float y = (size.y * 0.5 - coords.y) / scale;
    float dx = dfdx(x);
    float dy = dfdy(y);
    float z = eq(x, y);

    // Evaluate all 4 adjacent +/- neighbor pixels
    float2 zNeg = float2(eq(x - dx, y), eq(x, y - dy));
    float2 zPos = float2(eq(x + dx, y), eq(x, y + dy));

    // Compute the x and y slopes
    float2 slope = (zPos - zNeg) * 0.5;

    // Compute the gradient (the shortest point on the curve is assumed to lie in this direction)
    float2 gradient = normalize(slope);

    // Use the parabola "a*t^2 + b*t + z = 0" to approximate the function along the gradient
    float a = dot((zNeg + zPos) * 0.5 - z, gradient * gradient);
    float b = dot(slope, gradient);

    // The distance to the curve is the closest solution to the parabolic equation
    float distanceToCurve = 0.0;
    float thickness = abs(thicknessAndMode);

    if (abs(a) < 1.0e-6) {
        // Linear equation: "b*t + z = 0"
        distanceToCurve = abs(z / b);
    } else {
        // Quadratic equation: "a*t^2 + b*t + z = 0"
        float discriminant = b * b - 4.0 * a * z;
        if (discriminant < 0.0) {
            distanceToCurve = thickness;
        } else {
            discriminant = sqrt(discriminant);
            distanceToCurve = min(abs(b + discriminant), abs(b - discriminant)) / abs(2.0 * a);
        }
    }

    // Antialias the edge using the distance from the curve
    float edgeAlpha = clamp(abs(thickness) - distanceToCurve, 0.0, 1.0);

    return currentColor * edgeAlpha;
}
