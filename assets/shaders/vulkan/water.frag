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
layout(location = 9) in vec4 vClipPos;

layout(location = 0) out vec4 FragColor;

layout(set = 0, binding = 0) uniform GlobalUniforms {
    mat4 view_proj;
    mat4 view_proj_prev;
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
    vec4 lpv_params;
    vec4 lpv_origin;
} global;

layout(set = 0, binding = 1) uniform sampler2D uTexture;
layout(set = 0, binding = 9) uniform sampler2D uEnvMap;
layout(set = 0, binding = 14) uniform sampler2D uReflection;

const float PI = 3.14159265359;
const float WATER_LEVEL = 64.0;
const vec3 WATER_BASE_COLOR = vec3(0.1, 0.3, 0.5);
const float WATER_ABSORPTION_NEAR = 0.15;
const float WATER_ABSORPTION_FAR = 0.85;
const float WATER_DEPTH_ATTENUATION_DISTANCE = 5.0;

vec2 SampleSphericalMap(vec3 v) {
    vec3 n = normalize(v);
    float phi = atan(n.z, n.x);
    float theta = acos(clamp(n.y, -1.0, 1.0));
    vec2 uv;
    uv.x = phi / (2.0 * PI) + 0.5;
    uv.y = theta / PI;
    return uv;
}

void main() {
    vec3 N = normalize(vNormal);
    if (gl_FrontFacing) {
        N = -N;
    }

    vec3 V = normalize(global.cam_pos.xyz - vFragPosWorld);
    vec3 L = normalize(global.sun_dir.xyz);
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);

    vec2 screenUV = vClipPos.xy / vClipPos.w * 0.5 + 0.5;
    screenUV.y = 1.0 - screenUV.y;

    vec3 R = reflect(-V, N);
    vec2 envUV = SampleSphericalMap(R);
    vec3 envColor = textureLod(uEnvMap, envUV, 2.0).rgb;

    vec2 reflectUV = screenUV + N.xz * 0.02;
    reflectUV = clamp(reflectUV, 0.001, 0.999);
    vec3 reflectionColor = texture(uReflection, reflectUV).rgb;

    float reflectWeight = 0.4;
    vec3 reflectedColor = mix(envColor, reflectionColor, reflectWeight);

    float depthBelowSurface = max(WATER_LEVEL - vFragPosWorld.y, 0.0);
    float depthFactor = clamp(depthBelowSurface / WATER_DEPTH_ATTENUATION_DISTANCE, 0.0, 1.0);

    float fresnel = pow(1.0 - NdotV, 3.0);
    fresnel = mix(0.02, 1.0, fresnel);

    vec3 waterColor = mix(WATER_BASE_COLOR, WATER_BASE_COLOR * 0.5, depthFactor);
    waterColor = mix(waterColor, reflectedColor, fresnel * 0.6);

    float directLight = NdotL * global.params.w * (1.0 - 0.3);
    float skyLight = vSkyLight * (global.lighting.x + directLight * 0.5);
    float lightLevel = max(skyLight, max(vBlockLight.r, max(vBlockLight.g, vBlockLight.b)));
    lightLevel = max(lightLevel, global.lighting.x * 0.5);
    lightLevel = clamp(lightLevel, 0.0, 1.0);

    waterColor *= lightLevel;

    vec3 sunSpecular = vec3(0.0);
    vec3 H = normalize(V + L);
    float spec = pow(max(dot(N, H), 0.0), 256.0);
    sunSpecular = global.sun_color.rgb * global.params.w * spec * 0.5;
    waterColor += sunSpecular;

    if (global.params.z > 0.5) {
        waterColor = mix(waterColor, global.fog_color.rgb, clamp(1.0 - exp(-vDistance * global.params.y), 0.0, 1.0));
    }

    float alpha = mix(WATER_ABSORPTION_NEAR, WATER_ABSORPTION_FAR, depthFactor);
    alpha = mix(alpha, 1.0, fresnel * 0.3);

    FragColor = vec4(waterColor, alpha);
}
