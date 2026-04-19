#version 450

layout(location = 0) in vec3 vColor;
layout(location = 1) flat in vec3 vNormal;
layout(location = 2) in vec2 vTexCoord;
layout(location = 3) flat in int vTileID;
layout(location = 4) in float vDistance;
layout(location = 5) in float vSkyLight;
layout(location = 6) in vec3 vBlockLight;
layout(location = 7) in vec3 vFragPosWorld;
layout(location = 8) in float vViewDepth;
layout(location = 9) in vec3 vTangent;
layout(location = 10) in vec3 vBitangent;
layout(location = 11) in float vAO;
layout(location = 12) in vec4 vClipPosCurrent;
layout(location = 13) in vec4 vClipPosPrev;
layout(location = 14) in float vMaskRadius;

layout(location = 0) out vec4 FragColor;

layout(set = 0, binding = 0) uniform GlobalUniforms {
    mat4 view_proj;
    mat4 view_proj_prev; // Previous frame's view-projection for velocity buffer
    vec4 cam_pos;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 fog_color;
    vec4 cloud_wind_offset; // xy = offset, z = scale, w = coverage
    vec4 params; // x = time, y = fog_density, z = fog_enabled, w = sun_intensity
    vec4 lighting; // x = ambient, y = use_texture, z = pbr_enabled, w = cloud_shadow_strength
    vec4 cloud_params; // x = cloud_height, y = cloud_shadows_enabled, z/w reserved
    vec4 shadow_params; // x = pcf_samples, y = cascade_blend, z/w reserved
    vec4 pbr_params; // x = pbr_quality, y = exposure, z = saturation, w = ssao_strength
    vec4 volumetric_params; // x = enabled, y = density, z = steps, w = scattering
    vec4 viewport_size; // xy = width/height, z = shadow debug active, w = shadow debug channel (0=off, 1=shadow_factor, 2=cascade_index, 3=caster_coverage, 4=seam_diag)
    vec4 lpv_params; // x = enabled, y = intensity, z = cell_size, w = grid_size
    vec4 lpv_origin; // xyz = world origin
} global;

// Constants
const float PI = 3.14159265359;

const int DEBUG_OFF = 0;
const int DEBUG_SHADOW_FACTOR = 1;
const int DEBUG_CASCADE_INDEX = 2;
const int DEBUG_CASTER_COVERAGE = 3;
const int DEBUG_SEAM_DIAG = 4;
const int DEBUG_TILE_ID = 5;
const int DEBUG_TEX_COLOR = 6;

