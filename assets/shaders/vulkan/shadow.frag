#version 450

layout(location = 0) in vec2 vTexCoord;
layout(location = 1) flat in int vTileID;
layout(location = 2) flat in int vSkipShadow;

void main() {
    if (vSkipShadow != 0) discard;
}
