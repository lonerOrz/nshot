#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 selectionRect;
    float dimOpacity;
    vec2 screenSize;
    float borderRadius;        // in pixels
    float outlineThickness;    // in pixels
};

float sdRoundedBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + vec2(r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
    vec2 halfSize = selectionRect.zw / 2.0;
    vec2 center = selectionRect.xy + halfSize;
    vec2 pixelPos = qt_TexCoord0 * screenSize;
    vec2 p = pixelPos - center;

    float dist = sdRoundedBox(p, halfSize, borderRadius);

    // Smooth outline with anti-aliasing (1px transition)
    float outlineEdge = outlineThickness;
    float outlineAlpha = 1.0 - smoothstep(outlineEdge - 1.0, outlineEdge, dist);

    bool insideFilledArea = dist <= 0.0;

    if (insideFilledArea) {
        fragColor = vec4(0.0, 0.0, 0.0, 0.0);
    } else {
        // Mix between outline and dimmed background
        vec3 outlineColor = vec3(1.0);
        vec3 dimColor = vec3(0.0);
        vec3 color = mix(dimColor, outlineColor, outlineAlpha);
        float alpha = mix(dimOpacity, 1.0, outlineAlpha);
        fragColor = vec4(color, alpha * qt_Opacity);
    }
}