// Cloud shadow noise functions
float cloudHash(vec2 p) {
    p = fract(p * vec2(234.34, 435.345));
    p += dot(p, p + 34.23);
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

// World-space hash for LOD transition masking.
// Using world-space noise avoids a fixed screen-space dot pattern.
float lodTransitionNoise(vec2 worldXZ) {
    vec2 p = floor(worldXZ * 0.25);
    p = fract(p * vec2(0.1031, 0.1030));
    p += dot(p, p.yx + 33.33);
    return fract((p.x + p.y) * p.x);
}

float skyVisibilityFactor(float skyLight) {
    return smoothstep(0.05, 0.25, clamp(skyLight, 0.0, 1.0));
}

vec3 absoluteWorldPos(vec3 cameraRelativePos) {
    return cameraRelativePos + global.cam_pos.xyz;
}

float getCloudShadow(vec3 worldPos, vec3 sunDir) {
    const float cloudBlockSize = 12.0;
    vec3 actualWorldPos = worldPos + global.cam_pos.xyz;
    vec2 shadowOffset = sunDir.xz * (global.cloud_params.x - actualWorldPos.y) / max(sunDir.y, 0.1);
    vec2 worldXZ = actualWorldPos.xz + shadowOffset + global.cloud_wind_offset.xy;
    // Apply block quantization to match cloud rendering
    vec2 pixelPos = floor(worldXZ / cloudBlockSize) * cloudBlockSize;
    vec2 samplePos = pixelPos * global.cloud_wind_offset.z;
    float cloudValue = cloudFbm(samplePos, 3);
    float threshold = 1.0 - global.cloud_wind_offset.w;
    float cloudMask = smoothstep(threshold - 0.1, threshold + 0.1, cloudValue);
    return cloudMask * global.lighting.w;
}

vec4 sampleCloudOverlay(vec3 fragPosWorld) {
    if (global.cloud_wind_offset.w <= 0.01) return vec4(0.0);

    float cloudPlaneY = global.cloud_params.x - global.cam_pos.y;
    if (cloudPlaneY >= -0.5) return vec4(0.0);
    if (fragPosWorld.y >= cloudPlaneY - 0.001) return vec4(0.0);

    float rayY = fragPosWorld.y;
    if (rayY >= -0.001) return vec4(0.0);

    float t = cloudPlaneY / rayY;
    if (t <= 0.0 || t >= 1.0) return vec4(0.0);

    const float cloudBlockSize = 12.0;
    vec3 cloudPos = fragPosWorld * t;
    vec2 worldXZ = cloudPos.xz + global.cam_pos.xz + global.cloud_wind_offset.xy;
    vec2 pixelPos = floor(worldXZ / cloudBlockSize) * cloudBlockSize;
    vec2 samplePos = pixelPos * global.cloud_wind_offset.z;
    float cloudValue = cloudFbm(samplePos, 3);
    float threshold = 1.0 - global.cloud_wind_offset.w;
    float cloudMask = smoothstep(threshold - 0.08, threshold + 0.08, cloudValue);
    if (cloudMask <= 0.001) return vec4(0.0);

    vec3 nightTint = pow(vec3(0.10, 0.12, 0.20), vec3(2.2));
    vec3 dayColor = vec3(0.92, 0.95, 0.98);
    vec3 cloudColor = mix(nightTint, dayColor, global.params.w);
    float lightFactor = clamp(global.sun_dir.y, 0.0, 1.0);
    cloudColor *= (0.8 + 0.25 * lightFactor);

    float cloudDistance = length(cloudPos);
    float fogFactor = 1.0 - exp(-cloudDistance * global.params.y * 0.35);
    cloudColor = mix(cloudColor, global.fog_color.xyz, fogFactor);

    float alpha = cloudMask * (1.0 - fogFactor * 0.6);
    return vec4(cloudColor, alpha);
}

layout(set = 0, binding = 1) uniform sampler2D uTexture;         // Diffuse/albedo
layout(set = 0, binding = 6) uniform sampler2D uNormalMap;       // Normal map (OpenGL format)
layout(set = 0, binding = 7) uniform sampler2D uRoughnessMap;    // Roughness map
layout(set = 0, binding = 8) uniform sampler2D uDisplacementMap; // Displacement map (unused for now)
layout(set = 0, binding = 9) uniform sampler2D uEnvMap;          // Environment Map (EXR)
layout(set = 0, binding = 10) uniform sampler2D uSSAOMap;       // SSAO Map
layout(set = 0, binding = 11) uniform sampler3D uLPVGrid;       // LPV SH Red channel (4 SH coefficients)
layout(set = 0, binding = 12) uniform sampler3D uLPVGridG;      // LPV SH Green channel
layout(set = 0, binding = 13) uniform sampler3D uLPVGridB;      // LPV SH Blue channel

layout(set = 0, binding = 2) uniform ShadowUniforms {
    mat4 light_space_matrices[4];
    vec4 cascade_splits;
    vec4 shadow_texel_sizes;
    vec4 shadow_params; // x = light_size (PCSS), y/z/w reserved
} shadows;

layout(set = 0, binding = 3) uniform sampler2DArrayShadow uShadowMaps;
layout(set = 0, binding = 4) uniform sampler2DArray uShadowMapsRegular;

layout(push_constant) uniform ModelUniforms {
    mat4 model;
    vec4 color_override;
    float mask_radius;
} model_data;

// Poisson Disk for PCF (16-sample)
const vec2 poissonDisk16[16] = vec2[](
    vec2(-0.94201624, -0.39906216),
    vec2(0.94558609, -0.76890725),
    vec2(-0.094184101, -0.92938870),
    vec2(0.34495938, 0.29387760),
    vec2(-0.91588581, 0.45771432),
    vec2(-0.81544232, -0.87912464),
    vec2(0.97484398, 0.75648379),
    vec2(0.44323325, -0.97511554),
    vec2(0.53742981, -0.47373420),
    vec2(-0.26496911, -0.41893023),
    vec2(0.79197514, 0.19090188),
    vec2(-0.24188840, 0.99706507),
    vec2(-0.81409955, 0.91437590),
    vec2(0.19984126, 0.78641367),
    vec2(0.14383161, -0.14100790),
    vec2(-0.63242006, 0.31173663)
);

// 4-sample cross pattern for LOW preset (no noise, no PCSS)
const vec2 pcfCross4[4] = vec2[](
    vec2(-1.0, 0.0),
    vec2(1.0, 0.0),
    vec2(0.0, -1.0),
    vec2(0.0, 1.0)
);

float interleavedGradientNoise(vec2 fragCoord) {
    vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
    return fract(magic.z * fract(dot(fragCoord.xy, magic.xy)));
}

// PCSS blocker search using Poisson disk for better spatial distribution.
// searchRadius is derived from light size and receiver depth in light-space.
float findBlocker(vec2 uv, float zReceiver, int layer, float searchRadius, mat2 rot) {
    float blockerDepthSum = 0.0;
    int numBlockers = 0;
    // Use first 8 Poisson samples for blocker search (cheaper than full 16)
    for (int i = 0; i < 8; i++) {
        vec2 offset = (rot * poissonDisk16[i]) * searchRadius;
        float depth = texture(uShadowMapsRegular, vec3(uv + offset, float(layer))).r;
        // Reverse-Z: blockers have GREATER depth than receiver
        if (depth > zReceiver + 0.0002) {
            blockerDepthSum += depth;
            numBlockers++;
        }
    }
    if (numBlockers == 0) return -1.0;
    return blockerDepthSum / float(numBlockers);
}

float computeShadowFactor(vec3 fragPosWorld, vec3 N, vec3 L, int layer) {
    vec4 fragPosLightSpace = shadows.light_space_matrices[layer] * vec4(fragPosWorld, 1.0);
    vec3 projCoords = fragPosLightSpace.xyz / fragPosLightSpace.w;
    projCoords.xy = projCoords.xy * 0.5 + 0.5;
    
    // Bounds check: if outside current cascade, return lit (0.0 shadow factor)
    if (projCoords.x < 0.0 || projCoords.x > 1.0 || projCoords.y < 0.0 || projCoords.y > 1.0 || projCoords.z < 0.0 || projCoords.z > 1.0) return 0.0;

    float currentDepth = projCoords.z;
    float texelSize = shadows.shadow_texel_sizes[layer];
    float baseTexelSize = shadows.shadow_texel_sizes[0];
    float cascadeScale = texelSize / max(baseTexelSize, 0.0001);
    
    float NdotL = max(dot(N, L), 0.001);
    float sinTheta = sqrt(1.0 - NdotL * NdotL);
    float tanTheta = sinTheta / NdotL;
    
    // Reverse-Z Bias: push fragment CLOSER to light (towards Near=1.0)
    const float BASE_BIAS = 0.0025;
    const float SLOPE_BIAS = 0.003;
    const float MAX_BIAS = 0.015;
    
    float bias = BASE_BIAS * cascadeScale + SLOPE_BIAS * min(tanTheta, 5.0) * cascadeScale;
    bias = min(bias, MAX_BIAS);
    if (vTileID < 0) bias = max(bias, 0.006 * cascadeScale);

    int pcfSamples = int(global.shadow_params.x);

    if (pcfSamples <= 4) {
        // LOW preset: simple 4-sample cross PCF, no PCSS, no temporal noise.
        // Stable because there is no TAA to accumulate noise on LOW.
        float radius = texelSize * 1.5;
        float shadow = 0.0;
        for (int i = 0; i < 4; i++) {
            vec2 offset = pcfCross4[i] * radius;
            shadow += texture(uShadowMaps, vec4(projCoords.xy + offset, float(layer), currentDepth + bias));
        }
        return 1.0 - (shadow / 4.0);
    }

    // HIGH/ULTRA: PCSS with temporal noise rotation
    float angle = interleavedGradientNoise(gl_FragCoord.xy) * PI * 0.25;
    float s = sin(angle);
    float co = cos(angle);
    mat2 rot = mat2(co, s, -s, co);

    // PCSS: Percentage-Closer Soft Shadows
    // lightSize in shadow-map UV space, scaled per cascade
    float lightSize = shadows.shadow_params.x * texelSize;
    const float MIN_RADIUS = 0.0005;
    const float MAX_RADIUS = 0.008;

    // Step 1: Blocker search with light-size-proportional search radius
    float searchRadius = lightSize * 2.0 * cascadeScale;
    searchRadius = clamp(searchRadius, MIN_RADIUS, MAX_RADIUS);
    float avgBlockerDepth = findBlocker(projCoords.xy, currentDepth, layer, searchRadius, rot);

    float radius;
    if (avgBlockerDepth < 0.0) {
        // No blockers found — use minimum PCF radius for contact hardening
        radius = MIN_RADIUS * cascadeScale;
    } else {
        // Step 2: Penumbra estimation
        // Reverse-Z: blocker depth > receiver depth means blocker is closer to light
        float penumbraWidth = (avgBlockerDepth - currentDepth) / max(avgBlockerDepth, 0.0001) * lightSize;
        radius = clamp(penumbraWidth * cascadeScale, MIN_RADIUS * cascadeScale, MAX_RADIUS * cascadeScale);
    }

    // Step 3: Variable-radius PCF filtering
    float shadow = 0.0;
    for (int i = 0; i < 16; i++) {
        vec2 offset = (rot * poissonDisk16[i]) * radius;
        shadow += texture(uShadowMaps, vec4(projCoords.xy + offset, float(layer), currentDepth + bias));
    }
    // shadow factor: 1.0 (Shadowed) to 0.0 (Lit)
    return 1.0 - (shadow / 16.0);
}

float computeShadowCascades(vec3 fragPosWorld, vec3 N, vec3 L, float viewDepth, int layer) {
    if (global.shadow_params.z <= 0.0) return 0.0;

    float shadow = computeShadowFactor(fragPosWorld, N, L, layer);
    
    // Cascade blending transition (only when enabled).
    // shadow_params.y is packed as 1.0 (on) or 0.0 (off) from ShadowConfig.cascade_blend.
    if (global.shadow_params.y > 0.0 && layer < 3) {
        float nextSplit = shadows.cascade_splits[layer];
        float blendThreshold = nextSplit * 0.8;
        if (viewDepth > blendThreshold) {
            float blend = (viewDepth - blendThreshold) / (nextSplit - blendThreshold);
            float nextShadow = computeShadowFactor(fragPosWorld, N, L, layer + 1);
            shadow = mix(shadow, nextShadow, clamp(blend, 0.0, 1.0));
        }
    }
    return shadow;
}

// PBR functions
const float MAX_ENV_MIP_LEVEL = 8.0; 
const float SUN_RADIANCE_TO_IRRADIANCE = 4.0;
const float SUN_VOLUMETRIC_INTENSITY = 3.0;   
const float LEGACY_LIGHTING_INTENSITY = 2.5;  
const float LOD_LIGHTING_INTENSITY = 1.5;     
const float NON_PBR_ROUGHNESS = 0.5;          
const vec3 IBL_CLAMP = vec3(3.0);             
const float VOLUMETRIC_DENSITY_FACTOR = 0.1;  
const float DIELECTRIC_F0 = 0.04;             
const float COOK_TORRANCE_DENOM_FACTOR = 4.0; 

float DistributionGGX(vec3 N, vec3 H, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;
    float nom = a2;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
    return nom / max(denom, 0.001);
}

float GeometrySchlickGGX(float NdotV, float roughness) {
    float r = (roughness + 1.0);
    float k = (r * r) / 8.0;
    float nom = NdotV;
    float denom = NdotV * (1.0 - k) + k;
    return nom / max(denom, 0.001);
}

float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness) {
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2 = GeometrySchlickGGX(NdotV, roughness);
    float ggx1 = GeometrySchlickGGX(NdotL, roughness);
    return ggx1 * ggx2;
}

vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vec2 SampleSphericalMap(vec3 v) {
    vec3 n = normalize(v);
    float phi = atan(n.z, n.x);
    float theta = acos(clamp(n.y, -1.0, 1.0));
    vec2 uv;
    uv.x = phi / (2.0 * PI) + 0.5;
    uv.y = theta / PI;
    return uv;
}

vec3 computeIBLAmbient(vec3 N, float roughness) {
    float envMipLevel = roughness * MAX_ENV_MIP_LEVEL;
    vec2 envUV = SampleSphericalMap(normalize(N));
    return textureLod(uEnvMap, envUV, envMipLevel).rgb;
}

// SH L1 constants for irradiance reconstruction
const float LPV_SH_C0 = 0.282095;
const float LPV_SH_C1 = 0.488603;

// Evaluate SH L1 irradiance for a given direction
float evaluateLPVSH(vec4 sh, vec3 dir) {
    return max(0.0, sh.x * LPV_SH_C0 + sh.y * LPV_SH_C1 * dir.x + sh.z * LPV_SH_C1 * dir.y + sh.w * LPV_SH_C1 * dir.z);
}

// Sample the native 3D LPV SH grid and reconstruct directional irradiance using surface normal.
vec3 sampleLPVAtlas(vec3 worldPos, vec3 normal) {
    if (global.lpv_params.x < 0.5) return vec3(0.0);

    float gridSize = max(global.lpv_params.w, 1.0);
    float cellSize = max(global.lpv_params.z, 0.001);
    vec3 local = (worldPos - global.lpv_origin.xyz) / cellSize;

    if (any(lessThan(local, vec3(0.0))) || any(greaterThanEqual(local, vec3(gridSize)))) {
        return vec3(0.0);
    }

    // Normalize to [0,1] UV range for hardware trilinear sampling
    vec3 uvw = (local + 0.5) / gridSize;

    // Sample 4 SH coefficients per color channel
    vec4 sh_r = texture(uLPVGrid, uvw);
    vec4 sh_g = texture(uLPVGridG, uvw);
    vec4 sh_b = texture(uLPVGridB, uvw);

    // Reconstruct directional irradiance using the surface normal
    float irr_r = evaluateLPVSH(sh_r, normal);
    float irr_g = evaluateLPVSH(sh_g, normal);
    float irr_b = evaluateLPVSH(sh_b, normal);

    // Clamp to prevent overexposure from accumulated SH values
    return clamp(vec3(irr_r, irr_g, irr_b) * global.lpv_params.y, vec3(0.0), vec3(2.0));
}

