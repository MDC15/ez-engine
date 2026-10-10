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

pub const SpriteBackend = struct {
    allocator: std.mem.Allocator,
    graphics: *zgpu.GraphicsContext,
    assets: *ez_engine.Assets,
    pipeline: wgpu.RenderPipeline,
    pipeline_layout: wgpu.PipelineLayout,
    texture_layout: wgpu.BindGroupLayout,
    sampler: wgpu.Sampler,
    vertex_buffer: wgpu.Buffer,
    vertex_capacity: usize = 4096,
    vertices: std.ArrayListUnmanaged(SpriteVertex) = .empty,
    gpu_textures: std.AutoHashMapUnmanaged(u64, GpuTexture) = .empty,
    retired_gpu_textures: std.ArrayListUnmanaged(u64) = .empty,
    extent: ez_engine.Renderer.Extent2D = .{ .width = 0, .height = 0 },
    pending_work: bool = false,
    completion: ?wgpu.QueueWorkDoneStatus = null,

    const vtable = ez_engine.Renderer.Backend.VTable{
        .resize = resizeImpl,
        .render = renderImpl,
        .waitIdle = waitIdleImpl,
        .deinit = deinitImpl,
    };

    pub fn backend(self: *SpriteBackend) ez_engine.Renderer.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn resizeImpl(context: *anyopaque, extent: ez_engine.Renderer.Extent2D) anyerror!void {
        if (extent.width == 0 or extent.height == 0) return error.InvalidExtent;
        const self: *SpriteBackend = @ptrCast(@alignCast(context));
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

        const back_buffer = self.graphics.swapchain.getCurrentTextureView();
        defer back_buffer.release();
        const encoder = self.graphics.device.createCommandEncoder(null);
        defer encoder.release();
        const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
            .view = back_buffer,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0.035, .g = 0.055, .b = 0.09, .a = 1.0 },
        }};
        const pass = encoder.beginRenderPass(.{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
        });
        pass.setPipeline(self.pipeline);
        if (self.vertices.items.len > 0) {
            pass.setVertexBuffer(0, self.vertex_buffer, 0, self.vertices.items.len * @sizeOf(SpriteVertex));
            var sprite_first: usize = 0;
            var batches = world.batches();
            while (batches.next()) |batch| {
                const key = (@as(u64, batch.texture.generation) << 32) | batch.texture.index;
                const texture = self.gpu_textures.get(key) orelse return error.InvalidTextureHandle;
                pass.setBindGroup(0, texture.bind_group, null);
                const first_vertex: u32 = @intCast(sprite_first * 6);
                const vertex_count: u32 = @intCast(batch.count * 6);
                pass.draw(vertex_count, 1, first_vertex, 0);
                sprite_first += batch.count;
            }
        }
        pass.end();
        pass.release();
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
        self.sampler.release();
    }
};
