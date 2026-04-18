#version 450

layout(location = 0) in vec3 vWorldDir;
layout(location = 0) out vec4 FragColor;

layout(push_constant) uniform SkyPC {
    vec4 cam_forward;
    vec4 cam_right;
    vec4 cam_up;
    vec4 sun_dir;
    vec4 sky_color;
    vec4 horizon_color;
    vec4 params; // aspect, tanHalfFov, sunIntensity, moonIntensity
    vec4 time;
} pc;

layout(set = 0, binding = 0) uniform GlobalUniforms {
    mat4 view_proj;
    mat4 view_proj_prev; // Previous frame's view-projection for velocity buffer
    vec4 cam_pos;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 fog_color;
    vec4 cloud_wind_offset;
    vec4 params;
    vec4 lighting;
    vec4 cloud_params;
    vec4 shadow_params;
    vec4 pbr_params;
    vec4 volumetric_params;
    vec4 viewport_size;
} global;

layout(set = 0, binding = 2) uniform ShadowUniforms {
    mat4 light_space_matrices[3];
    vec4 cascade_splits;
    vec4 shadow_texel_sizes;
} shadows;

layout(set = 0, binding = 3) uniform sampler2DArrayShadow uShadowMaps;



const float PI = 3.14159265359;

float cloudHash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float cloudNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float a = cloudHash(i);
    float b = cloudHash(i + vec2(1.0, 0.0));
    float c = cloudHash(i + vec2(0.0, 1.0));
    float d = cloudHash(i + vec2(1.0, 1.0));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float cloudFbm(vec2 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    for (int i = 0; i < octaves; i++) {
        value += amplitude * cloudNoise(p * frequency);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return value;
}

vec4 sampleSkyClouds(vec3 dir) {
    float cloudCoverage = global.cloud_wind_offset.w;
    if (cloudCoverage <= 0.01 || abs(dir.y) <= 0.02) return vec4(0.0);

    float cloudHeight = global.cloud_params.x;
    float t = (cloudHeight - global.cam_pos.y) / dir.y;
    if (t <= 0.0 || t > 8000.0) return vec4(0.0);

    const float cloudBlockSize = 12.0;
    vec3 cloudPos = global.cam_pos.xyz + dir * t;
    vec2 worldXZ = cloudPos.xz + global.cloud_wind_offset.xy;
    vec2 pixelPos = floor(worldXZ / cloudBlockSize) * cloudBlockSize;
    vec2 samplePos = pixelPos * global.cloud_wind_offset.z;
    float cloudValue = cloudFbm(samplePos, 3);
    float threshold = 1.0 - cloudCoverage;
    float cloudMask = smoothstep(threshold - 0.08, threshold + 0.08, cloudValue);
    if (cloudMask <= 0.001) return vec4(0.0);

    vec3 nightTint = pow(vec3(0.10, 0.12, 0.20), vec3(2.2));
    vec3 dayColor = vec3(0.92, 0.95, 0.98);
    vec3 cloudColor = mix(nightTint, dayColor, pc.params.z);
    float lightFactor = clamp(pc.sun_dir.y, 0.0, 1.0);
    cloudColor *= (0.8 + 0.25 * lightFactor);

    float fogFactor = 1.0 - exp(-t * global.params.y * 0.35);
    cloudColor = mix(cloudColor, global.fog_color.xyz, fogFactor);

    float alpha = cloudMask * (1.0 - fogFactor * 0.6);
    alpha *= 1.0 - smoothstep(5000.0, 8000.0, t);
    return vec4(cloudColor, alpha);
}

// Henyey-Greenstein Phase Function for Mie Scattering (Phase 4)
float henyeyGreenstein(float g, float cosTheta) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * cosTheta, 0.01), 1.5));
}

// Simple shadow sampler for volumetric points, optimized
float getVolShadow(vec3 p, float viewDepth) {
    int layer = 2; // Sky is far, but raymarched points can be near
    if (viewDepth < shadows.cascade_splits[0]) layer = 0;
    else if (viewDepth < shadows.cascade_splits[1]) layer = 1;

    vec4 lightSpacePos = shadows.light_space_matrices[layer] * vec4(p, 1.0);
    vec3 proj = lightSpacePos.xyz / lightSpacePos.w;
    proj.xy = proj.xy * 0.5 + 0.5;
    
    if (proj.x < 0.0 || proj.x > 1.0 || proj.y < 0.0 || proj.y > 1.0 || proj.z > 1.0) return 1.0;
    
    return texture(uShadowMaps, vec4(proj.xy, float(layer), proj.z + 0.002));
}