vec3 computeBRDF(vec3 albedo, vec3 N, vec3 V, vec3 L, float roughness) {
    vec3 H = normalize(V + L);
    vec3 F0 = mix(vec3(DIELECTRIC_F0), albedo, 0.0);
    float NDF = DistributionGGX(N, H, roughness);
    float G = GeometrySmith(N, V, L, roughness);
    vec3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);
    vec3 numerator = NDF * G * F;
    float denominator = COOK_TORRANCE_DENOM_FACTOR * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 0.001;
    vec3 specular = numerator / denominator;
    vec3 kD = (vec3(1.0) - F);
    return (kD * albedo / PI + specular);
}

float baselineOutdoorFactor(float skyLight) {
    return smoothstep(0.0, 0.03, clamp(skyLight, 0.0, 1.0));
}

vec3 computeSimpleLighting(vec3 albedo, vec3 N, vec3 L, float skyLightIn, vec3 blockLightIn, float ao) {
    float outdoor = baselineOutdoorFactor(skyLightIn);
    float diagonalDelta = abs(abs(N.x) - abs(N.z));
    float isBillboard = (abs(N.y) < 0.01 && diagonalDelta < 0.05) ? 1.0 : 0.0;
    float sunFacing = mix(dot(N, L), abs(dot(N, L)), isBillboard);
    float wrappedDiffuse = clamp((sunFacing + 0.08 * outdoor) / (1.0 + 0.08 * outdoor), 0.0, 1.0);
    float directLight = wrappedDiffuse * global.params.w * outdoor * 0.9;
    float skyAmbient = global.lighting.x * (0.01 + skyLightIn * 0.20 + 0.10 * outdoor);
    float blockLight = max(blockLightIn.r, max(blockLightIn.g, blockLightIn.b));
    float lightLevel = skyAmbient + blockLight + directLight;
    float aoFactor = mix(1.0, ao, 0.25);
    return albedo * clamp(lightLevel * aoFactor, 0.0, 1.0);
}

