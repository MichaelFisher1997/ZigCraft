#version 450

layout(location = 0) in vec2 a_position;
layout(location = 1) in vec4 a_color;
layout(location = 2) in vec2 a_uv;

layout(location = 0) out vec4 v_color;
layout(location = 1) out vec2 v_uv;

layout(push_constant) uniform PushConstants {
    mat4 projection;
    layout(offset = 64) vec2 translation;
} pc;

void main() {
    gl_Position = pc.projection * vec4(a_position + pc.translation, 0.0, 1.0);
    gl_Position.y = -gl_Position.y;
    v_color = a_color;
    v_uv = a_uv;
}
