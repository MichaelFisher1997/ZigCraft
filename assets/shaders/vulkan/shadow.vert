#version 450

layout(location = 0) in vec3 aPos;
layout(location = 1) in uint aNormal;
layout(location = 2) in vec2 aTexCoord;
layout(location = 3) in uint aPackedMeta;

layout(location = 0) out vec2 vTexCoord;
layout(location = 1) flat out int vTileID;
layout(location = 2) flat out int vSkipShadow;

layout(push_constant) uniform ShadowModelUniforms {
    mat4 mvp;
    vec4 bias_params;
} pc;

vec3 decodeNormal(uint packed) {
    vec2 oct = unpackSnorm2x16(packed);
    float px = oct.x;
    float py = oct.y;
    float pz = 1.0 - abs(px) - abs(py);
    if (pz < 0.0) {
        float orig_px = px;
        px = (1.0 - abs(py)) * (px >= 0.0 ? 1.0 : -1.0);
        py = (1.0 - abs(orig_px)) * (py >= 0.0 ? 1.0 : -1.0);
    }
    return normalize(vec3(px, py, pz));
}

void main() {
    vec3 worldNormal = decodeNormal(aNormal);
    float normalBias = pc.bias_params.x * pc.bias_params.w;
    vec3 biasedPos = aPos + worldNormal * normalBias;
    uint tile_id_u16 = aPackedMeta & 0xFFFFu;

    vTexCoord = aTexCoord;
    vTileID = (tile_id_u16 == 0xFFFFu) ? -1 : int(tile_id_u16);
    // Skip shadows for diagonal billboard faces, such as cross-meshed vegetation.
    vSkipShadow = (abs(worldNormal.y) < 0.001 && abs(worldNormal.x) > 0.1 && abs(worldNormal.z) > 0.1) ? 1 : 0;
    
    gl_Position = pc.mvp * vec4(biasedPos, 1.0);
}
