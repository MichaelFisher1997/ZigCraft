#version 450

layout(location = 0) in vec2 inUV;
layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform sampler2D uHDRBuffer;
layout(set = 0, binding = 2) uniform sampler2D uBloomTexture;
layout(set = 0, binding = 3) uniform sampler3D uColorLUT;

layout(push_constant) uniform PostProcessParams {
    float bloomEnabled;           // 0.0 = disabled, 1.0 = enabled
    float bloomIntensity;         // Final bloom blend intensity
    float vignetteIntensity;      // 0.0 = none, 1.0 = full vignette
    float filmGrainIntensity;     // 0.0 = none, 1.0 = heavy grain
    float colorGradingEnabled;    // 0.0 = disabled, 1.0 = enabled
    float colorGradingIntensity;  // LUT blend intensity (0.0 = original, 1.0 = full LUT)
} postParams;

layout(set = 0, binding = 1) uniform GlobalUniforms {
    mat4 view_proj;
    mat4 view_proj_prev; // Previous frame's view-projection for velocity buffer
    vec4 cam_pos;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 fog_color;
    vec4 reserved0;
    vec4 params; // x = time, y = fog_density, z = fog_enabled, w = sun_intensity
    vec4 lighting; // x = ambient, y = use_texture, z = pbr_enabled, w = reserved
    vec4 render_flags;
    vec4 shadow_params; // x = pcf_samples, y = cascade_blend, z/w reserved
    vec4 pbr_params; // x = pbr_quality, y = exposure, z = saturation
    vec4 volumetric_params;
    vec4 viewport_size;
} global;

// AgX Log2 encoding for HDR input
vec3 agxDefaultContrastApprox(vec3 x) {
    vec3 x2 = x * x;
    vec3 x4 = x2 * x2;
    return + 15.5     * x4 * x2
           - 40.14    * x4 * x
           + 31.96    * x4
           - 6.868    * x2 * x
           + 0.4298   * x2
           + 0.1191   * x
           - 0.00232;
}

vec3 agx(vec3 val) {
    const mat3 agx_mat = mat3(
        0.842479062253094, 0.0423282422610123, 0.0423756549057051,
        0.0784335999999992, 0.878468636469772, 0.0784336,
        0.0792237451477643, 0.0791661274605434, 0.879142973793104
    );
    
    const float min_ev = -12.47393;
    const float max_ev = 4.026069;
    
    // Input transform (sRGB to AgX working space)
    val = agx_mat * val;
    
    // Log2 encoding
    val = clamp(log2(max(val, vec3(1e-6))), min_ev, max_ev);
    val = (val - min_ev) / (max_ev - min_ev);
    
    // Apply sigmoid contrast curve
    val = agxDefaultContrastApprox(val);
    
    return val;
}

vec3 agxEotf(vec3 val) {
    const mat3 agx_mat_inv = mat3(
        1.19687900512017, -0.0528968517574562, -0.0529716355144438,
        -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
        -0.0990297440797205, -0.0989611768448433, 1.15107367264116
    );
    
    // Inverse input transform
    val = agx_mat_inv * val;
    
    // sRGB IEC 61966-2-1 2.2 Exponent Reference EOTF Display
    return pow(max(val, vec3(0.0)), vec3(2.2));
}

vec3 agxLook(vec3 val, float saturation, float contrast) {
    float luma = dot(val, vec3(0.2126, 0.7152, 0.0722));
    
    // Saturation adjustment
    val = luma + saturation * (val - luma);
    
    // Contrast adjustment around mid-gray
    val = 0.5 + (0.5 + contrast * 0.5) * (val - 0.5);
    
    return val;
}

vec3 agxToneMap(vec3 color, float exposure, float saturation) {
    color *= exposure;
    color = max(color, vec3(0.0));
    color = agx(color);
    color = agxLook(color, saturation, 1.2);
    color = agxEotf(color);
    return clamp(color, 0.0, 1.0);
}

vec3 ACESFilm(vec3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// Vignette effect - darkens edges of the screen
vec3 applyVignette(vec3 color, vec2 uv, float intensity) {
    if (intensity <= 0.0) return color;
    
    // Convert UV from [0,1] to [-1,1] range, centered at (0.5, 0.5)
    vec2 centered = uv * 2.0 - 1.0;
    
    // Calculate distance from center (circular vignette)
    float dist = length(centered);
    
    // Smooth vignette falloff
    float vignette = smoothstep(1.0, 0.4, dist * (1.0 + intensity));
    
    // Apply vignette - darker at edges
    return color * mix(0.3, 1.0, vignette * (1.0 - intensity * 0.5) + intensity * 0.5);
}

// Pseudo-random function for film grain
float random(vec2 uv) {
    return fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453);
}

