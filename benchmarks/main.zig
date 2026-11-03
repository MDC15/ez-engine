const std = @import("std");
const ez = @import("ez_engine");

const Position = struct {
    x: f32,
    y: f32,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    try benchmarkEcs(init.io, allocator);
    try benchmarkRender(init.io, allocator);
    try benchmarkCollision(init.io, allocator);
    try benchmarkAssetDecode(init.io, allocator);
}

fn benchmarkEcs(io: std.Io, allocator: std.mem.Allocator) !void {
    var world = ez.World.init(allocator);
    defer world.deinit();
    for (0..10_000) |index| {
        const entity = try world.create();
        try world.add(entity, Position{ .x = @floatFromInt(index), .y = 0 });
    }

    const start = now(io);
    var checksum: f32 = 0;
    for (0..100) |_| {
        var query = world.query(.{Position});
        while (query.next()) |item| checksum += item.Position.x;
    }
    report("ecs_query", now(io) - start, 1_000_000, checksum);
}

fn benchmarkRender(io: std.Io, allocator: std.mem.Allocator) !void {
    var world = ez.World.init(allocator);
    defer world.deinit();
    for (0..2_000) |index| {
        const entity = try world.create();
        try world.add(entity, ez.RenderComponents.Transform{
            .position = .{ .x = @floatFromInt(index % 100), .y = @floatFromInt(index / 100) },
        });
        try world.add(entity, ez.RenderComponents.SpriteRenderer{
            .texture = .{ .index = @intCast(index % 8), .generation = 1 },
            .size = .{ .x = 1, .y = 1 },
            .z_index = @intCast(index % 3),
        });
    }
    var render_world = ez.RenderWorld.init(allocator);
    defer render_world.deinit();
    const start = now(io);
    for (0..100) |_| {
        try render_world.extract(&world);
        try render_world.cullSprites2D(.{ .viewport_size = .{ .x = 64, .y = 64 } });
        render_world.sortForBatching();
    }
    report("render_extract_cull_batch", now(io) - start, 200_000, @floatFromInt(render_world.items.items.len));
}

fn benchmarkCollision(io: std.Io, allocator: std.mem.Allocator) !void {
    var world = ez.World.init(allocator);
    defer world.deinit();
    for (0..512) |index| {
        const entity = try world.create();
        try world.add(entity, ez.RenderComponents.Transform{
            .position = .{ .x = @floatFromInt(index % 32 * 4), .y = @floatFromInt(index / 32 * 4) },
        });
        try world.add(entity, ez.Collision2D.Collider2D{
            .size = .{ .x = 1, .y = 1 },
        });
    }
    var system = ez.Collision2D.System.init(allocator);
    defer system.deinit();
    const start = now(io);
    for (0..100) |_| try system.update(&world);
    report("collision_pairwise", now(io) - start, 100, @floatFromInt(system.active_contacts.items.len));
}

fn benchmarkAssetDecode(io: std.Io, allocator: std.mem.Allocator) !void {
    const width: u32 = 64;
    const height: u32 = 64;
    const pixel_bytes = width * height * 4;
    const encoded = try allocator.alloc(u8, 20 + pixel_bytes);
    defer allocator.free(encoded);
    @memset(encoded, 127);
    @memcpy(encoded[0..4], "ZTEX");
    std.mem.writeInt(u32, encoded[4..8], 1, .little);
    std.mem.writeInt(u32, encoded[8..12], width, .little);
    std.mem.writeInt(u32, encoded[12..16], height, .little);
    encoded[16] = 0;
    @memset(encoded[17..20], 0);

    const start = now(io);
    for (0..1_000) |_| {
        var texture = try ez.AssetLoading.Texture.loadAny(allocator, encoded, pixel_bytes);
        texture.deinit(allocator);
    }
    report("asset_ztex_decode_64x64", now(io) - start, 1_000, @floatFromInt(pixel_bytes));
}

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn report(name: []const u8, elapsed_ns: i96, iterations: usize, checksum: f64) void {
    const elapsed: f64 = @floatFromInt(elapsed_ns);
    std.debug.print(
        "{s}: iterations={d}, total_ms={d:.3}, ns_per_iteration={d:.1}, checksum={d:.3}\n",
        .{ name, iterations, elapsed / std.time.ns_per_ms, elapsed / @as(f64, @floatFromInt(iterations)), checksum },
    );
}