vec3 computeLegacyDirect(vec3 albedo, float nDotL, float totalShadow, float skyLightIn, vec3 blockLightIn, float intensityFactor) {
    float directLight = nDotL * global.params.w * (1.0 - totalShadow) * intensityFactor;
    float skyAmbient = max(skyLightIn * global.lighting.x, global.lighting.x * 0.08);
    float blockLight = max(blockLightIn.r, max(blockLightIn.g, blockLightIn.b));
    float ambientShadowFactor = mix(1.0, 0.5, totalShadow);
    float lightLevel = skyAmbient * ambientShadowFactor + blockLight + directLight;
    return albedo * clamp(lightLevel, 0.0, 1.0);
}

vec3 computePBR(vec3 albedo, vec3 N, vec3 V, vec3 L, float roughness, float totalShadow, float skyLight, float skyVisibility, vec3 blockLight, float ao, float ssao) {
    float atmosphere = skyVisibilityFactor(skyVisibility);
    vec3 brdf = computeBRDF(albedo, N, V, L, roughness);
    float NdotL_final = max(dot(N, L), 0.0);
    vec3 sunColor = global.sun_color.rgb * global.params.w * SUN_RADIANCE_TO_IRRADIANCE / PI;
    vec3 Lo = brdf * sunColor * NdotL_final * (1.0 - totalShadow);
    vec3 envColor = computeIBLAmbient(N, roughness);
    float shadowAmbientFactor = mix(1.0, 0.2, totalShadow);
    vec3 indirect = sampleLPVAtlas(absoluteWorldPos(vFragPosWorld), N);
    vec3 skyAmbient = max(min(envColor, IBL_CLAMP) * skyLight * 0.8 * atmosphere, vec3(global.lighting.x * 0.08));
    vec3 ambientColor = albedo * (skyAmbient + blockLight + indirect) * ao * ssao * shadowAmbientFactor;
    return ambientColor + Lo;
}

