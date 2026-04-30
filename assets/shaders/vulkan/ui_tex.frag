#version 450

layout(location = 0) in vec2 vTexCoord;

layout(location = 0) out vec4 FragColor;

layout(set = 0, binding = 0) uniform sampler2D uTexture;

layout(push_constant) uniform PushConstants {
    layout(offset = 64) vec4 tint;
} pc;

void main() {
    vec4 texColor = texture(uTexture, vTexCoord);
    if (pc.tint.a < 0.0) {
        FragColor = vec4(pc.tint.rgb, -pc.tint.a * texColor.r);
    } else {
        FragColor = texColor * pc.tint;
    }
}
