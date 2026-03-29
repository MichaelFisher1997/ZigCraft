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

vec3 sampleHdr(vec2 uv) {
    return texture(uCurrentHdr, uv).rgb;
}

vec3 sampleHistory(vec2 uv) {
    return texture(uHistory, uv).rgb;
}

vec2 sampleVelocity(vec2 uv) {
    return texture(uVelocity, uv).rg;
}

vec3 rgbToYCoCg(vec3 c) {
    return vec3(
        0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
        0.5 * c.r - 0.5 * c.b,
       -0.25 * c.r + 0.5 * c.g - 0.25 * c.b
    );
}

vec3 yCoCgToRgb(vec3 c) {
    float tmp = c.x - c.z;
    return vec3(tmp + c.y, c.x + c.z, tmp - c.y);
}

vec3 clampToAabb(vec3 color, vec3 aabb_min, vec3 aabb_max) {
    vec3 center = 0.5 * (aabb_max + aabb_min);
    vec3 extents = 0.5 * (aabb_max - aabb_min);
    vec3 offset = color - center;
    vec3 clamped = clamp(abs(offset), vec3(0.0), extents);
    clamped = sign(offset) * clamped;
    return center + clamped;
}

void main() {
    vec3 current = sampleHdr(outUV);

    if (taa.reset_history > 0.5) {
        outColor = vec4(current, 1.0);
        return;
    }

    vec2 velocity = sampleVelocity(outUV);
    float speed = length(velocity);
    if (speed > taa.velocity_rejection) {
        outColor = vec4(current, 1.0);
        return;
    }

    vec2 texel_size = 1.0 / vec2(textureSize(uCurrentHdr, 0));
    vec3 n0 = sampleHdr(outUV + vec2(-texel_size.x, -texel_size.y));
    vec3 n1 = sampleHdr(outUV + vec2( 0.0,           -texel_size.y));
    vec3 n2 = sampleHdr(outUV + vec2( texel_size.x,  -texel_size.y));
    vec3 n3 = sampleHdr(outUV + vec2(-texel_size.x,   0.0));
    vec3 n4 = sampleHdr(outUV + vec2( texel_size.x,   0.0));
    vec3 n5 = sampleHdr(outUV + vec2(-texel_size.x,   texel_size.y));
    vec3 n6 = sampleHdr(outUV + vec2( 0.0,            texel_size.y));
    vec3 n7 = sampleHdr(outUV + vec2( texel_size.x,   texel_size.y));

    vec3 aabb_min = min(current, min(min(n0, n1), min(n2, n3)));
    aabb_min = min(aabb_min, min(min(n4, n5), min(n6, n7)));
    vec3 aabb_max = max(current, max(max(n0, n1), max(n2, n3)));
    aabb_max = max(aabb_max, max(max(n4, n5), max(n6, n7)));

    vec3 aabb_min_ycocg = rgbToYCoCg(aabb_min);
    vec3 aabb_max_ycocg = rgbToYCoCg(aabb_max);

    aabb_min_ycocg -= vec3(0.0, 0.0075, 0.0075);
    aabb_max_ycocg += vec3(0.0, 0.0075, 0.0075);

    vec2 history_uv = outUV - velocity;
    if (history_uv.x < 0.0 || history_uv.x > 1.0 ||
        history_uv.y < 0.0 || history_uv.y > 1.0) {
        outColor = vec4(current, 1.0);
        return;
    }

    vec3 history = sampleHistory(history_uv);
    vec3 history_ycocg = rgbToYCoCg(history);
    vec3 clamped_ycocg = clampToAabb(history_ycocg, aabb_min_ycocg, aabb_max_ycocg);
    vec3 clamped_history = yCoCgToRgb(clamped_ycocg);

    float blend = taa.blend_factor;
    blend *= clamp(1.0 - speed / taa.velocity_rejection, 0.2, 1.0);

    vec3 result = mix(current, clamped_history, blend);
    outColor = vec4(result, 1.0);
}
