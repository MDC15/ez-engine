struct PostProcessSettings {
    grayscale: f32,
    vignette: f32,
    exposure: f32,
    padding: f32,
};
struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};
@group(0) @binding(0) var scene_texture: texture_2d<f32>;
@group(0) @binding(1) var scene_sampler: sampler;
@group(0) @binding(2) var<uniform> settings: PostProcessSettings;
@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    var output: VertexOutput;
    let position = vec2<f32>(f32((vertex_index << 1u) & 2u), f32(vertex_index & 2u));
    output.uv = vec2<f32>(position.x, 1.0 - position.y);
    output.position = vec4<f32>(position * 2.0 - vec2<f32>(1.0), 0.0, 1.0);
    return output;
}
@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    let color = textureSample(scene_texture, scene_sampler, input.uv);
    let exposed_rgb = color.rgb * settings.exposure;
    let luminance = dot(exposed_rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
    let grayscale_rgb = mix(exposed_rgb, vec3<f32>(luminance), settings.grayscale);
    let radius = length(input.uv - vec2<f32>(0.5)) * 1.41421356;
    let vignette = 1.0 - smoothstep(0.25, 0.95, radius);
    let vignette_rgb = grayscale_rgb * mix(1.0, vignette, settings.vignette);
    return vec4<f32>(vignette_rgb, color.a);
}
