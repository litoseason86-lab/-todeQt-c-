#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 itemSize;
    float cornerRadius;
    float bezelWidth;
    float refractionStrength;
} ubuf;

layout(binding = 1) uniform sampler2D source;

float roundedRectSdf(vec2 point, vec2 halfSize, float radius)
{
    vec2 q = abs(point) - (halfSize - vec2(radius));
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

void main()
{
    vec2 safeSize = max(ubuf.itemSize, vec2(1.0));
    vec2 halfSize = safeSize * 0.5;
    vec2 point = qt_TexCoord0 * safeSize - halfSize;
    float radius = clamp(ubuf.cornerRadius, 0.0, min(halfSize.x, halfSize.y));
    float distanceToEdge = roundedRectSdf(point, halfSize, radius);

    // 只有圆角边缘带产生折射；中心采样保持不变，避免业务文字背后的背景整体漂移。
    float edgeWeight = smoothstep(-max(ubuf.bezelWidth, 0.5), 0.0, distanceToEdge);
    float pointLength = max(length(point), 0.001);
    vec2 inwardDirection = -point / pointLength;
    vec2 offset = inwardDirection * edgeWeight * ubuf.refractionStrength / safeSize;
    vec2 sampleUv = clamp(qt_TexCoord0 + offset, vec2(0.0), vec2(1.0));

    fragColor = texture(source, sampleUv) * ubuf.qt_Opacity;
}
