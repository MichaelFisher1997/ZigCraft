#version 450

layout(location = 0) in vec2 outUV;
layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform sampler2D uCurrentHdr;
layout(set = 0, binding = 1) uniform sampler2D uHistory;
layout(set = 0, binding = 2) uniform sampler2D uVelocity;

layout(push_constant) uniform TAAPush {
    float blend_factor;
    float velocity_rejection;
    float reset_history;
    float _pad;
} taa;

vec3 sampleCurrent(vec2 uv) {
    return texture(uCurrentHdr, uv).rgb;
}

void main() {
    // TODO: restore full temporal accumulation once the TAA output path is
    // revalidated against the rest of the post-processing chain.
    vec3 current = sampleCurrent(outUV);
    outColor = vec4(current, 1.0);
}
