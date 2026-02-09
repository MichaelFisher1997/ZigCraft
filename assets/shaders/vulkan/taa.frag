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
    vec2 velocity = texture(uVelocity, outUV).xy;
    vec2 history_uv = outUV - velocity;

    vec3 current = sampleCurrent(outUV);

    if (taa.reset_history > 0.5 || history_uv.x < 0.0 || history_uv.y < 0.0 || history_uv.x > 1.0 || history_uv.y > 1.0) {
        outColor = vec4(current, 1.0);
        return;
    }

    vec3 history = texture(uHistory, history_uv).rgb;

    vec2 texel = 1.0 / vec2(textureSize(uCurrentHdr, 0));
    vec3 c1 = sampleCurrent(clamp(outUV + vec2(texel.x, 0.0), 0.0, 1.0));
    vec3 c2 = sampleCurrent(clamp(outUV + vec2(-texel.x, 0.0), 0.0, 1.0));
    vec3 c3 = sampleCurrent(clamp(outUV + vec2(0.0, texel.y), 0.0, 1.0));
    vec3 c4 = sampleCurrent(clamp(outUV + vec2(0.0, -texel.y), 0.0, 1.0));

    vec3 min_color = min(current, min(min(c1, c2), min(c3, c4)));
    vec3 max_color = max(current, max(max(c1, c2), max(c3, c4)));
    vec3 clamped_history = clamp(history, min_color, max_color);

    float speed = length(velocity);
    float stable = 1.0 - smoothstep(taa.velocity_rejection, taa.velocity_rejection * 4.0, speed);
    float history_weight = taa.blend_factor * stable;
    vec3 resolved = mix(current, clamped_history, history_weight);

    outColor = vec4(resolved, 1.0);
}
