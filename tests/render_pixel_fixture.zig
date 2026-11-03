const std = @import("std");
const ez_engine = @import("ez_engine");

const sprite_texture = [_]u8{
    255, 0, 0,   255, 0,   255, 0,   255,
    0,   0, 255, 255, 255, 255, 255, 255,
};
const solid_red = [_]u8{ 255, 0, 0, 255 };
const solid_green = [_]u8{ 0, 255, 0, 255 };
const half_red = [_]u8{ 255, 0, 0, 128 };

fn insertTexture(
    allocator: std.mem.Allocator,
    assets: *ez_engine.Assets,
    width: u32,
    height: u32,
    pixels: []const u8,
) !ez_engine.TextureHandle {
    const owned_pixels = try allocator.dupe(u8, pixels);
    errdefer allocator.free(owned_pixels);
    return assets.textures.insert(.{
        .width = width,
        .height = height,
        .format = .rgba8,
        .pixels = owned_pixels,
    });
}

fn expectPixel(actual: [4]u8, expected: [4]u8, tolerance: u8) !void {
    for (actual, expected) |got, want| {
        if (@abs(@as(i16, got) - @as(i16, want)) > tolerance) {
            std.debug.print("pixel mismatch: actual={any}, expected={any}\n", .{ actual, expected });
            return error.PixelMismatch;
        }
    }
}

fn render(app: anytype, world: *const ez_engine.RenderWorld, width: u32, height: u32) !void {
    const backend = app.backend.backend();
    try backend.resize(.{ .width = width, .height = height });
    try backend.render(world);
}

pub fn run(comptime AppType: type) !void {
    var app: AppType = undefined;
    try app.init(std.testing.allocator, "ez-engine-render-regression", 96, 64, false);
    defer app.deinit();

    const uv_texture = try insertTexture(std.testing.allocator, &app.game.assets, 2, 2, &sprite_texture);
    const red_texture = try insertTexture(std.testing.allocator, &app.game.assets, 1, 1, &solid_red);
    const green_texture = try insertTexture(std.testing.allocator, &app.game.assets, 1, 1, &solid_green);
    const alpha_texture = try insertTexture(std.testing.allocator, &app.game.assets, 1, 1, &half_red);
    var world = ez_engine.RenderWorld.init(std.testing.allocator);
    defer world.deinit();
    world.camera_2d = .{ .viewport_size = .{ .x = 32, .y = 32 } };

    try world.add(.{ .texture = uv_texture, .sprite_size = .{ .x = 16, .y = 16 } });
    world.sortForBatching();
    try render(&app, &world, 64, 64);
    const top_left = try app.backend.readScenePixel(27, 27);
    const top_right = try app.backend.readScenePixel(36, 27);
    const bottom_left = try app.backend.readScenePixel(27, 36);
    const bottom_right = try app.backend.readScenePixel(36, 36);
    try expectPixel(top_left, .{ 255, 0, 0, 255 }, 8);
    try expectPixel(top_right, .{ 0, 255, 0, 255 }, 8);
    try expectPixel(bottom_left, .{ 0, 0, 255, 255 }, 8);
    try expectPixel(bottom_right, .{ 255, 255, 255, 255 }, 8);

    world.clear();
    try world.add(.{
        .texture = red_texture,
        .sprite_size = .{ .x = 16, .y = 16 },
        .z_index = 0,
    });
    try world.add(.{
        .texture = green_texture,
        .sprite_size = .{ .x = 8, .y = 8 },
        .z_index = 1,
    });
    world.sortForBatching();
    try render(&app, &world, 64, 64);
    try expectPixel(try app.backend.readScenePixel(32, 32), .{ 0, 255, 0, 255 }, 8);
    try expectPixel(try app.backend.readScenePixel(20, 20), .{ 255, 0, 0, 255 }, 8);

    world.clear();
    try world.add(.{
        .texture = alpha_texture,
        .sprite_size = .{ .x = 16, .y = 16 },
    });
    try render(&app, &world, 64, 64);
    try expectPixel(try app.backend.readScenePixel(32, 32), .{ 132, 7, 11, 255 }, 12);

    world.clear();
    try world.add(.{
        .texture = red_texture,
        .position = .{ .x = 8 },
        .sprite_size = .{ .x = 8, .y = 8 },
    });
    world.camera_2d.center = .{ .x = 8 };
    try render(&app, &world, 64, 64);
    try expectPixel(try app.backend.readScenePixel(32, 32), .{ 255, 0, 0, 255 }, 8);
    world.camera_2d.center = .zero;
    try render(&app, &world, 64, 64);
    try expectPixel(try app.backend.readScenePixel(32, 32), .{ 9, 14, 23, 255 }, 3);
    try expectPixel(try app.backend.readScenePixel(48, 32), .{ 255, 0, 0, 255 }, 8);

    world.clear();
    world.camera_2d = .{ .viewport_size = .{ .x = 32, .y = 16 } };
    try world.add(.{ .texture = red_texture, .sprite_size = .{ .x = 8, .y = 8 } });
    try render(&app, &world, 96, 48);
    try expectPixel(try app.backend.readScenePixel(48, 24), .{ 255, 0, 0, 255 }, 8);
}
