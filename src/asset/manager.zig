const std = @import("std");
const Handles = @import("../core/handle.zig");
const TextureLoader = @import("texture_loader.zig");
const AtlasModule = @import("../gfx/atlas.zig");

pub const AssetHandle = Handles.Handle(enum { asset });

/// Typed, generational asset store. Slots own values through the caller's
/// value lifecycle; use releaseFn when the value owns allocations.
pub fn Store(comptime T: type, comptime HandleType: type, comptime releaseFn: ?*const fn (std.mem.Allocator, *T) void) type {
    return struct {
        const Self = @This();
        const Slot = struct {
            generation: u32 = 1,
            value: ?T = null,
        };

        allocator: std.mem.Allocator,
        slots: std.ArrayListUnmanaged(Slot) = .empty,
        free_slots: std.ArrayListUnmanaged(u32) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            for (self.slots.items) |*slot| self.releaseValue(slot);
            self.slots.deinit(self.allocator);
            self.free_slots.deinit(self.allocator);
        }

        pub fn insert(self: *Self, value: T) !HandleType {
            if (self.free_slots.pop()) |index| {
                const slot = &self.slots.items[index];
                slot.value = value;
                return .{ .index = index, .generation = slot.generation };
            }
            if (self.slots.items.len > std.math.maxInt(u32)) return error.OutOfMemory;
            const index: u32 = @intCast(self.slots.items.len);
            try self.slots.append(self.allocator, .{ .value = value });
            return .{ .index = index, .generation = 1 };
        }

        pub fn get(self: *Self, handle: HandleType) ?*T {
            if (handle.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[handle.index];
            if (slot.generation != handle.generation) return null;
            return if (slot.value) |*value| value else null;
        }

        pub fn remove(self: *Self, handle: HandleType) !void {
            if (self.get(handle) == null) return error.InvalidHandle;
            try self.free_slots.ensureUnusedCapacity(self.allocator, 1);
            const slot = &self.slots.items[handle.index];
            self.releaseValue(slot);
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            self.free_slots.appendAssumeCapacity(handle.index);
        }

        fn releaseValue(self: *Self, slot: *Slot) void {
            if (slot.value) |*value| {
                if (releaseFn) |release| release(self.allocator, value);
                slot.value = null;
            }
        }
    };
}

pub const Asset = struct {
    path: []u8,
    bytes: []u8,
};

fn releaseAsset(allocator: std.mem.Allocator, asset: *Asset) void {
    allocator.free(asset.bytes);
    allocator.free(asset.path);
}

fn releaseTextureData(allocator: std.mem.Allocator, texture: *TextureLoader.TextureData) void {
    texture.deinit(allocator);
}

pub const AtlasEntry = struct {
    texture: Handles.TextureHandle,
    atlas: AtlasModule.OwnedAtlas,
};

fn releaseAtlasData(allocator: std.mem.Allocator, entry: *AtlasEntry) void {
    entry.atlas.deinit(allocator);
}

