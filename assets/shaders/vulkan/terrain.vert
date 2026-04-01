#version 450

layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aColor;
layout(location = 2) in vec3 aNormal;
layout(location = 3) in vec2 aTexCoord;
layout(location = 4) in float aTileID;
layout(location = 5) in float aSkyLight;
layout(location = 6) in vec3 aBlockLight;
layout(location = 7) in float aAO;

layout(location = 0) out vec3 vColor;
layout(location = 1) flat out vec3 vNormal;
layout(location = 2) out vec2 vTexCoord;
layout(location = 3) flat out int vTileID;
layout(location = 4) out float vDistance;
layout(location = 5) out float vSkyLight;
layout(location = 6) out vec3 vBlockLight;
layout(location = 7) out vec3 vFragPosWorld;
layout(location = 8) out float vViewDepth;
layout(location = 9) out vec3 vTangent;
layout(location = 10) out vec3 vBitangent;
layout(location = 11) out float vAO;
layout(location = 12) out vec4 vClipPosCurrent;
layout(location = 13) out vec4 vClipPosPrev;
layout(location = 14) out float vMaskRadius;

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

struct InstanceData {
    mat4 view_proj;
    mat4 model;
    float mask_radius;
    float _pad0;
    float _pad1;
    float _pad2;
};

layout(set = 0, binding = 5) readonly buffer InstanceBuffer {
    InstanceData instances[];
} instance_buf;

layout(push_constant) uniform ModelUniforms {
    mat4 model;
    vec3 color_override;
    float mask_radius;
} model_data;

void main() {
    mat4 model;
    float mask_radius;
    vec3 color_override;

    if (model_data.mask_radius < 0.0) {
        InstanceData inst = instance_buf.instances[gl_InstanceIndex];
        model = inst.model;
        mask_radius = inst.mask_radius;
        color_override = vec3(1.0);
    } else {
        model = model_data.model;
        mask_radius = model_data.mask_radius;
        color_override = model_data.color_override;
    }

    vec4 worldPos = model * vec4(aPos, 1.0);
    vec4 clipPos = global.view_proj * worldPos;
    vec4 clipPosPrev = global.view_proj_prev * worldPos;

    gl_Position = clipPos;
    gl_Position.y = -gl_Position.y;

    vClipPosCurrent = vec4(clipPos.x, -clipPos.y, clipPos.z, clipPos.w);
    vClipPosPrev = vec4(clipPosPrev.x, -clipPosPrev.y, clipPosPrev.z, clipPosPrev.w);

    vColor = aColor * color_override;
    vNormal = aNormal;
    vTexCoord = aTexCoord;
    vTileID = int(aTileID);
    vDistance = length(worldPos.xyz);
    vSkyLight = aSkyLight;
    vBlockLight = aBlockLight;

    vFragPosWorld = worldPos.xyz;
    vViewDepth = -clipPos.w;
    vAO = aAO;
    vMaskRadius = mask_radius;

    vec3 absNormal = abs(aNormal);
    if (absNormal.y > 0.9) {
        vTangent = vec3(1.0, 0.0, 0.0);
        vBitangent = vec3(0.0, 0.0, aNormal.y > 0.0 ? 1.0 : -1.0);
    } else if (absNormal.x > 0.9) {
        vTangent = vec3(0.0, 0.0, aNormal.x > 0.0 ? -1.0 : 1.0);
        vBitangent = vec3(0.0, 1.0, 0.0);
    } else {
        vTangent = vec3(aNormal.z > 0.0 ? 1.0 : -1.0, 0.0, 0.0);
        vBitangent = vec3(0.0, 1.0, 0.0);
    }
}
