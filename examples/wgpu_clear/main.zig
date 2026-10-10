const std = @import("std");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const game_lib = @import("game_lib");
const GlfwWindow = @import("glfw_window").WindowAdapter;
const wgpu = zgpu.wgpu;

const sprite_shader =
    \\struct VertexInput {
    \\    @location(0) position: vec2<f32>,
    \\    @location(1) uv: vec2<f32>,
    \\    @location(2) tint: vec4<f32>,
    \\};
    \\struct VertexOutput {
    \\    @builtin(position) position: vec4<f32>,
    \\    @location(0) uv: vec2<f32>,
    \\    @location(1) tint: vec4<f32>,
    \\};
    \\@vertex
    \\fn vs_main(input: VertexInput) -> VertexOutput {
    \\    var output: VertexOutput;
    \\    output.position = vec4<f32>(input.position, 0.0, 1.0);
    \\    output.uv = input.uv;
    \\    output.tint = input.tint;
    \\    return output;
    \\}
    \\@group(0) @binding(0) var sprite_texture: texture_2d<f32>;
    \\@group(0) @binding(1) var sprite_sampler: sampler;
    \\@fragment
    \\fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    \\    return textureSample(sprite_texture, sprite_sampler, input.uv) * input.tint;
    \\}
;

const SpriteVertex = extern struct {
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

const SpriteBackend = struct {
    allocator: std.mem.Allocator,
    graphics: *zgpu.GraphicsContext,
    assets: *game_lib.Assets,
    pipeline: wgpu.RenderPipeline,
    pipeline_layout: wgpu.PipelineLayout,
    texture_layout: wgpu.BindGroupLayout,
    sampler: wgpu.Sampler,
    vertex_buffer: wgpu.Buffer,
    vertex_capacity: usize = 4096,
    vertices: std.ArrayListUnmanaged(SpriteVertex) = .empty,
    gpu_textures: std.AutoHashMapUnmanaged(u64, GpuTexture) = .empty,
    retired_gpu_textures: std.ArrayListUnmanaged(u64) = .empty,
    extent: game_lib.Renderer.Extent2D = .{ .width = 0, .height = 0 },
    pending_work: bool = false,
    completion: ?wgpu.QueueWorkDoneStatus = null,

    const vtable = game_lib.Renderer.Backend.VTable{
        .resize = resizeImpl,
        .render = renderImpl,
        .waitIdle = waitIdleImpl,
        .deinit = deinitImpl,
    };

    fn backend(self: *SpriteBackend) game_lib.Renderer.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn resizeImpl(context: *anyopaque, extent: game_lib.Renderer.Extent2D) anyerror!void {
        if (extent.width == 0 or extent.height == 0) return error.InvalidExtent;
        const self: *SpriteBackend = @ptrCast(@alignCast(context));
        self.extent = extent;
    }

    fn ensureTexture(self: *SpriteBackend, handle: game_lib.Handles.TextureHandle) !GpuTexture {
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
            const handle: game_lib.Handles.TextureHandle = .{
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

    fn appendSpriteVertices(self: *SpriteBackend, world: *const game_lib.RenderWorld) !void {
        self.vertices.clearRetainingCapacity();
        for (world.items.items) |item| {
            if (item.kind != .sprite) continue;
            const half_width = item.sprite_size.x * item.scale.x * 0.5;
            const half_height = item.sprite_size.y * item.scale.y * 0.5;
            const local = [4]game_lib.Vec3{
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

    fn renderImpl(context: *anyopaque, world: *const game_lib.RenderWorld) anyerror!void {
        const self: *SpriteBackend = @ptrCast(@alignCast(context));
        try self.evictReleasedTextures();
        if (self.extent.width == 0 or self.extent.height == 0 or
            self.graphics.swapchain_descriptor.width == 0 or self.graphics.swapchain_descriptor.height == 0)
            return;

        try self.appendSpriteVertices(world);
        try self.ensureVertexCapacity(self.vertices.items.len);
        var upload_batches = world.batches();
        while (upload_batches.next()) |batch| {
            if (batch.kind == .sprite) _ = try self.ensureTexture(batch.texture);
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
                if (batch.kind != .sprite) continue;
                const key = (@as(u64, batch.texture.generation) << 32) | batch.texture.index;
                const texture = self.gpu_textures.get(key) orelse unreachable;
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

    fn deinitImpl(context: *anyopaque) void {
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

const PlayerController = struct {
    const Animation = game_lib.RenderComponents.SpriteAnimation;
    const idle_clip: Animation.Clip = .{ .first_frame = 0, .frame_count = 1, .frames_per_second = 1 };
    const walk_clip: Animation.Clip = .{ .first_frame = 1, .frame_count = 4, .frames_per_second = 8 };

    game: *game_lib.Game,
    input: *const game_lib.Input,
    player: game_lib.Entity,
    fn keyDown(input: *const game_lib.Input, code: u16) bool {
        const state = input.keyCode(code) catch return false;
        return state.down;
    }

    fn update(context: ?*anyopaque, world: *game_lib.World, dt: f32) anyerror!void {
        const self: *PlayerController = @ptrCast(@alignCast(context.?));
        if (keyDown(self.input, 256)) self.game.running = false; // Escape
        var direction = game_lib.Vec2.zero;
        if (keyDown(self.input, 65)) direction.x -= 1; // A
        if (keyDown(self.input, 68)) direction.x += 1; // D
        if (keyDown(self.input, 83)) direction.y -= 1; // S
        if (keyDown(self.input, 87)) direction.y += 1; // W
        if (direction.x != 0 and direction.y != 0) direction = game_lib.Vec2.scale(direction, 0.70710678);
        const transform = try world.get(self.player, game_lib.RenderComponents.Transform);
        transform.position.x += direction.x * 260 * dt;
        transform.position.y += direction.y * 260 * dt;

        const animation = try world.get(self.player, Animation);
        animation.play(if (direction.x == 0 and direction.y == 0) idle_clip else walk_clip);
    }
};

const Collectible = struct {};

const PickupListener = struct {
    fn onContact(context: ?*anyopaque, world: *game_lib.World, event: game_lib.Collision2D.Event) anyerror!void {
        const game: *game_lib.Game = @ptrCast(@alignCast(context.?));
        if (event.kind != .stay) {
            try game.logger.formatCategory(
                game.allocator,
                .info,
                "collision",
                "{s} entity={d}:{d} with entity={d}:{d}",
                .{
                    @tagName(event.kind),
                    event.a.id,
                    event.a.generation,
                    event.b.id,
                    event.b.generation,
                },
            );
        }
        if (event.kind != .begin) return;
        const item = if (world.has(event.a, Collectible)) event.a else if (world.has(event.b, Collectible)) event.b else return;
        try game.logger.formatCategory(
            game.allocator,
            .info,
            "gameplay",
            "Picked up item entity={d}:{d}",
            .{ item.id, item.generation },
        );
        try world.destroy(item);
    }
};

const DebugReporter = struct {
    game: *game_lib.Game,
    elapsed_seconds: f32 = 0,

    fn update(context: ?*anyopaque, _: *game_lib.World, dt: f32) anyerror!void {
        const self: *DebugReporter = @ptrCast(@alignCast(context.?));
        const toggle = self.game.input.keyCode(292) catch return; // F3
        if (toggle.pressed) {
            self.game.debug.enabled = !self.game.debug.enabled;
            self.elapsed_seconds = 0;
            self.game.logger.writeCategory(
                .info,
                "debug",
                if (self.game.debug.enabled) "Runtime stats enabled" else "Runtime stats disabled",
            );
        }
        if (!self.game.debug.enabled) return;

        self.elapsed_seconds += dt;
        if (self.elapsed_seconds < 1) return;
        self.elapsed_seconds = @mod(self.elapsed_seconds, 1);

        const stats = self.game.debug.stats;
        self.game.logger.formatCategory(
            self.game.allocator,
            .info,
            "debug",
            "frame={d} fps={d:.1} dt={d:.2}ms entities={d} sprites={d}/{d} culled={d} batches={d}",
            .{
                stats.frame_index,
                stats.fps,
                stats.frame_time_ms,
                stats.entity_count,
                stats.visible_render_items,
                stats.extracted_render_items,
                stats.culled_render_items,
                stats.render_batches,
            },
        ) catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var window = try GlfwWindow.init(1280, 720, "ez-engine | textured 2D sprites");
    defer window.deinit();

    const graphics = try zgpu.GraphicsContext.create(allocator, .{
        .window = window.native(),
        .fn_getTime = @ptrCast(&zglfw.getTime),
        .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
        .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
        .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
        .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
        .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
        .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
        .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
    }, .{});
    defer graphics.destroy(allocator);

    const texture_layout_entries = [_]wgpu.BindGroupLayoutEntry{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .texture = .{} },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .sampler = .{ .binding_type = .filtering } },
    };
    const texture_layout = graphics.device.createBindGroupLayout(.{
        .entry_count = texture_layout_entries.len,
        .entries = &texture_layout_entries,
    });
    var texture_layout_owned = true;
    defer if (texture_layout_owned) texture_layout.release();
    const layout_entries = [_]wgpu.BindGroupLayout{texture_layout};
    const pipeline_layout = graphics.device.createPipelineLayout(.{
        .bind_group_layout_count = layout_entries.len,
        .bind_group_layouts = &layout_entries,
    });
    var pipeline_layout_owned = true;
    defer if (pipeline_layout_owned) pipeline_layout.release();

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
        .format = graphics.swapchain_descriptor.format,
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
    var pipeline_owned = true;
    defer if (pipeline_owned) pipeline.release();
    const sampler = graphics.device.createSampler(.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .mipmap_filter = .nearest,
    });
    var sampler_owned = true;
    defer if (sampler_owned) sampler.release();
    var backend = SpriteBackend{
        .allocator = allocator,
        .graphics = graphics,
        .assets = undefined,
        .pipeline = pipeline,
        .pipeline_layout = pipeline_layout,
        .texture_layout = texture_layout,
        .sampler = sampler,
        .vertex_buffer = graphics.device.createBuffer(.{
            .label = "ez-engine-sprite-vertices",
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = 4096 * @sizeOf(SpriteVertex),
        }),
    };
    var backend_transferred = false;
    defer if (!backend_transferred) SpriteBackend.deinitImpl(&backend);
    texture_layout_owned = false;
    pipeline_layout_owned = false;
    pipeline_owned = false;
    sampler_owned = false;

    var game = try game_lib.Game.init(allocator, 2);
    defer game.deinit();
    backend.assets = &game.assets;
    const player_sheet = try game.assets.loadTextureFile(init.io, "assets/player_sheet.png", 16 * 1024 * 1024);
    const decoration_texture = try game.assets.loadTextureFile(init.io, "assets/sprite.png", 16 * 1024 * 1024);
    const sprite = try game.world.create();
    try game.world.add(sprite, game_lib.RenderComponents.Transform{ .position = .{ .x = 0, .y = 0 } });
    try game.world.add(sprite, game_lib.RenderComponents.SpriteRenderer{
        .texture = player_sheet,
        .size = .{ .x = 240, .y = 240 },
        .z_index = 0,
    });
    try game.world.add(sprite, game_lib.RenderComponents.SpriteAnimation{
        .sheet = .{ .columns = 5, .rows = 1 },
        .clip = PlayerController.idle_clip,
    });
    try game.world.add(sprite, game_lib.Collision2D.Collider2D{
        .size = .{ .x = 48, .y = 48 },
        .solid = true,
    });
    const second = try game.world.create();
    try game.world.add(second, game_lib.RenderComponents.Transform{ .position = .{ .x = 220, .y = 60 } });
    try game.world.add(second, game_lib.RenderComponents.SpriteRenderer{
        .texture = decoration_texture,
        .size = .{ .x = 150, .y = 150 },
        .tint = .{ .x = 0.55, .y = 0.8, .z = 1, .w = 0.85 },
        .z_index = 1,
    });
    const pickup = try game.world.create();
    try game.world.add(pickup, game_lib.RenderComponents.Transform{ .position = .{ .x = 300, .y = 0 } });
    try game.world.add(pickup, game_lib.RenderComponents.SpriteRenderer{
        .texture = decoration_texture,
        .size = .{ .x = 48, .y = 48 },
        .tint = .{ .x = 1, .y = 0.7, .z = 0.2, .w = 1 },
        .z_index = 1,
    });
    try game.world.add(pickup, game_lib.Collision2D.Collider2D{ .size = .{ .x = 40, .y = 40 } });
    try game.world.add(pickup, Collectible{});
    const wall = try game.world.create();
    try game.world.add(wall, game_lib.RenderComponents.Transform{ .position = .{ .x = 0, .y = 150 } });
    try game.world.add(wall, game_lib.RenderComponents.SpriteRenderer{
        .texture = decoration_texture,
        .size = .{ .x = 100, .y = 60 },
        .tint = .{ .x = 0.45, .y = 0.5, .z = 0.6, .w = 1 },
        .z_index = 1,
    });
    try game.world.add(wall, game_lib.Collision2D.Collider2D{
        .size = .{ .x = 100, .y = 60 },
        .solid = true,
        .is_static = true,
    });
    game.renderer = backend.backend();
    backend_transferred = true;

    var player_controller = PlayerController{ .game = &game, .input = &game.input, .player = sprite };
    _ = try game.scheduler.addSystem("Player movement", &player_controller, PlayerController.update);
    _ = try game.scheduler.addSystem("Sprite animation", null, game_lib.SpriteAnimation.updateSystem);
    var collisions = game_lib.Collision2D.System.init(allocator);
    defer collisions.deinit();
    collisions.setListener(&game, PickupListener.onContact);
    _ = try game.scheduler.addSystem("2D collision", &collisions, game_lib.Collision2D.System.updateSystem);
    var camera_follow = game_lib.CameraFollow2D.System.init(&game.camera_2d, sprite);
    camera_follow.follow_speed = 7;
    _ = try game.scheduler.addSystem("Camera follow", &camera_follow, game_lib.CameraFollow2D.System.updateSystem);
    var debug_reporter = DebugReporter{ .game = &game };
    _ = try game.scheduler.addSystem("Debug stats", &debug_reporter, DebugReporter.update);
    game.logger.writeCategory(.info, "sample", "Press F3 to toggle runtime statistics");
    try game.run(init.io, window.platformWindow());
}