// Raymarched God Rays (Phase 4)
// Energy-conserving volumetric lighting with transmittance for sky
vec4 calculateVolumetric(vec3 rayStart, vec3 rayDir, float dither) {
    if (global.volumetric_params.x < 0.5) return vec4(0.0, 0.0, 0.0, 1.0);
    
    float cosSun = dot(rayDir, normalize(global.sun_dir.xyz));
    // Optimization: Skip volumetric if looking away from sun (conservative threshold)
    if (cosSun < -0.3) return vec4(0.0, 0.0, 0.0, 1.0);
    
    float maxDist = 400.0; 
    int steps = 16; 
    float stepSize = maxDist / float(steps);
    
    float phase = henyeyGreenstein(global.volumetric_params.w, cosSun);
    
    // Use the actual sun color for scattering
    vec3 sunColor = global.sun_color.rgb * global.params.w * 3.0; // Boost scattering
    vec3 accumulatedScattering = vec3(0.0);
    float transmittance = 1.0;
    float baseDensity = global.volumetric_params.y * 0.08; // Slightly lower for sky
    
    for (int i = 0; i < steps; i++) {
        float d = (float(i) + dither) * stepSize;
        vec3 p = rayStart + rayDir * d;
        // Fix: Use absolute world height for density falloff
        float worldY = p.y + global.cam_pos.y;
        float heightFactor = exp(-max(worldY, 0.0) * 0.02); // Slower falloff for sky rays
        float density = baseDensity * heightFactor;
        
        if (density > 1e-4) {
            float shadow = getVolShadow(p, d);
            vec3 stepScattering = sunColor * shadow * phase * density * stepSize;
            
            accumulatedScattering += stepScattering * transmittance;
            transmittance *= exp(-density * stepSize);
            
            // Optimization: Early exit if fully occluded
            if (transmittance < 0.01) break;
        }
    }
    
    // No hard mix at the end, the density falloff should handle the transition naturally
    
    return vec4(accumulatedScattering, transmittance);
}

float hash21(vec2 p) {
    p = fract(p * vec2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

vec2 hash22(vec2 p) {
    float n = hash21(p);
    return vec2(n, hash21(p + n));
}

float stars(vec3 dir) {
    float theta = atan(dir.z, dir.x);
    float phi = asin(clamp(dir.y, -1.0, 1.0));

    vec2 gridCoord = vec2(theta * 15.0, phi * 30.0);
    vec2 cell = floor(gridCoord);
    vec2 cellFrac = fract(gridCoord);

    float brightness = 0.0;

    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            vec2 neighbor = cell + vec2(float(dx), float(dy));

            float starChance = hash21(neighbor);
            if (starChance > 0.92) {
                vec2 starPos = hash22(neighbor * 1.7);
                vec2 offset = vec2(float(dx), float(dy)) + starPos - cellFrac;
                float dist = length(offset);

                float starBright = smoothstep(0.08, 0.0, dist);
                starBright *= 0.5 + 0.5 * hash21(neighbor * 3.14);
                float twinkle = 0.7 + 0.3 * sin(hash21(neighbor) * 50.0 + pc.time.x * 8.0);
                starBright *= twinkle;

                brightness = max(brightness, starBright);
            }
        }
    }

    return brightness;
}

void main() {
    vec3 dir = normalize(vWorldDir);

    float horizon = 1.0 - abs(dir.y);
    horizon = pow(horizon, 1.5);
    vec3 sky = mix(pc.sky_color.xyz, pc.horizon_color.xyz, horizon) * 4.0; // Boost sky radiance to match terrain boost

    float sunDot = dot(dir, normalize(pc.sun_dir.xyz));
    float sunDisc = smoothstep(0.9995, 0.9999, sunDot);
    // Use uniform sun color instead of hardcoded value
    vec3 sunColor = global.sun_color.rgb;

    float sunGlow = pow(max(sunDot, 0.0), 8.0) * 0.5;
    sunGlow += pow(max(sunDot, 0.0), 64.0) * 0.3;

    float moonDot = dot(dir, -normalize(pc.sun_dir.xyz));
    float moonDisc = smoothstep(0.9990, 0.9995, moonDot);
    vec3 moonColor = pow(vec3(0.9, 0.9, 1.0), vec3(2.2));

    float starIntensity = 0.0;
    if (pc.params.z < 0.3 && dir.y > 0.0) {
        float nightFactor = 1.0 - pc.params.z * 3.33;
        starIntensity = stars(dir) * nightFactor * 1.5;
    }

    vec3 finalColor = sky;

    vec4 skyClouds = sampleSkyClouds(dir);
    finalColor = mix(finalColor, skyClouds.rgb, skyClouds.a);

    finalColor += sunGlow * pc.params.z * pow(vec3(1.0, 0.8, 0.4), vec3(2.2));
    finalColor += sunDisc * sunColor * pc.params.z;
    finalColor += moonDisc * moonColor * pc.params.w * 3.0;
    finalColor += vec3(starIntensity);

    // Volumetric Scattering (Phase 4)
    if (global.volumetric_params.x > 0.5) {
        float dither = cloudHash(gl_FragCoord.xy + vec2(global.params.x));
        // Use camera-relative origin (0,0,0) for raymarching start
        vec4 volumetric = calculateVolumetric(vec3(0.0), dir, dither);
        // Apply transmittance to sky color and add scattered light
        finalColor = finalColor * volumetric.a + volumetric.rgb;
    }

    FragColor = vec4(finalColor, 1.0);
}
