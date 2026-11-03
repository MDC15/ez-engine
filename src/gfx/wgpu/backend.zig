//! WGPU sprite backend for `ez_engine`.
//!
//! This module is intentionally NOT exported from `src/root.zig`: it depends
//! on `zgpu`, which is only available on Linux x86_64. Wire it as a separate
//! module in `build.zig` (see the `wgpu_backend` module) and import it from
//! desktop examples only.

const std = @import("std");
const ez_engine = @import("ez_engine");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

pub const SpriteVertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    tint: [4]f32,
};

const GpuTexture = struct {
    texture: wgpu.Texture,
    view: wgpu.TextureView,
    bind_group: wgpu.BindGroup,

    fn deinit(self: GpuTexture) void {
        self.bind_group.release();
        self.view.release();
        self.texture.destroy();
        self.texture.release();
    }
};

const PostProcessUniforms = extern struct {
    grayscale: f32,
    vignette: f32,
    exposure: f32,
    padding: f32 = 0,
};

pub const SpriteBackend = struct {
    allocator: std.mem.Allocator,
    graphics: *zgpu.GraphicsContext,
    assets: *ez_engine.Assets,
    pipeline: wgpu.RenderPipeline,
    pipeline_layout: wgpu.PipelineLayout,
    texture_layout: wgpu.BindGroupLayout,
    post_process_pipeline: wgpu.RenderPipeline,
    post_process_layout: wgpu.BindGroupLayout,
    post_process_sampler: wgpu.Sampler,
    post_process_uniform_buffer: wgpu.Buffer,
    post_process_bind_group: ?wgpu.BindGroup = null,
    scene_texture: ?wgpu.Texture = null,
    scene_texture_view: ?wgpu.TextureView = null,
    sampler: wgpu.Sampler,
    vertex_buffer: wgpu.Buffer,
    vertex_capacity: usize = 4096,
    vertices: std.ArrayListUnmanaged(SpriteVertex) = .empty,
    gpu_textures: std.AutoHashMapUnmanaged(u64, GpuTexture) = .empty,
    retired_gpu_textures: std.ArrayListUnmanaged(u64) = .empty,
    extent: ez_engine.Renderer.Extent2D = .{ .width = 0, .height = 0 },
    /// Fixed offscreen render resolution; `null` follows the window.
    render_extent: ?ez_engine.Renderer.Extent2D = null,
    pending_work: bool = false,
    completion: ?wgpu.QueueWorkDoneStatus = null,

    const vtable = ez_engine.Renderer.Backend.VTable{
        .resize = resizeImpl,
        .render = renderImpl,
        .waitIdle = waitIdleImpl,
        .deinit = deinitImpl,
    };

    const shader_sources = @import("shader_sources");
    const sprite_shader = shader_sources.wgpu_sprite;
    const post_process_shader = shader_sources.wgpu_post_process;

    /// Creates the pipeline, sampler and vertex buffer. Owns all GPU objects;
    /// release with `deinit`.
    pub fn init(
        allocator: std.mem.Allocator,
        graphics: *zgpu.GraphicsContext,
        assets: *ez_engine.Assets,
    ) !SpriteBackend {
        const texture_layout_entries = [_]wgpu.BindGroupLayoutEntry{
            .{ .binding = 0, .visibility = .{ .fragment = true }, .texture = .{} },
            .{ .binding = 1, .visibility = .{ .fragment = true }, .sampler = .{ .binding_type = .filtering } },
        };
        const texture_layout = graphics.device.createBindGroupLayout(.{
            .entry_count = texture_layout_entries.len,
            .entries = &texture_layout_entries,
        });
        errdefer texture_layout.release();
        const layout_entries = [_]wgpu.BindGroupLayout{texture_layout};
        const pipeline_layout = graphics.device.createPipelineLayout(.{
            .bind_group_layout_count = layout_entries.len,
            .bind_group_layouts = &layout_entries,
        });
        errdefer pipeline_layout.release();

        var wgsl_descriptor = wgpu.ShaderModuleWGSLDescriptor{
            .chain = .{ .next = null, .struct_type = .shader_module_wgsl_descriptor },
            .code = sprite_shader,
        };
        const shader = graphics.device.createShaderModule(.{
            .label = "ez-engine-sprite-shader",
            .next_in_chain = @ptrCast(&wgsl_descriptor),
        });
        defer shader.release();
        const attributes = [_]wgpu.VertexAttribute{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x2, .offset = 8, .shader_location = 1 },
            .{ .format = .float32x4, .offset = 16, .shader_location = 2 },
        };
        const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
            .array_stride = @sizeOf(SpriteVertex),
            .attribute_count = attributes.len,
            .attributes = &attributes,
        }};
        const blend = wgpu.BlendState{
            .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
            .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha },
        };
        const color_targets = [_]wgpu.ColorTargetState{.{
            .format = .rgba8_unorm,
            .blend = &blend,
        }};
        const fragment = wgpu.FragmentState{
            .module = shader,
            .entry_point = "fs_main",
            .target_count = color_targets.len,
            .targets = &color_targets,
        };
        const pipeline = graphics.device.createRenderPipeline(.{
            .label = "ez-engine-sprite-pipeline",
            .layout = pipeline_layout,
            .vertex = .{
                .module = shader,
                .entry_point = "vs_main",
                .buffer_count = vertex_buffers.len,
                .buffers = &vertex_buffers,
            },
            .fragment = &fragment,
        });
        errdefer pipeline.release();

        const post_process_layout_entries = [_]wgpu.BindGroupLayoutEntry{
            .{ .binding = 0, .visibility = .{ .fragment = true }, .texture = .{} },
            .{ .binding = 1, .visibility = .{ .fragment = true }, .sampler = .{ .binding_type = .filtering } },
            .{ .binding = 2, .visibility = .{ .fragment = true }, .buffer = .{
                .binding_type = .uniform,
                .min_binding_size = @sizeOf(PostProcessUniforms),
            } },
        };
        const post_process_layout = graphics.device.createBindGroupLayout(.{
            .entry_count = post_process_layout_entries.len,
            .entries = &post_process_layout_entries,
        });
        errdefer post_process_layout.release();
        const post_process_layouts = [_]wgpu.BindGroupLayout{post_process_layout};
        const post_process_pipeline_layout = graphics.device.createPipelineLayout(.{
            .bind_group_layout_count = post_process_layouts.len,
            .bind_group_layouts = &post_process_layouts,
        });
        errdefer post_process_pipeline_layout.release();
        var post_process_wgsl_descriptor = wgpu.ShaderModuleWGSLDescriptor{
            .chain = .{ .next = null, .struct_type = .shader_module_wgsl_descriptor },
            .code = post_process_shader,
        };
        const post_process_shader_module = graphics.device.createShaderModule(.{
            .label = "ez-engine-post-process-shader",
            .next_in_chain = @ptrCast(&post_process_wgsl_descriptor),
        });
        defer post_process_shader_module.release();
        const post_process_targets = [_]wgpu.ColorTargetState{.{
            .format = graphics.swapchain_descriptor.format,
        }};
        const post_process_fragment = wgpu.FragmentState{
            .module = post_process_shader_module,
            .entry_point = "fs_main",
            .target_count = post_process_targets.len,
            .targets = &post_process_targets,
        };
        const post_process_pipeline = graphics.device.createRenderPipeline(.{
            .label = "ez-engine-post-process-pipeline",
            .layout = post_process_pipeline_layout,
            .vertex = .{
                .module = post_process_shader_module,
                .entry_point = "vs_main",
            },
            .fragment = &post_process_fragment,
        });
        errdefer post_process_pipeline.release();

        const post_process_sampler = graphics.device.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .nearest,
        });
        errdefer post_process_sampler.release();
        const post_process_uniform_buffer = graphics.device.createBuffer(.{
            .label = "ez-engine-post-process-settings",
            .usage = .{ .uniform = true, .copy_dst = true },
            .size = @sizeOf(PostProcessUniforms),
        });
        errdefer post_process_uniform_buffer.release();

        const sampler = graphics.device.createSampler(.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_filter = .nearest,
        });
        errdefer sampler.release();
        const vertex_buffer = graphics.device.createBuffer(.{
            .label = "ez-engine-sprite-vertices",
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = 4096 * @sizeOf(SpriteVertex),
        });
        return .{
            .allocator = allocator,
            .graphics = graphics,
            .assets = assets,
            .pipeline = pipeline,
            .pipeline_layout = pipeline_layout,
            .texture_layout = texture_layout,
            .post_process_pipeline = post_process_pipeline,
            .post_process_layout = post_process_layout,
            .post_process_sampler = post_process_sampler,
            .post_process_uniform_buffer = post_process_uniform_buffer,
            .sampler = sampler,
            .vertex_buffer = vertex_buffer,
        };
    }

    pub fn deinit(self: *SpriteBackend) void {
        deinitImpl(self);
    }

    pub fn backend(self: *SpriteBackend) ez_engine.Renderer.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn readScenePixel(self: *SpriteBackend, x: u32, y: u32) ![4]u8 {
        const extent = ez_engine.Renderer.resolveRenderExtent(self.extent, self.render_extent);
        if (x >= extent.width or y >= extent.height) return error.PixelOutOfBounds;
        try waitIdleImpl(self);

        const row_size = try std.math.mul(usize, extent.width, 4);
        const bytes_per_row = std.mem.alignForward(usize, row_size, 256);
        const buffer_size = try std.math.mul(usize, bytes_per_row, extent.height);
        const buffer = self.graphics.device.createBuffer(.{
            .label = "ez-engine-readback",
            .usage = .{ .copy_dst = true, .map_read = true },
            .size = @intCast(buffer_size),
        });
        defer buffer.release();

        const encoder = self.graphics.device.createCommandEncoder(null);
        defer encoder.release();
        encoder.copyTextureToBuffer(
            .{ .texture = self.scene_texture orelse return error.RenderTargetNotInitialized },
            .{
                .buffer = buffer,
                .layout = .{
                    .bytes_per_row = @intCast(bytes_per_row),
                    .rows_per_image = extent.height,
                },
            },
            .{ .width = extent.width, .height = extent.height },
        );
        const command_buffer = encoder.finish(null);
        defer command_buffer.release();
        self.graphics.queue.submit(&.{command_buffer});

        var map_status: ?wgpu.BufferMapAsyncStatus = null;
        buffer.mapAsync(.{ .read = true }, 0, buffer_size, onReadbackMapped, @ptrCast(&map_status));
        while (map_status == null) self.graphics.device.tick();
        if (map_status.? != .success) return error.ReadbackMapFailed;
        defer buffer.unmap();

        const mapped = buffer.getConstMappedRange(u8, 0, buffer_size) orelse return error.ReadbackMapFailed;
        const offset = @as(usize, y) * bytes_per_row + @as(usize, x) * 4;
        return mapped[offset..][0..4].*;
    }

    fn onReadbackMapped(status: wgpu.BufferMapAsyncStatus, userdata: ?*anyopaque) callconv(.c) void {
        const result: *?wgpu.BufferMapAsyncStatus = @ptrCast(@alignCast(userdata.?));
        result.* = status;
    }

    fn resizeImpl(context: *anyopaque, extent: ez_engine.Renderer.Extent2D) anyerror!void {
        if (extent.width == 0 or extent.height == 0) return error.InvalidExtent;
        const self: *SpriteBackend = @ptrCast(@alignCast(context));
        const render_size = ez_engine.Renderer.resolveRenderExtent(extent, self.render_extent);
        const scene_texture = self.graphics.device.createTexture(.{
            .label = "ez-engine-post-process-scene",
            .usage = .{ .render_attachment = true, .texture_binding = true, .copy_src = true },
            .size = .{ .width = render_size.width, .height = render_size.height },
            .format = .rgba8_unorm,
        });
        errdefer scene_texture.release();
        const scene_texture_view = scene_texture.createView(.{});
        errdefer scene_texture_view.release();
        const bind_group_entries = [_]wgpu.BindGroupEntry{
            .{ .binding = 0, .texture_view = scene_texture_view, .size = 0 },
            .{ .binding = 1, .sampler = self.post_process_sampler, .size = 0 },
            .{
                .binding = 2,
                .buffer = self.post_process_uniform_buffer,
                .size = @sizeOf(PostProcessUniforms),
            },
        };
        const post_process_bind_group = self.graphics.device.createBindGroup(.{
            .layout = self.post_process_layout,
            .entry_count = bind_group_entries.len,
            .entries = &bind_group_entries,
        });
        errdefer post_process_bind_group.release();
        if (self.post_process_bind_group) |old| old.release();
        if (self.scene_texture_view) |old| old.release();
        if (self.scene_texture) |old| {
            old.destroy();
            old.release();
        }
        self.scene_texture = scene_texture;
        self.scene_texture_view = scene_texture_view;
        self.post_process_bind_group = post_process_bind_group;
        self.extent = extent;
    }

    fn ensureTexture(self: *SpriteBackend, handle: ez_engine.Handles.TextureHandle) !GpuTexture {
        const key = (@as(u64, handle.generation) << 32) | handle.index;
        if (self.gpu_textures.get(key)) |gpu_texture| return gpu_texture;
        const source = self.assets.getTexture(handle) orelse return error.InvalidTextureHandle;
        if (source.width == 0 or source.height == 0) return error.InvalidTexture;
        const format: wgpu.TextureFormat = switch (source.format) {
            .rgba8 => .rgba8_unorm_srgb,
            .bgra8 => .bgra8_unorm_srgb,
        };
        const texture = self.graphics.device.createTexture(.{
            .label = "ez-engine-sprite-texture",
            .usage = .{ .copy_dst = true, .texture_binding = true },
            .size = .{ .width = source.width, .height = source.height },
            .format = format,
        });
        errdefer texture.release();
        self.graphics.queue.writeTexture(.{
            .texture = texture,
        }, .{
            .bytes_per_row = source.width * 4,
            .rows_per_image = source.height,
        }, .{ .width = source.width, .height = source.height }, u8, source.pixels);
        const view = texture.createView(.{});
        errdefer view.release();
        const entries = [_]wgpu.BindGroupEntry{
            .{ .binding = 0, .texture_view = view, .size = 0 },
            .{ .binding = 1, .sampler = self.sampler, .size = 0 },
        };
        const bind_group = self.graphics.device.createBindGroup(.{
            .layout = self.texture_layout,
            .entry_count = entries.len,
            .entries = &entries,
        });
        errdefer bind_group.release();
        const gpu_texture = GpuTexture{ .texture = texture, .view = view, .bind_group = bind_group };
        try self.gpu_textures.put(self.allocator, key, gpu_texture);
        return gpu_texture;
    }

    fn evictReleasedTextures(self: *SpriteBackend) !void {
        self.retired_gpu_textures.clearRetainingCapacity();
        var keys = self.gpu_textures.keyIterator();
        while (keys.next()) |key| {
            const handle: ez_engine.Handles.TextureHandle = .{
                .index = @truncate(key.*),
                .generation = @truncate(key.* >> 32),
            };
            if (self.assets.getTexture(handle) == null)
                try self.retired_gpu_textures.append(self.allocator, key.*);
        }

        for (self.retired_gpu_textures.items) |key| {
            if (self.gpu_textures.fetchRemove(key)) |entry| entry.value.deinit();
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
        const replacement = self.graphics.device.createBuffer(.{
            .label = "ez-engine-sprite-vertices",
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = capacity * @sizeOf(SpriteVertex),
        });
        self.vertex_buffer.release();
        self.vertex_buffer = replacement;
        self.vertex_capacity = capacity;
    }

    fn renderImpl(context: *anyopaque, world: *const ez_engine.RenderWorld) anyerror!void {
        const self: *SpriteBackend = @ptrCast(@alignCast(context));
        try world.post_process.validate();
        try self.evictReleasedTextures();
        if (self.extent.width == 0 or self.extent.height == 0 or
            self.graphics.swapchain_descriptor.width == 0 or self.graphics.swapchain_descriptor.height == 0)
            return;

        try self.appendSpriteVertices(world);
        try self.ensureVertexCapacity(self.vertices.items.len);
        var upload_batches = world.batches();
        while (upload_batches.next()) |batch| {
            _ = try self.ensureTexture(batch.texture);
        }
        if (self.vertices.items.len > 0) {
            self.graphics.queue.writeBuffer(self.vertex_buffer, 0, SpriteVertex, self.vertices.items);
        }
        const settings: PostProcessUniforms = .{
            .grayscale = world.post_process.grayscale,
            .vignette = world.post_process.vignette,
            .exposure = world.post_process.exposure,
        };
        self.graphics.queue.writeBuffer(self.post_process_uniform_buffer, 0, PostProcessUniforms, &.{settings});

        const back_buffer = self.graphics.swapchain.getCurrentTextureView();
        defer back_buffer.release();
        const scene_texture_view = self.scene_texture_view orelse return error.RenderTargetNotInitialized;
        const encoder = self.graphics.device.createCommandEncoder(null);
        defer encoder.release();
        const scene_attachments = [_]wgpu.RenderPassColorAttachment{.{
            .view = scene_texture_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0.035, .g = 0.055, .b = 0.09, .a = 1.0 },
        }};
        const scene_pass = encoder.beginRenderPass(.{
            .color_attachment_count = scene_attachments.len,
            .color_attachments = &scene_attachments,
        });
        scene_pass.setPipeline(self.pipeline);
        if (self.vertices.items.len > 0) {
            scene_pass.setVertexBuffer(0, self.vertex_buffer, 0, self.vertices.items.len * @sizeOf(SpriteVertex));
            var sprite_first: usize = 0;
            var batches = world.batches();
            while (batches.next()) |batch| {
                const key = (@as(u64, batch.texture.generation) << 32) | batch.texture.index;
                const texture = self.gpu_textures.get(key) orelse return error.InvalidTextureHandle;
                scene_pass.setBindGroup(0, texture.bind_group, null);
                const first_vertex: u32 = @intCast(sprite_first * 6);
                const vertex_count: u32 = @intCast(batch.count * 6);
                scene_pass.draw(vertex_count, 1, first_vertex, 0);
                sprite_first += batch.count;
            }
        }
        scene_pass.end();
        scene_pass.release();
        const output_attachments = [_]wgpu.RenderPassColorAttachment{.{
            .view = back_buffer,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        }};
        const post_process_pass = encoder.beginRenderPass(.{
            .color_attachment_count = output_attachments.len,
            .color_attachments = &output_attachments,
        });
        post_process_pass.setPipeline(self.post_process_pipeline);
        post_process_pass.setBindGroup(0, self.post_process_bind_group orelse return error.RenderTargetNotInitialized, null);
        post_process_pass.draw(3, 1, 0, 0);
        post_process_pass.end();
        post_process_pass.release();
        const command_buffer = encoder.finish(null);
        defer command_buffer.release();
        self.graphics.queue.submit(&.{command_buffer});
        self.pending_work = true;
        _ = self.graphics.present();
    }

    fn waitIdleImpl(context: *anyopaque) anyerror!void {
        const self: *SpriteBackend = @ptrCast(@alignCast(context));
        if (!self.pending_work) return;
        self.completion = null;
        self.graphics.queue.onSubmittedWorkDone(0, onWorkDone, @ptrCast(self));
        while (self.completion == null) self.graphics.device.tick();
        if (self.completion.? != .success) return error.QueueWorkFailed;
        self.pending_work = false;
    }

    fn onWorkDone(status: wgpu.QueueWorkDoneStatus, userdata: ?*anyopaque) callconv(.c) void {
        const self: *SpriteBackend = @ptrCast(@alignCast(userdata.?));
        self.completion = status;
    }

    pub fn deinitImpl(context: *anyopaque) void {
        const self: *SpriteBackend = @ptrCast(@alignCast(context));
        var textures = self.gpu_textures.valueIterator();
        while (textures.next()) |texture| texture.deinit();
        self.gpu_textures.deinit(self.allocator);
        self.retired_gpu_textures.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        self.vertex_buffer.release();
        self.pipeline.release();
        self.pipeline_layout.release();
        self.texture_layout.release();
        self.post_process_pipeline.release();
        self.post_process_layout.release();
        self.post_process_sampler.release();
        self.post_process_uniform_buffer.release();
        if (self.post_process_bind_group) |bind_group| bind_group.release();
        if (self.scene_texture_view) |view| view.release();
        if (self.scene_texture) |texture| {
            texture.destroy();
            texture.release();
        }
        self.sampler.release();
    }
};
