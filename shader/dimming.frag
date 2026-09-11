#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    vec4 selectionRect;       // offset: 64,  size: 16
    vec2 screenSize;          // offset: 80,  size: 8
    float qt_Opacity;         // offset: 88,  size: 4
    float dimOpacity;         // offset: 92,  size: 4
    float borderRadius;       // offset: 96,  size: 4
    float outlineThickness;   // offset: 100, size: 4
};

float sdRoundedBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + vec2(r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
    vec2 halfSize = selectionRect.zw * 0.5;
    vec2 center = selectionRect.xy + halfSize;
    vec2 p = (qt_TexCoord0 * screenSize) - center;

    float dist = sdRoundedBox(p, halfSize, borderRadius);

    float aa = fwidth(dist);
    float outlineAlpha = 1.0 - smoothstep(outlineThickness - aa, outlineThickness, dist);
    float fillMask = smoothstep(0.0, aa, dist); // 0.0 为内部，1.0 为外部

    vec3 col = mix(vec3(0.0), vec3(1.0), outlineAlpha);
    float alpha = mix(dimOpacity, 1.0, outlineAlpha) * fillMask;

    fragColor = vec4(col, alpha * qt_Opacity);
}
