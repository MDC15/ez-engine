# Shaders

The engine ships GLSL 330 sources for OpenGL and WGSL sources for WGPU. The
project scaffold copies this directory into `Assets/Shaders`. Project builds
read shader sources from that folder, so edit the files there and rebuild to
use your changes (runtime hot reload is not enabled).

The sprite shaders render the scene. The post-process shaders then apply
grayscale, vignette and exposure adjustments. In code, set
`game.post_process` (`grayscale` and `vignette` in `0...1`; `exposure` in
`0...8`). The default settings are neutral. Both backend shader variants are
included for adaptation by custom rendering code.
