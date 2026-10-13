#version 330 core
in vec2 vUv;
in vec4 vTint;
uniform sampler2D sprite_texture;
out vec4 fragColor;
void main() {
    fragColor = texture(sprite_texture, vUv) * vTint;
}
