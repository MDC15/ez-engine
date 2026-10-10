const std = @import("std");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zgui = @import("zgui");
const GlfwWindow = @import("glfw_window").WindowAdapter;
const Scene = @import("scene.zig");
const wgpu = zgpu.wgpu;

const scene_path = "editor_scene.json";

const Editor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    document: Scene.Document,
    selected_id: ?u32 = null,
    status: [160]u8 = undefined,
    status_len: usize = 0,

    fn init(allocator: std.mem.Allocator, io: std.Io) !Editor {
        var editor = Editor{
            .allocator = allocator,
            .io = io,
            .document = Scene.Document.init(allocator),
        };
        errdefer editor.document.deinit();
        if (try editor.loadInitialScene()) {
            editor.setStatus("Opened {s}", .{scene_path});
        } else {
            editor.setStatus("New scene", .{});
        }
        return editor;
    }

    fn deinit(self: *Editor) void {
        self.document.deinit();
    }

    fn newScene(self: *Editor) !void {
        self.document.objects.clearRetainingCapacity();
        self.document.next_id = 1;
        self.selected_id = try self.document.add(.sprite);
        _ = try self.document.add(.obstacle);
        _ = try self.document.add(.pickup);
        self.document.get(self.document.objects.items[1].id).?.position = .{ 100, 80 };
        self.document.get(self.document.objects.items[2].id).?.position = .{ 220, -100 };
    }

    fn loadInitialScene(self: *Editor) !bool {
        self.document.load(self.io, scene_path) catch |err| switch (err) {
            error.FileNotFound => {
                try self.newScene();
                return false;
            },
            else => return err,
        };
        self.selected_id = if (self.document.objects.items.len > 0)
            self.document.objects.items[0].id
        else
            null;
        return true;
    }

    fn setStatus(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.bufPrint(&self.status, fmt, args) catch "Status message too long";
        self.status_len = message.len;
    }

    fn save(self: *Editor) void {
        self.document.save(self.io, scene_path) catch |err| {
            self.setStatus("Save failed: {s}", .{@errorName(err)});
            return;
        };
        self.setStatus("Saved {s}", .{scene_path});
    }

    fn load(self: *Editor) void {
        self.document.load(self.io, scene_path) catch |err| {
            self.setStatus("Open failed: {s}", .{@errorName(err)});
            return;
        };
        self.selected_id = if (self.document.objects.items.len > 0)
            self.document.objects.items[0].id
        else
            null;
        self.setStatus("Opened {s}", .{scene_path});
    }

    fn addObject(self: *Editor, kind: Scene.ObjectKind) !void {
        self.selected_id = try self.document.add(kind);
        self.setStatus("Created {s} #{d}", .{ @tagName(kind), self.selected_id.? });
    }

    fn frame(self: *Editor, window_width: f32, window_height: f32) !void {
        const width = @max(window_width, 1);
        const height = @max(window_height, 1);
        const menu_height: f32 = 24;
        const hierarchy_width = @min(260, @max(190, width * 0.20));
        const inspector_width = @min(300, @max(220, width * 0.23));
        const assets_height = @min(160, @max(110, height * 0.19));
        const scene_width = width - hierarchy_width - inspector_width;
        const scene_height = height - menu_height - assets_height;

        if (zgui.beginMainMenuBar()) {
            if (zgui.beginMenu("File", true)) {
                if (zgui.menuItem("New scene", .{})) try self.newScene();
                if (zgui.menuItem("Open scene", .{})) self.load();
                if (zgui.menuItem("Save scene", .{})) self.save();
                zgui.endMenu();
            }
            if (zgui.beginMenu("Create", true)) {
                if (zgui.menuItem("Sprite", .{})) try self.addObject(.sprite);
                if (zgui.menuItem("Obstacle", .{})) try self.addObject(.obstacle);
                if (zgui.menuItem("Pickup", .{})) try self.addObject(.pickup);
                zgui.endMenu();
            }
            zgui.sameLine(.{});
            zgui.textDisabled("ez-engine editor  |  {s}", .{scene_path});
            zgui.endMainMenuBar();
        }

        zgui.setNextWindowPos(.{ .x = 0, .y = menu_height, .cond = .always });
        zgui.setNextWindowSize(.{ .w = hierarchy_width, .h = scene_height, .cond = .always });
        if (zgui.begin("Hierarchy", .{})) try self.drawHierarchy();
        zgui.end();

        zgui.setNextWindowPos(.{ .x = hierarchy_width, .y = menu_height, .cond = .always });
        zgui.setNextWindowSize(.{ .w = scene_width, .h = scene_height, .cond = .always });
        if (zgui.begin("Scene View", .{})) self.drawSceneView();
        zgui.end();

        zgui.setNextWindowPos(.{ .x = hierarchy_width + scene_width, .y = menu_height, .cond = .always });
        zgui.setNextWindowSize(.{ .w = inspector_width, .h = scene_height, .cond = .always });
        if (zgui.begin("Inspector", .{})) self.drawInspector();
        zgui.end();

        // Keep the bottom dock edge-to-edge so resizing never leaves unused
        // strips under the side panels.
        zgui.setNextWindowPos(.{ .x = 0, .y = menu_height + scene_height, .cond = .always });
        zgui.setNextWindowSize(.{ .w = width, .h = assets_height, .cond = .always });
        if (zgui.begin("Assets / Output", .{})) self.drawAssets();
        zgui.end();
    }

    fn drawHierarchy(self: *Editor) !void {
        if (zgui.button("+ Sprite", .{})) try self.addObject(.sprite);
        zgui.sameLine(.{});
        if (zgui.button("+ Wall", .{})) try self.addObject(.obstacle);
        zgui.sameLine(.{});
        if (zgui.button("+ Pickup", .{})) try self.addObject(.pickup);

        zgui.separator();
        for (self.document.objects.items) |object| {
            var label_buffer: [64]u8 = undefined;
            const label = try std.fmt.bufPrintZ(&label_buffer, "{s}  #{d}", .{ @tagName(object.kind), object.id });
            if (zgui.selectable(label, .{ .selected = self.selected_id == object.id }))
                self.selected_id = object.id;
        }

        if (self.selected_id) |id| {
            if (zgui.button("Delete selected", .{})) {
                _ = self.document.remove(id);
                self.selected_id = if (self.document.objects.items.len > 0)
                    self.document.objects.items[0].id
                else
                    null;
                self.setStatus("Deleted entity #{d}", .{id});
            }
        }
        zgui.separator();
        if (zgui.button("Save", .{})) self.save();
        zgui.sameLine(.{});
        if (zgui.button("Open", .{})) self.load();
    }

    fn drawInspector(self: *Editor) void {
        const id = self.selected_id orelse {
            zgui.textDisabled("Select an entity in Hierarchy", .{});
            return;
        };
        const object = self.document.get(id) orelse {
            zgui.textDisabled("Selection no longer exists", .{});
            return;
        };

        zgui.text("Entity #{d}", .{object.id});
        zgui.text("Type: {s}", .{@tagName(object.kind)});
        zgui.separatorText("Transform");
        _ = zgui.dragFloat2("Position", .{ .v = &object.position, .speed = 1 });
        _ = zgui.dragFloat2("Size", .{ .v = &object.size, .speed = 1, .min = 1, .max = 2048 });
        object.size[0] = @max(object.size[0], 1);
        object.size[1] = @max(object.size[1], 1);
        zgui.separatorText("Sprite");
        zgui.text("Texture: preview color", .{});
        zgui.text("Layer: 0", .{});
    }

    fn drawSceneView(self: *Editor) void {
        const available = zgui.getContentRegionAvail();
        const canvas_origin = zgui.getCursorScreenPos();
        const canvas_size = .{ @max(available[0], 100), @max(available[1], 100) };
        _ = zgui.invisibleButton("scene-canvas", .{ .w = canvas_size[0], .h = canvas_size[1] });
        const draw_list = zgui.getWindowDrawList();
        const canvas_max = .{ canvas_origin[0] + canvas_size[0], canvas_origin[1] + canvas_size[1] };
        draw_list.addRectFilled(.{
            .pmin = canvas_origin,
            .pmax = canvas_max,
            .col = zgui.colorConvertFloat4ToU32(.{ 0.07, 0.09, 0.12, 1 }),
        });

        const scale = @min(canvas_size[0] / 640, canvas_size[1] / 360);
        const center = .{ canvas_origin[0] + canvas_size[0] * 0.5, canvas_origin[1] + canvas_size[1] * 0.5 };
        const grid_color = zgui.colorConvertFloat4ToU32(.{ 0.17, 0.2, 0.24, 1 });
        var grid: f32 = -320;
        while (grid <= 320) : (grid += 40) {
            const x = center[0] + grid * scale;
            draw_list.addLine(.{ .p1 = .{ x, canvas_origin[1] }, .p2 = .{ x, canvas_max[1] }, .col = grid_color });
        }
        grid = -180;
        while (grid <= 180) : (grid += 40) {
            const y = center[1] - grid * scale;
            draw_list.addLine(.{ .p1 = .{ canvas_origin[0], y }, .p2 = .{ canvas_max[0], y }, .col = grid_color });
        }

        for (self.document.objects.items) |object| {
            const half_width = object.size[0] * scale * 0.5;
            const half_height = object.size[1] * scale * 0.5;
            const object_center = .{ center[0] + object.position[0] * scale, center[1] - object.position[1] * scale };
            const pmin = .{ object_center[0] - half_width, object_center[1] - half_height };
            const pmax = .{ object_center[0] + half_width, object_center[1] + half_height };
            const tint: [4]f32 = switch (object.kind) {
                .sprite => .{ 0.25, 0.72, 0.94, 1 },
                .obstacle => .{ 0.5, 0.56, 0.66, 1 },
                .pickup => .{ 1, 0.68, 0.2, 1 },
            };
            draw_list.addRectFilled(.{ .pmin = pmin, .pmax = pmax, .col = zgui.colorConvertFloat4ToU32(tint), .rounding = 3 });
            if (self.selected_id == object.id) {
                draw_list.addRect(.{
                    .pmin = .{ pmin[0] - 2, pmin[1] - 2 },
                    .pmax = .{ pmax[0] + 2, pmax[1] + 2 },
                    .col = zgui.colorConvertFloat4ToU32(.{ 1, 1, 1, 1 }),
                    .rounding = 3,
                    .thickness = 2,
                });
            }
        }

        if (zgui.isItemHovered(.{}) and zgui.isMouseClicked(.left)) {
            const mouse = zgui.getMousePos();
            self.selected_id = null;
            var index = self.document.objects.items.len;
            while (index > 0) {
                index -= 1;
                const object = self.document.objects.items[index];
                const half_width = object.size[0] * scale * 0.5;
                const half_height = object.size[1] * scale * 0.5;
                const x = center[0] + object.position[0] * scale;
                const y = center[1] - object.position[1] * scale;
                if (mouse[0] >= x - half_width and mouse[0] <= x + half_width and
                    mouse[1] >= y - half_height and mouse[1] <= y + half_height)
                {
                    self.selected_id = object.id;
                    break;
                }
            }
        }
    }

    fn drawAssets(self: *Editor) void {
        zgui.text("Project assets", .{});
        zgui.sameLine(.{});
        zgui.textDisabled("assets/player_sheet.png  |  assets/sprite.png", .{});
        zgui.separator();
        zgui.textUnformatted(self.status[0..self.status_len]);
        zgui.textDisabled("Save/open file: {s}", .{scene_path});
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var window = try GlfwWindow.init(1280, 800, "ez-engine | editor");
    defer window.deinit();
    window.native().setSizeLimits(800, 600, -1, -1);

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

    zgui.init(allocator);
    defer zgui.deinit();
    zgui.backend.init(
        window.native(),
        graphics.device,
        @intFromEnum(graphics.swapchain_descriptor.format),
        @intFromEnum(wgpu.TextureFormat.undef),
    );
    defer zgui.backend.deinit();

    var editor = try Editor.init(allocator, init.io);
    defer editor.deinit();

    while (!window.native().shouldClose()) {
        zglfw.pollEvents();
        const window_size = window.native().getSize();
        const framebuffer = window.native().getFramebufferSize();
        const framebuffer_width: u32 = @intCast(@max(framebuffer[0], 0));
        const framebuffer_height: u32 = @intCast(@max(framebuffer[1], 0));
        if (framebuffer_width == 0 or framebuffer_height == 0) continue;

        zgui.backend.newFrame(framebuffer_width, framebuffer_height);
        // ImGui positions and mouse coordinates use logical window units;
        // the WGPU surface uses physical framebuffer pixels. WSLg often has
        // a 2x scale between these dimensions.
        try editor.frame(@floatFromInt(@max(window_size[0], 0)), @floatFromInt(@max(window_size[1], 0)));

        const back_buffer = graphics.swapchain.getCurrentTextureView();
        defer back_buffer.release();
        const encoder = graphics.device.createCommandEncoder(null);
        defer encoder.release();
        const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
            .view = back_buffer,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0.035, .g = 0.045, .b = 0.06, .a = 1 },
        }};
        const pass = encoder.beginRenderPass(.{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
        });
        zgui.backend.draw(pass);
        pass.end();
        pass.release();

        const command_buffer = encoder.finish(null);
        defer command_buffer.release();
        graphics.queue.submit(&.{command_buffer});
        _ = graphics.present();
    }
}
