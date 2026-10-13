#version 330 core
in vec2 vUv;
uniform sampler2D scene_texture;
uniform float grayscale_amount;
uniform float vignette_amount;
uniform float exposure;
out vec4 fragColor;
void main() {
    vec4 color = texture(scene_texture, vUv);
    color.rgb *= exposure;
    float luminance = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(color.rgb, vec3(luminance), grayscale_amount);
    float vignette = 1.0 - smoothstep(0.25, 0.95, length(vUv - vec2(0.5)) * 1.41421356);
    color.rgb *= mix(1.0, vignette, vignette_amount);
    fragColor = color;
}
