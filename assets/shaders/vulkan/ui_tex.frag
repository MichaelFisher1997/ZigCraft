#version 450

layout(location = 0) in vec2 vTexCoord;

layout(location = 0) out vec4 FragColor;

layout(set = 0, binding = 0) uniform sampler2D uTexture;

layout(push_constant) uniform PushConstants {
    layout(offset = 64) vec4 tint;
} pc;

void main() {
    vec4 texColor = texture(uTexture, vTexCoord);
    // Font atlases use R8 coverage. Regular RGBA UI textures still pass
    // through because their alpha remains authoritative.
    float alpha = texColor.a < 1.0 ? texColor.a : texColor.r;
    FragColor = vec4(pc.tint.rgb, pc.tint.a * alpha);
}
