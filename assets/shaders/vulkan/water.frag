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
layout(set = 0, binding = 15) uniform sampler2D uSceneDepth;

const float PI = 3.14159265359;
const float WATER_LEVEL = 64.0;
const float F0_WATER = 0.02;

const vec3 WATER_SHALLOW = vec3(0.1, 0.6, 0.8);
const vec3 WATER_DEEP = vec3(0.02, 0.05, 0.15);
const float WATER_MAX_DEPTH = 10.0;

const float WAVE_AMPLITUDE = 0.5;
const float WAVE_FREQUENCY = 1.5;
const float WAVE_SPEED = 0.8;

vec2 SampleSphericalMap(vec3 v) {
    vec3 n = normalize(v);
    float phi = atan(n.z, n.x);
    float theta = acos(clamp(n.y, -1.0, 1.0));
    vec2 uv;
    uv.x = phi / (2.0 * PI) + 0.5;
    uv.y = theta / PI;
    return uv;
}

float schlickFresnel(float cos_theta, float F0) {
    return F0 + (1.0 - F0) * pow(1.0 - cos_theta, 5.0);
}

vec3 gerstnerWave(vec2 pos, float time, vec2 direction, float wavelength, float amplitude) {
    float k = 2.0 * PI / wavelength;
    float c = sqrt(9.8 / k);
    vec2 d = normalize(direction);
    float f = k * (dot(d, pos) - c * time);
    float a = amplitude * k;
    return vec3(
        d.x * (a * cos(f)),
        a * sin(f),
        d.y * (a * cos(f))
    );
}

vec3 getProceduralWaveNormal(vec2 pos, float time) {
    vec3 wave1 = gerstnerWave(pos, time * WAVE_SPEED, vec2(1.0, 0.3), 8.0, WAVE_AMPLITUDE * 0.4);
    vec3 wave2 = gerstnerWave(pos, time * WAVE_SPEED * 1.2, vec2(-0.5, 0.8), 5.0, WAVE_AMPLITUDE * 0.3);
    vec3 wave3 = gerstnerWave(pos, time * WAVE_SPEED * 0.8, vec2(0.3, -0.6), 12.0, WAVE_AMPLITUDE * 0.5);
    vec3 wave4 = gerstnerWave(pos, time * WAVE_SPEED * 1.5, vec2(-0.7, -0.4), 3.0, WAVE_AMPLITUDE * 0.2);
    
    vec3 displacement = wave1 + wave2 + wave3 + wave4;
    
    vec3 normal = vec3(-displacement.x, 1.0, -displacement.z);
    return normalize(normal);
}

float linearizeDepth(float depth, float near, float far) {
    return (2.0 * near * far) / (far + near - depth * (far - near));
}

void main() {
    float time = global.params.x;
    
    vec3 base_normal = normalize(vNormal);
    if (gl_FrontFacing) {
        base_normal = -base_normal;
    }
    
    vec2 wave_pos = vFragPosWorld.xz * 0.1;
    vec3 wave_normal = getProceduralWaveNormal(wave_pos, time);
    vec3 N = normalize(base_normal + wave_normal * 0.2);
    
    vec3 V = normalize(global.cam_pos.xyz - vFragPosWorld);
    float NdotV = max(dot(N, V), 0.0);
    
    vec3 L = normalize(global.sun_dir.xyz);
    float NdotL = max(dot(N, L), 0.0);
    
    float fresnel = schlickFresnel(NdotV, F0_WATER);
    fresnel = clamp(fresnel, 0.02, 1.0);
    
    vec2 screenUV = vClipPos.xy / vClipPos.w * 0.5 + 0.5;
    screenUV.y = 1.0 - screenUV.y;
    
    vec3 R = reflect(-V, N);
    vec2 envUV = SampleSphericalMap(R);
    vec3 envColor = textureLod(uEnvMap, envUV, 2.0).rgb;
    
    vec2 reflectUV = screenUV + N.xz * 0.03;
    reflectUV = clamp(reflectUV, 0.001, 0.999);
    vec3 reflectionColor = texture(uReflection, reflectUV).rgb;
    
    float scene_depth_raw = texture(uSceneDepth, screenUV).r;
    float scene_depth_linear = linearizeDepth(scene_depth_raw, 0.1, 1000.0);
    float surface_depth = -vViewDepth;
    float water_depth = scene_depth_linear - surface_depth;
    water_depth = max(water_depth, 0.0);
    
    float depth_factor = clamp(water_depth / WATER_MAX_DEPTH, 0.0, 1.0);
    
    vec3 shallow_water = mix(WATER_SHALLOW, WATER_SHALLOW * 1.2, 0.3);
    vec3 deep_water = mix(WATER_DEEP, WATER_DEEP * 0.8, 0.2);
    vec3 absorption = mix(shallow_water, deep_water, depth_factor);
    
    vec3 refraction_color = absorption;
    
    vec3 waterColor = mix(refraction_color, reflectionColor, fresnel);
    waterColor = mix(waterColor, envColor, fresnel * 0.3);
    
    float direct_light = NdotL * global.params.w * (1.0 - 0.3);
    float sky_light = vSkyLight * (global.lighting.x + direct_light * 0.5);
    float light_level = max(sky_light, max(vBlockLight.r, max(vBlockLight.g, vBlockLight.b)));
    light_level = max(light_level, global.lighting.x * 0.5);
    light_level = clamp(light_level, 0.0, 1.0);
    
    waterColor *= light_level;
    
    vec3 H = normalize(V + L);
    float spec = pow(max(dot(N, H), 0.0), 256.0);
    vec3 sun_specular = global.sun_color.rgb * global.params.w * spec * 0.8;
    
    vec3 view_reflect = reflect(-V, wave_normal);
    float view_spec = pow(max(dot(view_reflect, L), 0.0), 128.0);
    sun_specular += global.sun_color.rgb * view_spec * 0.5;
    
    waterColor += sun_specular;
    
    if (global.params.z > 0.5) {
        waterColor = mix(waterColor, global.fog_color.rgb, clamp(1.0 - exp(-vDistance * global.params.y), 0.0, 1.0));
    }
    
    float alpha = mix(0.6, 0.95, depth_factor);
    alpha = mix(alpha, 1.0, fresnel * 0.5);
    alpha = clamp(alpha, 0.5, 1.0);
    
    FragColor = vec4(waterColor, alpha);
}
