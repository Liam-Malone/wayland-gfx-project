#version 450

layout(location = 0) out vec4 f_color;

void main() {
    // f_color = vec4(v_color, 1.0);
    f_color = vec4(1, 0.7, 0.5, 1);
}
