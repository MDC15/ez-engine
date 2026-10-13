#version 330 core
layout(location = 0) in vec2 position;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec4 tint;
out vec2 vUv;
out vec4 vTint;
void main() {
    vUv = uv;
    vTint = tint;
    gl_Position = vec4(position, 0.0, 1.0);
}