vec3 computeNonPBR(vec3 albedo, vec3 N, float nDotL, float totalShadow, float skyLight, float skyVisibility, vec3 blockLight, float ao, float ssao) {
    float atmosphere = skyVisibilityFactor(skyVisibility);
    vec3 envColor = computeIBLAmbient(N, NON_PBR_ROUGHNESS);
    float shadowAmbientFactor = mix(1.0, 0.2, totalShadow);
    vec3 indirect = sampleLPVAtlas(absoluteWorldPos(vFragPosWorld), N);
    vec3 skyAmbient = max(min(envColor, IBL_CLAMP) * skyLight * 0.8 * atmosphere, vec3(global.lighting.x * 0.08));
    vec3 ambientColor = albedo * (skyAmbient + blockLight + indirect) * ao * ssao * shadowAmbientFactor;
    vec3 sunColor = global.sun_color.rgb * global.params.w * SUN_RADIANCE_TO_IRRADIANCE / PI;
    vec3 directColor = albedo * sunColor * nDotL * (1.0 - totalShadow);
    return ambientColor + directColor;
}

vec3 computeLOD(vec3 albedo, float nDotL, float totalShadow, float skyLightVal, float skyVisibility, vec3 blockLight, float ao, float ssao) {
    float atmosphere = skyVisibilityFactor(skyVisibility);
    float shadowAmbientFactor = mix(1.0, 0.2, totalShadow);
    vec3 indirect = sampleLPVAtlas(absoluteWorldPos(vFragPosWorld), vec3(0.0, 1.0, 0.0)); // LOD uses up-facing normal
    vec3 ambientColor = albedo * (max(vec3(skyLightVal * 0.8 * atmosphere), vec3(global.lighting.x * 0.08)) + blockLight + indirect) * ao * ssao * shadowAmbientFactor;
    vec3 sunColor = global.sun_color.rgb * global.params.w * SUN_VOLUMETRIC_INTENSITY / PI;
    vec3 directColor = albedo * sunColor * nDotL * (1.0 - totalShadow);
    return ambientColor + directColor;
}

// Simple shadow sampler for volumetric points, optimized
float getVolShadow(vec3 p, float viewDepth) {
    int layer = 3;
    if (viewDepth < shadows.cascade_splits[0]) layer = 0;
    else if (viewDepth < shadows.cascade_splits[1]) layer = 1;
    else if (viewDepth < shadows.cascade_splits[2]) layer = 2;
    vec4 lightSpacePos = shadows.light_space_matrices[layer] * vec4(p, 1.0);
    vec3 proj = lightSpacePos.xyz / lightSpacePos.w;
    proj.xy = proj.xy * 0.5 + 0.5;
    if (proj.x < 0.0 || proj.x > 1.0 || proj.y < 0.0 || proj.y > 1.0 || proj.z < 0.0 || proj.z > 1.0) return 1.0;
    return texture(uShadowMaps, vec4(proj.xy, float(layer), proj.z + 0.002));
}

// Henyey-Greenstein Phase Function for Mie Scattering (Phase 4)
float henyeyGreensteinVol(float g, float cosTheta) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * cosTheta, 0.01), 1.5));
}

vec4 computeVolumetric(vec3 rayStart, vec3 rayEnd, float dither) {
    if (global.volumetric_params.x < 0.5) return vec4(0.0, 0.0, 0.0, 1.0);
    vec3 rayDir = rayEnd - rayStart;
    float totalDist = length(rayDir);
    rayDir /= totalDist;
    float maxDist = min(totalDist, 180.0); 
    int steps = 16; 
    float stepSize = maxDist / float(steps);
    float cosTheta = dot(rayDir, normalize(global.sun_dir.xyz));
    float phase = henyeyGreensteinVol(global.volumetric_params.w, cosTheta);
    vec3 sunColor = global.sun_color.rgb * global.params.w * SUN_VOLUMETRIC_INTENSITY / PI;
    vec3 accumulatedScattering = vec3(0.0);
    float transmittance = 1.0;
    float density = global.volumetric_params.y * VOLUMETRIC_DENSITY_FACTOR;
    for (int i = 0; i < steps; i++) {
        float d = (float(i) + dither) * stepSize;
        vec3 p = rayStart + rayDir * d;
        float worldY = p.y + global.cam_pos.y;
        float heightFactor = exp(-max(worldY, 0.0) * 0.05);
        float stepDensity = density * heightFactor;
        if (stepDensity > 0.0001) {
            float shadow = getVolShadow(p, d);
            vec3 stepScattering = sunColor * phase * stepDensity * shadow * stepSize;
            accumulatedScattering += stepScattering * transmittance;
            transmittance *= exp(-stepDensity * stepSize);
            if (transmittance < 0.01) break;
        }
    }
    return vec4(accumulatedScattering, transmittance);
}

