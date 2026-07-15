#version 450

layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;

layout(location = 0) out vec4 frag_color;

layout(set = 0, binding = 0) uniform sampler2D ui_texture;

void main() {
    frag_color = texture(ui_texture, v_uv) * v_color;
}
