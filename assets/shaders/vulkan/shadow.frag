#version 450

layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in int vTileID;
layout(location = 2) flat in int vSkipShadow;

layout(set = 0, binding = 1) uniform sampler2D uTexture;

void main() {
    if (vSkipShadow != 0) discard;

    if (vTileID >= 0) {
        vec2 tiledUV = fract(vTexCoord);
        tiledUV = clamp(tiledUV, 0.001, 0.999);
        vec2 uv = (vec2(mod(float(vTileID), 16.0), floor(float(vTileID) / 16.0)) + tiledUV) * (1.0 / 16.0);
        if (texture(uTexture, uv).a < 0.1) discard;
    }
}