void main() {
    vec3 color;
    float outputAlpha = 1.0;
    const float LOD_TRANSITION_WIDTH = 24.0;
    const float AO_FADE_DISTANCE = 128.0;
    float viewDistance = length(vFragPosWorld);

    if (vMaskRadius > 0.0) {
        float distFromMask = length(vFragPosWorld.xz) - vMaskRadius;
        float fade = clamp(distFromMask / LOD_TRANSITION_WIDTH, 0.0, 1.0);
        vec2 worldXZ = vFragPosWorld.xz + global.cam_pos.xz;
        float ditherThreshold = lodTransitionNoise(worldXZ);
        if (fade < ditherThreshold) discard;
    }
    
    vec2 tiledUV = fract(vTexCoord);
    tiledUV = clamp(tiledUV, 0.001, 0.999);
    vec2 uv = (vec2(mod(float(vTileID), 16.0), floor(float(vTileID) / 16.0)) + tiledUV) * (1.0 / 16.0);

    vec3 N = normalize(vNormal);
    if (vTileID < 0) {
        N = vec3(0.0, 1.0, 0.0);
    }
    vec4 normalMapSample = vec4(0.5, 0.5, 1.0, 0.0);
    if (global.lighting.z > 0.5 && global.pbr_params.x > 1.5 && vTileID >= 0) {
        normalMapSample = texture(uNormalMap, uv);
        mat3 TBN = mat3(normalize(vTangent), normalize(vBitangent), N);
        N = normalize(TBN * (normalMapSample.rgb * 2.0 - 1.0));
    }

    vec3 L = normalize(global.sun_dir.xyz);
    float nDotL = max(dot(N, L), 0.0);
    float skyVisibility = clamp(vSkyLight, 0.0, 1.0);
    float atmosphericVisibility = skyVisibilityFactor(skyVisibility);
    int layer = vViewDepth < shadows.cascade_splits[0] ? 0
              : (vViewDepth < shadows.cascade_splits[1] ? 1
              : (vViewDepth < shadows.cascade_splits[2] ? 2 : 3));
    float shadowFactor = computeShadowCascades(vFragPosWorld, N, L, vViewDepth, layer);
    
    float cloudShadow = (atmosphericVisibility > 0.01 && global.cloud_params.y > 0.5 && global.params.w > 0.05 && global.sun_dir.y > 0.05)
        ? getCloudShadow(vFragPosWorld, global.sun_dir.xyz) * atmosphericVisibility
        : 0.0;
    float totalShadow = min(shadowFactor + cloudShadow, 1.0);

    float ssao = mix(1.0, texture(uSSAOMap, gl_FragCoord.xy / global.viewport_size.xy).r, global.pbr_params.w);
    if (vTileID < 0) {
        ssao = 1.0;
    }
    float ao = mix(1.0, vAO, mix(0.4, 0.05, clamp(viewDistance / AO_FADE_DISTANCE, 0.0, 1.0)));

    if (global.shadow_params.z <= 0.0) {
        vec3 albedo = vColor;
        if (global.lighting.y > 0.5 && vTileID >= 0) {
            vec4 texColor = texture(uTexture, uv);
            if (texColor.a < 0.1) discard;
            outputAlpha = texColor.a;
            // In simple-lighting mode, ignore the baked per-face shade encoded in vColor.
            // Preserve biome hue from vColor for tintable textures like grass/leaves,
            // but normalize away the per-face darkening baked into the mesh color.
            float maxChannel = max(max(vColor.r, vColor.g), max(vColor.b, 1e-4));
            vec3 normalizedTint = clamp(vColor / maxChannel, 0.0, 1.0);
            float chroma = max(max(normalizedTint.r, normalizedTint.g), normalizedTint.b) - min(min(normalizedTint.r, normalizedTint.g), normalizedTint.b);
            float tintStrength = smoothstep(0.05, 0.2, chroma);
            vec3 tint = mix(vec3(1.0), normalizedTint, tintStrength);
            albedo = texColor.rgb * tint;
        }
        color = computeSimpleLighting(albedo, N, L, vSkyLight, vBlockLight, ao);
    } else if (global.lighting.y > 0.5 && vTileID >= 0) {
        vec4 texColor = texture(uTexture, uv);
        if (texColor.a < 0.1) discard;
        outputAlpha = texColor.a;
        vec3 albedo = texColor.rgb * vColor;

        if (global.cloud_params.z > 0.5 && global.lighting.z > 0.5 && global.pbr_params.x > 0.5) {
            float roughness = texture(uRoughnessMap, uv).r;
            if (normalMapSample.a > 0.5 || roughness < 0.99) {
                vec3 V = normalize(global.cam_pos.xyz - vFragPosWorld);
                color = computePBR(albedo, N, V, L, clamp(roughness, 0.05, 1.0), totalShadow, vSkyLight * global.lighting.x, skyVisibility, vBlockLight, ao, ssao);
            } else {
                color = computeNonPBR(albedo, N, nDotL, totalShadow, vSkyLight * global.lighting.x, skyVisibility, vBlockLight, ao, ssao);
            }
        } else {
            color = computeLegacyDirect(albedo, nDotL, totalShadow, vSkyLight, vBlockLight, LEGACY_LIGHTING_INTENSITY) * ao * ssao;
        }
    } else if (vTileID < 0) {
        color = computeLOD(vColor, nDotL, totalShadow, vSkyLight * global.lighting.x, skyVisibility, vBlockLight, ao, ssao);
    } else {
        color = computeLegacyDirect(vColor, nDotL, totalShadow, vSkyLight, vBlockLight, LOD_LIGHTING_INTENSITY) * ao * ssao;
    }

    if (global.volumetric_params.x > 0.5 && atmosphericVisibility > 0.01) {
        vec4 volumetric = computeVolumetric(vec3(0.0), vFragPosWorld, cloudHash(gl_FragCoord.xy + vec2(global.params.x)));
        volumetric.rgb *= atmosphericVisibility;
        color = color * volumetric.a + volumetric.rgb;
    }

    if (global.params.z > 0.5) {
        float fogFactor = clamp(1.0 - exp(-viewDistance * global.params.y), 0.0, 1.0) * atmosphericVisibility;
        color = mix(color, global.fog_color.rgb, fogFactor);
    }

    vec4 cloudOverlay = (global.shadow_params.z > 0.0) ? sampleCloudOverlay(vFragPosWorld) : vec4(0.0);
    cloudOverlay.a *= atmosphericVisibility;
    color = mix(color, cloudOverlay.rgb, cloudOverlay.a);

    float debugChannel = global.viewport_size.w;
    if (global.viewport_size.z > 0.5 && debugChannel > 0.5) {
        if (debugChannel < DEBUG_SHADOW_FACTOR + 0.5) {
            vec3 debugShadow = mix(vec3(0.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), shadowFactor);
            color = mix(vec3(0.02, 0.02, 0.02), debugShadow, atmosphericVisibility);
        } else if (debugChannel < DEBUG_CASCADE_INDEX + 0.5) {
            color = (layer == 0) ? vec3(1.0, 0.2, 0.2)
                  : (layer == 1) ? vec3(0.2, 1.0, 0.2)
                  : (layer == 2) ? vec3(0.2, 0.4, 1.0)
                  : vec3(0.8, 0.3, 1.0);
        } else if (debugChannel < DEBUG_CASTER_COVERAGE + 0.5) {
            vec4 shadowCoord = shadows.light_space_matrices[layer] * vec4(vFragPosWorld, 1.0);
            vec3 projCoords = shadowCoord.xyz / shadowCoord.w * 0.5 + 0.5;
            float mapDepth = texture(uShadowMapsRegular, vec3(projCoords.xy, float(layer))).r;
            float fragDepth = projCoords.z;
            float hasCaster = (mapDepth < 0.999) ? 1.0 : 0.0;
            float isInShadow = (fragDepth > mapDepth + 0.001) ? 1.0 : 0.0;
            color = vec3(hasCaster * 0.3, isInShadow * 0.5 + 0.2, mapDepth);
        } else if (debugChannel < DEBUG_SEAM_DIAG + 0.5) {
            float nextSplit = shadows.cascade_splits[layer];
            float blendStart = nextSplit * 0.8;
            float distToSplit = abs(vViewDepth - nextSplit) / max(nextSplit, 0.01);
            float inBlend = (vViewDepth > blendStart && layer < 3) ? (vViewDepth - blendStart) / max(nextSplit - blendStart, 0.01) : 0.0;
            float splitLine = 1.0 - smoothstep(0.0, 0.05, distToSplit);
            color = vec3(splitLine, distToSplit * 2.0, clamp(inBlend, 0.0, 1.0));
        } else if (debugChannel < DEBUG_TILE_ID + 0.5) {
            if (vTileID < 0) {
                color = vec3(1.0, 0.0, 1.0);
            } else if (vTileID == 0) {
                color = vec3(1.0, 1.0, 1.0);
            } else {
                float tid = float(vTileID);
                color = vec3(fract(tid * 0.618), fract(tid * 0.381), fract(tid * 0.236));
            }
        } else if (debugChannel < DEBUG_TEX_COLOR + 0.5) {
            vec4 texColor = texture(uTexture, uv);
            color = texColor.rgb;
        }
    }

    FragColor = vec4(color, outputAlpha);
}
