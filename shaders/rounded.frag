#version 440
// Cuts a layer to a rounded rectangle with a one-pixel antialiased edge.
// Cheaper than MultiEffect's mask (no second texture), crisp at any scale.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;      // item size in item pixels
    float radius;   // corner radius in item pixels
};
layout(binding = 1) uniform sampler2D source;
void main() {
    vec2 p = qt_TexCoord0 * size - size * 0.5;
    vec2 q = abs(p) - (size * 0.5 - vec2(radius));
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    float aa = max(fwidth(d), 0.0001);
    float a = 1.0 - smoothstep(-0.5 * aa, 0.5 * aa, d);
    fragColor = texture(source, qt_TexCoord0) * (a * qt_Opacity);
}