/// File-backed binary asset cache. Repeated paths resolve to the same live
/// handle; callers retain handles and explicitly release them when finished.
pub const Manager = struct {
    allocator: std.mem.Allocator,
    assets: Store(Asset, AssetHandle, releaseAsset),
    paths: std.StringHashMapUnmanaged(AssetHandle) = .empty,
    textures: Store(TextureLoader.TextureData, Handles.TextureHandle, releaseTextureData),
    texture_paths: std.StringHashMapUnmanaged(Handles.TextureHandle) = .empty,
    atlases: Store(AtlasEntry, Handles.AtlasHandle, releaseAtlasData),
    atlas_paths: std.StringHashMapUnmanaged(Handles.AtlasHandle) = .empty,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{
            .allocator = allocator,
            .assets = Store(Asset, AssetHandle, releaseAsset).init(allocator),
            .textures = Store(TextureLoader.TextureData, Handles.TextureHandle, releaseTextureData).init(allocator),
            .atlases = Store(AtlasEntry, Handles.AtlasHandle, releaseAtlasData).init(allocator),
        };
    }

    pub fn deinit(self: *Manager) void {
        var atlas_keys = self.atlas_paths.keyIterator();
        while (atlas_keys.next()) |key| self.allocator.free(key.*);
        self.atlas_paths.deinit(self.allocator);
        self.atlases.deinit();
        var texture_keys = self.texture_paths.keyIterator();
        while (texture_keys.next()) |key| self.allocator.free(key.*);
        self.texture_paths.deinit(self.allocator);
        self.textures.deinit();
        self.paths.deinit(self.allocator);
        self.assets.deinit();
    }

    /// Loads and decodes a ZTEX or PNG file once. The returned handle owns its pixel
    /// bytes until `releaseTexture` or manager deinitialization.
    pub fn loadTextureFile(self: *Manager, io: std.Io, path: []const u8, max_bytes: usize) !Handles.TextureHandle {
        if (self.texture_paths.get(path)) |handle| {
            if (self.textures.get(handle) != null) return handle;
            return error.AssetCacheCorrupt;
        }

        const asset_handle = try self.loadFile(io, path, max_bytes);
        const asset = self.get(asset_handle) orelse return error.AssetCacheCorrupt;
        try self.texture_paths.ensureUnusedCapacity(self.allocator, 1);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const texture_data = try TextureLoader.loadAny(self.allocator, asset.bytes, max_bytes);
        errdefer self.allocator.free(texture_data.pixels);
        const handle = try self.textures.insert(texture_data);
        self.texture_paths.putAssumeCapacityNoClobber(owned_path, handle);
        return handle;
    }

    pub fn getTexture(self: *Manager, handle: Handles.TextureHandle) ?*TextureLoader.TextureData {
        return self.textures.get(handle);
    }

    pub fn releaseTexture(self: *Manager, handle: Handles.TextureHandle) !void {
        try self.textures.remove(handle);
        var found_path: ?[]const u8 = null;
        var iter = self.texture_paths.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.index == handle.index and entry.value_ptr.generation == handle.generation) {
                found_path = entry.key_ptr.*;
                break;
            }
        }
        if (found_path) |path_key| {
            _ = self.texture_paths.remove(path_key);
            self.allocator.free(@constCast(path_key));
        }
    }

    /// Loads a packed atlas: the texture through the shared texture cache plus
    /// the JSON sidecar parsed against its dimensions. Cached on `json_path`;
    /// releasing the atlas never releases the texture.
    pub fn loadAtlasFile(self: *Manager, io: std.Io, json_path: []const u8, texture_path: []const u8, max_bytes: usize) !Handles.AtlasHandle {
        if (self.atlas_paths.get(json_path)) |handle| {
            if (self.atlases.get(handle) != null) return handle;
            return error.AssetCacheCorrupt;
        }

        const texture_handle = try self.loadTextureFile(io, texture_path, max_bytes);
        const texture_data = self.getTexture(texture_handle) orelse return error.AssetCacheCorrupt;
        const asset_handle = try self.loadFile(io, json_path, max_bytes);
        const asset = self.get(asset_handle) orelse return error.AssetCacheCorrupt;
        try self.atlas_paths.ensureUnusedCapacity(self.allocator, 1);
        const owned_path = try self.allocator.dupe(u8, json_path);
        errdefer self.allocator.free(owned_path);
        var owned = try AtlasModule.load(self.allocator, asset.bytes, texture_data.width, texture_data.height);
        errdefer owned.deinit(self.allocator);
        const handle = try self.atlases.insert(.{ .texture = texture_handle, .atlas = owned });
        self.atlas_paths.putAssumeCapacityNoClobber(owned_path, handle);
        return handle;
    }

    pub fn getAtlas(self: *Manager, handle: Handles.AtlasHandle) ?*AtlasEntry {
        return self.atlases.get(handle);
    }

    pub fn releaseAtlas(self: *Manager, handle: Handles.AtlasHandle) !void {
        try self.atlases.remove(handle);
        var found_path: ?[]const u8 = null;
        var iter = self.atlas_paths.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.index == handle.index and entry.value_ptr.generation == handle.generation) {
                found_path = entry.key_ptr.*;
                break;
            }
        }
        if (found_path) |path_key| {
            _ = self.atlas_paths.remove(path_key);
            self.allocator.free(@constCast(path_key));
        }
    }

    pub fn loadFile(self: *Manager, io: std.Io, path: []const u8, max_bytes: usize) !AssetHandle {
        if (self.paths.get(path)) |handle| {
            if (self.assets.get(handle) != null) return handle;
            return error.AssetCacheCorrupt;
        }

        const contents = try std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            self.allocator,
            .limited(max_bytes),
        );
        errdefer self.allocator.free(contents);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.paths.ensureUnusedCapacity(self.allocator, 1);
        const handle = try self.assets.insert(.{ .path = owned_path, .bytes = contents });
        self.paths.putAssumeCapacityNoClobber(owned_path, handle);
        return handle;
    }

    pub fn get(self: *Manager, handle: AssetHandle) ?*Asset {
        return self.assets.get(handle);
    }

    pub fn release(self: *Manager, handle: AssetHandle) !void {
        const asset = self.assets.get(handle) orelse return error.InvalidHandle;
        const key = try self.allocator.dupe(u8, asset.path);
        defer self.allocator.free(key);
        try self.assets.remove(handle);
        _ = self.paths.remove(key);
    }
};

test "asset handles become stale after release and slot reuse" {
    var meshes = Store(u32, Handles.TextureHandle, null).init(std.testing.allocator);
    defer meshes.deinit();
    const first = try meshes.insert(10);
    try std.testing.expectEqual(@as(u32, 10), meshes.get(first).?.*);
    try meshes.remove(first);
    try std.testing.expect(meshes.get(first) == null);
    const second = try meshes.insert(20);
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(first.generation != second.generation);
}

test "manager caches atlas by json path and keeps texture independent" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    const h1 = try manager.loadAtlasFile(io, "assets/atlas_test.json", "assets/atlas_test.ztex", 1024 * 1024);
    const h2 = try manager.loadAtlasFile(io, "assets/atlas_test.json", "assets/atlas_test.ztex", 1024 * 1024);
    try std.testing.expectEqual(h1.index, h2.index);
    try std.testing.expect(manager.getAtlas(h1) != null);
    try manager.releaseAtlas(h1);
    try std.testing.expect(manager.getAtlas(h1) == null);
    const tex = try manager.loadTextureFile(io, "assets/atlas_test.ztex", 1024 * 1024);
    try std.testing.expect(manager.getTexture(tex) != null);
}