// LUT-based color grading using a 3D lookup texture.
// Input color should be in [0,1] range (post-tonemapping).
vec3 applyColorGrading(vec3 color, float intensity) {
    if (intensity <= 0.0) return color;
    
    // Clamp to valid LUT range and apply half-texel offset for correct sampling
    vec3 lutCoord = clamp(color, 0.0, 1.0);
    
    // Scale and bias for correct 3D LUT sampling (avoid edge texels)
    const float LUT_SIZE = 32.0;
    lutCoord = lutCoord * ((LUT_SIZE - 1.0) / LUT_SIZE) + 0.5 / LUT_SIZE;
    
    vec3 graded = texture(uColorLUT, lutCoord).rgb;
    return mix(color, graded, intensity);
}

// Film grain effect - adds animated noise
vec3 applyFilmGrain(vec3 color, vec2 uv, float intensity, float time) {
    if (intensity <= 0.0) return color;
    
    // Generate grain using UV and time for animation
    float grain = random(uv + time * 0.01);
    
    // Convert to signed noise centered around 0
    grain = (grain - 0.5) * 2.0;
    
    // Apply grain with intensity - subtle effect
    return color + grain * intensity * 0.05;
}

vec2 sunScreenUV() {
    vec4 clip = global.view_proj * vec4(normalize(global.sun_dir.xyz) * 256.0, 1.0);
    vec2 ndc = clip.xy / max(abs(clip.w), 0.001);
    return ndc * vec2(0.5, -0.5) + vec2(0.5);
}

float brightMask(vec3 color) {
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float greenBias = smoothstep(0.04, 0.24, color.g - max(color.r, color.b) * 0.45);
    return smoothstep(0.16, 0.85, luma) * (0.45 + 0.55 * greenBias);
}

vec3 computeScreenSunShafts(vec2 uv) {
    if (global.volumetric_params.x < 0.5 || global.render_flags.w < 0.5 || global.params.w <= 0.02) return vec3(0.0);

    vec3 currentColor = texture(uHDRBuffer, uv).rgb;
    float currentLuma = dot(currentColor, vec3(0.2126, 0.7152, 0.0722));
    float darkReceiver = 1.0 - smoothstep(0.03, 0.32, currentLuma);
    if (darkReceiver <= 0.001) return vec3(0.0);

    vec2 sourceUV = mix(vec2(0.5), sunScreenUV(), 0.18);
    vec2 toSource = sourceUV - uv;
    float centerFade = 1.0 - smoothstep(0.15, 1.45, length(uv * 2.0 - 1.0));
    float shaft = 0.0;
    float weightSum = 0.0;

    const int samples = 24;
    for (int i = 0; i < samples; i++) {
        float t = (float(i) + 0.5) / float(samples);
        vec2 sampleUV = uv + toSource * t;
        if (sampleUV.x < 0.0 || sampleUV.x > 1.0 || sampleUV.y < 0.0 || sampleUV.y > 1.0) continue;

        vec3 sampleColor = texture(uHDRBuffer, sampleUV).rgb;
        float weight = pow(t, 1.2);
        shaft += brightMask(sampleColor) * weight;
        weightSum += weight;
    }

    shaft /= max(weightSum, 0.001);
    shaft *= centerFade * darkReceiver;
    shaft = pow(clamp(shaft, 0.0, 1.0), 1.15);

    vec3 warmSun = mix(global.sun_color.rgb, vec3(1.0, 0.84, 0.52), 0.40);
    return warmSun * shaft * global.volumetric_params.y * 1.15;
}

void main() {
    vec3 color = texture(uHDRBuffer, inUV).rgb;

    if (postParams.bloomEnabled > 0.5) {
        color += texture(uBloomTexture, inUV).rgb * postParams.bloomIntensity;
    }

    if (global.render_flags.z > 0.5) {
        color = agxToneMap(color, global.pbr_params.y, global.pbr_params.z);
        color = applyColorGrading(color, postParams.colorGradingEnabled * postParams.colorGradingIntensity);
        color = applyVignette(color, inUV, postParams.vignetteIntensity);
        color = applyFilmGrain(color, inUV, postParams.filmGrainIntensity, global.params.x);
    } else {
        // Keep the safe/non-PBR path on the same display transform so bright terrain
        // doesn't collapse into a pale linear-looking wash.
        color = agxToneMap(color, global.pbr_params.y, global.pbr_params.z);
    }

    outColor = vec4(color, 1.0);
}
