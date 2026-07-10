#version 450

layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in int vTileID;

layout(set = 0, binding = 1) uniform sampler2D uTexture;

const float TILE_SIZE = 1.0 / 16.0;
const float CUTOUT_ALPHA = 0.1;

void main() {
    if (vTileID >= 0) {
        vec2 tile = vec2(float(vTileID % 16), float(vTileID / 16));
        vec2 padding = vec2(0.5) / vec2(textureSize(uTexture, 0));
        vec2 localUv = clamp(fract(vTexCoord), padding / TILE_SIZE, vec2(1.0) - padding / TILE_SIZE);
        if (texture(uTexture, tile * TILE_SIZE + localUv * TILE_SIZE).a < CUTOUT_ALPHA) discard;
    }
}
