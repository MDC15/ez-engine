//! OpenGL sprite backend for `ez_engine`.
//!
//! This module is intentionally NOT exported from `src/root.zig`: it depends
//! on `zglfw` (for `swapBuffers`) and a live GL 3.3 core context, which are
//! only available on Linux x86_64. Wire it as a separate module in `build.zig`
//! (see the `gl_backend` module) and import it from the OpenGL desktop app
//! only.
//!
//! It mirrors `src/gfx/wgpu/backend.zig` 1:1: the CPU-side logic (texture
//! cache key, eviction, `appendSpriteVertices`, batch iteration, capacity
//! growth) is unchanged; only the GPU objects and submission calls differ.

const std = @import("std");
const ez_engine = @import("ez_engine");
const zglfw = @import("zglfw");

// `GL_GLEXT_PROTOTYPES` makes `glcorearb.h` declare the `gl*` entry points;
// without it the header only defines types and function-pointer typedefs.
// This is not `GL/gl.h`; we deliberately include the core-profile header only.
const c = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/glcorearb.h");
});

pub const SpriteVertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    tint: [4]f32,
};

pub const SpriteBackend = struct {
    allocator: std.mem.Allocator,
    window: *zglfw.Window,
    assets: *ez_engine.Assets,
    program: c.GLuint,
    post_process_program: c.GLuint,
    vao: c.GLuint,
    vbo: c.GLuint,
    framebuffer: c.GLuint,
    scene_texture: c.GLuint,
    vertex_capacity: usize = 4096,
    vertices: std.ArrayListUnmanaged(SpriteVertex) = .empty,
    gl_textures: std.AutoHashMapUnmanaged(u64, c.GLuint) = .empty,
    retired_gl_textures: std.ArrayListUnmanaged(u64) = .empty,
    extent: ez_engine.Renderer.Extent2D = .{ .width = 0, .height = 0 },
    /// Fixed offscreen render resolution; `null` follows the window.
    render_extent: ?ez_engine.Renderer.Extent2D = null,

    const vtable = ez_engine.Renderer.Backend.VTable{
        .resize = resizeImpl,
        .render = renderImpl,
        .waitIdle = waitIdleImpl,
        .deinit = deinitImpl,
    };

    const shader_sources = @import("shader_sources");
    const vertex_source = shader_sources.gl_sprite_vertex;
    const fragment_source = shader_sources.gl_sprite_fragment;
    const post_process_vertex_source = shader_sources.gl_post_process_vertex;
    const post_process_fragment_source = shader_sources.gl_post_process_fragment;

    /// Creates the program, VAO and vertex buffer, then logs the GL
    /// implementation so software fallbacks are visible at startup. Owns all
    /// GL objects; release with `deinit`.
    pub fn init(
        allocator: std.mem.Allocator,
        window: *zglfw.Window,
        assets: *ez_engine.Assets,
    ) !SpriteBackend {
        const vertex_shader = try compileShader(c.GL_VERTEX_SHADER, vertex_source);
        defer c.glDeleteShader(vertex_shader);
        const fragment_shader = try compileShader(c.GL_FRAGMENT_SHADER, fragment_source);
        defer c.glDeleteShader(fragment_shader);
        const sprite_program = try linkProgram(vertex_shader, fragment_shader);
        errdefer c.glDeleteProgram(sprite_program);

        const post_vertex_shader = try compileShader(c.GL_VERTEX_SHADER, post_process_vertex_source);
        defer c.glDeleteShader(post_vertex_shader);
        const post_fragment_shader = try compileShader(c.GL_FRAGMENT_SHADER, post_process_fragment_source);
        defer c.glDeleteShader(post_fragment_shader);
        const post_process_program = try linkProgram(post_vertex_shader, post_fragment_shader);
        errdefer c.glDeleteProgram(post_process_program);

        var vao: c.GLuint = 0;
        c.glGenVertexArrays(1, &vao);
        errdefer c.glDeleteVertexArrays(1, &vao);
        c.glBindVertexArray(vao);

        var vbo: c.GLuint = 0;
        c.glGenBuffers(1, &vbo);
        errdefer c.glDeleteBuffers(1, &vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
        c.glBufferData(
            c.GL_ARRAY_BUFFER,
            @intCast(4096 * @sizeOf(SpriteVertex)),
            null,
            c.GL_DYNAMIC_DRAW,
        );

        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(SpriteVertex), @ptrFromInt(0));
        c.glEnableVertexAttribArray(0);
        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(SpriteVertex), @ptrFromInt(8));
        c.glEnableVertexAttribArray(1);
        c.glVertexAttribPointer(2, 4, c.GL_FLOAT, c.GL_FALSE, @sizeOf(SpriteVertex), @ptrFromInt(16));
        c.glEnableVertexAttribArray(2);

        var framebuffer: c.GLuint = 0;
        c.glGenFramebuffers(1, &framebuffer);
        errdefer c.glDeleteFramebuffers(1, &framebuffer);
        var scene_texture: c.GLuint = 0;
        c.glGenTextures(1, &scene_texture);
        errdefer c.glDeleteTextures(1, &scene_texture);

        // D9 diagnostic: report which GL implementation we actually landed on.
        const vendor = glString(c.GL_VENDOR);
        const renderer = glString(c.GL_RENDERER);
        const version = glString(c.GL_VERSION);
        std.debug.print("gl vendor: {s}\n", .{vendor});
        std.debug.print("gl renderer: {s}\n", .{renderer});
        std.debug.print("gl version: {s}\n", .{version});
        if (std.mem.startsWith(u8, renderer, "llvmpipe")) {
            std.debug.print(
                "warning: llvmpipe software renderer detected; for hardware acceleration " ++
                    "run with GALLIUM_DRIVER=d3d12 and MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA\n",
                .{},
            );
        }

        return .{
            .allocator = allocator,
            .window = window,
            .assets = assets,
            .program = sprite_program,
            .post_process_program = post_process_program,
            .vao = vao,
            .vbo = vbo,
            .framebuffer = framebuffer,
            .scene_texture = scene_texture,
            .extent = .{ .width = 0, .height = 0 },
        };
    }

    pub fn deinit(self: *SpriteBackend) void {
        deinitImpl(self);
    }

    pub fn backend(self: *SpriteBackend) ez_engine.Renderer.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn glString(name: c.GLenum) []const u8 {
        const ptr = c.glGetString(name);
        if (ptr == null) return "unknown";
        return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
    }

    fn compileShader(shader_type: c.GLenum, source: []const u8) !c.GLuint {
        const shader = c.glCreateShader(shader_type);
        if (shader == 0) return error.ShaderCreationFailed;
        errdefer c.glDeleteShader(shader);

        const source_ptr: [*c]const c.GLchar = @ptrCast(source.ptr);
        const source_length: c.GLint = @intCast(source.len);
        c.glShaderSource(shader, 1, @ptrCast(&source_ptr), @ptrCast(&source_length));
        c.glCompileShader(shader);

        var status: c.GLint = c.GL_FALSE;
        c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &status);
        if (status != c.GL_TRUE) {
            var log: [1024]u8 = undefined;
            var length: c.GLsizei = 0;
            c.glGetShaderInfoLog(shader, @intCast(log.len), &length, @ptrCast(&log));
            if (length > 0) {
                std.debug.print("gl shader compile failed: {s}\n", .{log[0..@intCast(length)]});
            } else {
                std.debug.print("gl shader compile failed: (no log)\n", .{});
            }
            return error.ShaderCompileFailed;
        }
        return shader;
    }

    fn linkProgram(vertex: c.GLuint, fragment: c.GLuint) !c.GLuint {
        const program = c.glCreateProgram();
        if (program == 0) return error.ProgramCreationFailed;
        errdefer c.glDeleteProgram(program);

        c.glAttachShader(program, vertex);
        c.glAttachShader(program, fragment);
        c.glLinkProgram(program);

        var status: c.GLint = c.GL_FALSE;
        c.glGetProgramiv(program, c.GL_LINK_STATUS, &status);
        if (status != c.GL_TRUE) {
            var log: [1024]u8 = undefined;
            var length: c.GLsizei = 0;
            c.glGetProgramInfoLog(program, @intCast(log.len), &length, @ptrCast(&log));
            if (length > 0) {
                std.debug.print("gl program link failed: {s}\n", .{log[0..@intCast(length)]});
            } else {
                std.debug.print("gl program link failed: (no log)\n", .{});
            }
            return error.ProgramLinkFailed;
        }
        return program;
    }

    fn resizeImpl(context: *anyopaque, extent: ez_engine.Renderer.Extent2D) anyerror!void {
        if (extent.width == 0 or extent.height == 0) return error.InvalidExtent;
        const self: *SpriteBackend = @ptrCast(@alignCast(context));
        const render_size = ez_engine.Renderer.resolveRenderExtent(extent, self.render_extent);
        c.glBindTexture(c.GL_TEXTURE_2D, self.scene_texture);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA8,
            @intCast(render_size.width),
            @intCast(render_size.height),
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            null,
        );
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.framebuffer);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.scene_texture, 0);
        const status = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        if (status != c.GL_FRAMEBUFFER_COMPLETE) return error.FramebufferIncomplete;
        self.extent = extent;
    }

    fn ensureTexture(self: *SpriteBackend, handle: ez_engine.Handles.TextureHandle) !c.GLuint {
        const key = (@as(u64, handle.generation) << 32) | handle.index;
        if (self.gl_textures.get(key)) |texture| return texture;
        const source = self.assets.getTexture(handle) orelse return error.InvalidTextureHandle;
        if (source.width == 0 or source.height == 0) return error.InvalidTexture;
        const format: c.GLenum = switch (source.format) {
            .rgba8 => c.GL_RGBA,
            .bgra8 => c.GL_BGRA,
        };
        var texture: c.GLuint = 0;
        c.glGenTextures(1, &texture);
        errdefer c.glDeleteTextures(1, &texture);
        c.glBindTexture(c.GL_TEXTURE_2D, texture);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA8,
            @intCast(source.width),
            @intCast(source.height),
            0,
            format,
            c.GL_UNSIGNED_BYTE,
            @ptrCast(source.pixels.ptr),
        );
        try self.gl_textures.put(self.allocator, key, texture);
        return texture;
    }

    fn evictReleasedTextures(self: *SpriteBackend) !void {
        self.retired_gl_textures.clearRetainingCapacity();
        var keys = self.gl_textures.keyIterator();
        while (keys.next()) |key| {
            const handle: ez_engine.Handles.TextureHandle = .{
                .index = @truncate(key.*),
                .generation = @truncate(key.* >> 32),
            };
            if (self.assets.getTexture(handle) == null)
                try self.retired_gl_textures.append(self.allocator, key.*);
        }

        for (self.retired_gl_textures.items) |key| {
            if (self.gl_textures.fetchRemove(key)) |entry| {
                const texture = entry.value;
                c.glDeleteTextures(1, &texture);
            }
        }
    }

    fn appendSpriteVertices(self: *SpriteBackend, world: *const ez_engine.RenderWorld) !void {
        self.vertices.clearRetainingCapacity();
        for (world.items.items) |item| {
            const half_width = item.sprite_size.x * item.scale.x * 0.5;
            const half_height = item.sprite_size.y * item.scale.y * 0.5;
            const local = [4]ez_engine.Vec3{
                .{ .x = -half_width, .y = -half_height },
                .{ .x = half_width, .y = -half_height },
                .{ .x = half_width, .y = half_height },
                .{ .x = -half_width, .y = half_height },
            };
            const source = item.source_rect;
            const uv = [4][2]f32{
                .{ source.x, source.y + source.height },
                .{ source.x + source.width, source.y + source.height },
                .{ source.x + source.width, source.y },
                .{ source.x, source.y },
            };
            var corners: [4]SpriteVertex = undefined;
            for (local, 0..) |point, index| {
                const rotated = item.rotation.rotate(point);
                const ndc = world.camera_2d.worldToNdc(.{
                    .x = item.position.x + rotated.x,
                    .y = item.position.y + rotated.y,
                });
                corners[index] = .{
                    .position = .{ ndc.x, ndc.y },
                    .uv = uv[index],
                    .tint = .{ item.tint.x, item.tint.y, item.tint.z, item.tint.w },
                };
            }
            try self.vertices.appendSlice(self.allocator, &.{
                corners[0], corners[1], corners[2],
                corners[0], corners[2], corners[3],
            });
        }
    }

    fn ensureVertexCapacity(self: *SpriteBackend, required: usize) !void {
        if (required <= self.vertex_capacity) return;
        const capacity = try std.math.ceilPowerOfTwo(usize, required);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glBufferData(
            c.GL_ARRAY_BUFFER,
            @intCast(capacity * @sizeOf(SpriteVertex)),
            null,
            c.GL_DYNAMIC_DRAW,
        );
        self.vertex_capacity = capacity;
    }

    fn renderImpl(context: *anyopaque, world: *const ez_engine.RenderWorld) anyerror!void {
        const self: *SpriteBackend = @ptrCast(@alignCast(context));
        try world.post_process.validate();
        try self.evictReleasedTextures();
        if (self.extent.width == 0 or self.extent.height == 0) return;

        try self.appendSpriteVertices(world);
        try self.ensureVertexCapacity(self.vertices.items.len);
        var upload_batches = world.batches();
        while (upload_batches.next()) |batch| {
            _ = try self.ensureTexture(batch.texture);
        }
        if (self.vertices.items.len > 0) {
            c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
            c.glBufferSubData(
                c.GL_ARRAY_BUFFER,
                0,
                @intCast(self.vertices.items.len * @sizeOf(SpriteVertex)),
                @ptrCast(self.vertices.items.ptr),
            );
        }

        const render_size = ez_engine.Renderer.resolveRenderExtent(self.extent, self.render_extent);
        c.glViewport(0, 0, @intCast(render_size.width), @intCast(render_size.height));
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.framebuffer);
        c.glClearColor(0.035, 0.055, 0.09, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        c.glEnable(c.GL_BLEND);
        c.glBlendFuncSeparate(
            c.GL_SRC_ALPHA,
            c.GL_ONE_MINUS_SRC_ALPHA,
            c.GL_ONE,
            c.GL_ONE_MINUS_SRC_ALPHA,
        );

        if (self.vertices.items.len > 0) {
            c.glUseProgram(self.program);
            c.glBindVertexArray(self.vao);
            c.glActiveTexture(c.GL_TEXTURE0);
            const sampler = c.glGetUniformLocation(self.program, "sprite_texture");
            c.glUniform1i(sampler, 0);
            var sprite_first: usize = 0;
            var batches = world.batches();
            while (batches.next()) |batch| {
                const key = (@as(u64, batch.texture.generation) << 32) | batch.texture.index;
                const texture = self.gl_textures.get(key) orelse return error.InvalidTextureHandle;
                c.glBindTexture(c.GL_TEXTURE_2D, texture);
                const first_vertex: c.GLint = @intCast(sprite_first * 6);
                const vertex_count: c.GLsizei = @intCast(batch.count * 6);
                c.glDrawArrays(c.GL_TRIANGLES, first_vertex, vertex_count);
                sprite_first += batch.count;
            }
        }

        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        c.glViewport(0, 0, @intCast(self.extent.width), @intCast(self.extent.height));
        c.glDisable(c.GL_BLEND);
        c.glUseProgram(self.post_process_program);
        c.glBindVertexArray(self.vao);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.scene_texture);
        c.glUniform1i(c.glGetUniformLocation(self.post_process_program, "scene_texture"), 0);
        c.glUniform1f(c.glGetUniformLocation(self.post_process_program, "grayscale_amount"), world.post_process.grayscale);
        c.glUniform1f(c.glGetUniformLocation(self.post_process_program, "vignette_amount"), world.post_process.vignette);
        c.glUniform1f(c.glGetUniformLocation(self.post_process_program, "exposure"), world.post_process.exposure);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        zglfw.swapBuffers(self.window);
    }

    fn waitIdleImpl(context: *anyopaque) anyerror!void {
        const self: *SpriteBackend = @ptrCast(@alignCast(context));
        _ = self;
        c.glFinish();
    }

    pub fn deinitImpl(context: *anyopaque) void {
        const self: *SpriteBackend = @ptrCast(@alignCast(context));
        var textures = self.gl_textures.valueIterator();
        while (textures.next()) |texture| c.glDeleteTextures(1, texture);
        self.gl_textures.deinit(self.allocator);
        self.retired_gl_textures.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        c.glDeleteBuffers(1, &self.vbo);
        c.glDeleteVertexArrays(1, &self.vao);
        c.glDeleteTextures(1, &self.scene_texture);
        c.glDeleteFramebuffers(1, &self.framebuffer);
        c.glDeleteProgram(self.program);
        c.glDeleteProgram(self.post_process_program);
    }
};
