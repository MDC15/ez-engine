const Device = @import("device.zig").Device;
const Handle = @import("instance.zig").Handle;
const std = @import("std");

pub const Binding = struct {
    binding: u32,
    descriptor_type: u32,
    descriptor_count: u32 = 1,
    stage_flags: u32,
};

const NativeBinding = extern struct {
    binding: u32,
    descriptor_type: u32,
    descriptor_count: u32,
    stage_flags: u32,
    immutable_samplers: ?[*]const Handle = null,
};
const LayoutCreateInfo = extern struct {
    s_type: u32 = 32,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    binding_count: u32,
    bindings: ?[*]const NativeBinding,
};
const CreateLayoutFn = *const fn (Handle, *const LayoutCreateInfo, ?*const anyopaque, *Handle) callconv(.c) i32;
const DestroyLayoutFn = *const fn (Handle, Handle, ?*const anyopaque) callconv(.c) void;

pub const SetLayout = struct {
    handle: Handle,
    device: Handle,
    destroy_fn: DestroyLayoutFn,

    pub fn init(device: *const Device, allocator: std.mem.Allocator, bindings: []const Binding) !SetLayout {
        const native = try allocator.alloc(NativeBinding, bindings.len);
        defer allocator.free(native);
        for (bindings, 0..) |binding, index| {
            if (binding.descriptor_count == 0 or binding.stage_flags == 0) return error.InvalidDescriptorBinding;
            native[index] = .{
                .binding = binding.binding,
                .descriptor_type = binding.descriptor_type,
                .descriptor_count = binding.descriptor_count,
                .stage_flags = binding.stage_flags,
            };
        }
        const create_fn = device.proc(CreateLayoutFn, "vkCreateDescriptorSetLayout") orelse return error.VulkanLoaderMissingEntryPoint;
        const destroy_fn = device.proc(DestroyLayoutFn, "vkDestroyDescriptorSetLayout") orelse return error.VulkanLoaderMissingEntryPoint;
        const info = LayoutCreateInfo{
            .binding_count = @intCast(native.len),
            .bindings = if (native.len == 0) null else native.ptr,
        };
        var handle: Handle = null;
        if (create_fn(device.handle, &info, null, &handle) != 0 or handle == null)
            return error.VulkanDescriptorLayoutCreationFailed;
        return .{ .handle = handle, .device = device.handle, .destroy_fn = destroy_fn };
    }

    pub fn deinit(self: *SetLayout) void {
        self.destroy_fn(self.device, self.handle, null);
        self.handle = null;
    }
};

pub const PoolSize = struct {
    descriptor_type: u32,
    descriptor_count: u32,
};

const NativePoolSize = extern struct { descriptor_type: u32, descriptor_count: u32 };
const PoolCreateInfo = extern struct {
    s_type: u32 = 33,
    next: ?*const anyopaque = null,
    flags: u32 = 1,
    max_sets: u32,
    pool_size_count: u32,
    pool_sizes: ?[*]const NativePoolSize,
};
const AllocateInfo = extern struct {
    s_type: u32 = 34,
    next: ?*const anyopaque = null,
    pool: Handle,
    set_count: u32,
    layouts: [*]const Handle,
};
const CreatePoolFn = *const fn (Handle, *const PoolCreateInfo, ?*const anyopaque, *Handle) callconv(.c) i32;
const DestroyPoolFn = *const fn (Handle, Handle, ?*const anyopaque) callconv(.c) void;
const AllocateSetsFn = *const fn (Handle, *const AllocateInfo, [*]Handle) callconv(.c) i32;
const FreeSetsFn = *const fn (Handle, Handle, u32, [*]const Handle) callconv(.c) i32;

pub const Pool = struct {
    allocator: std.mem.Allocator,
    handle: Handle,
    device: Handle,
    destroy_fn: DestroyPoolFn,
    allocate_fn: AllocateSetsFn,
    free_fn: FreeSetsFn,

    pub fn init(device: *const Device, allocator: std.mem.Allocator, max_sets: u32, sizes: []const PoolSize) !Pool {
        if (max_sets == 0 or sizes.len == 0) return error.InvalidDescriptorPool;
        const native_sizes = try allocator.alloc(NativePoolSize, sizes.len);
        defer allocator.free(native_sizes);
        for (sizes, 0..) |size, index| {
            if (size.descriptor_count == 0) return error.InvalidDescriptorPool;
            native_sizes[index] = .{ .descriptor_type = size.descriptor_type, .descriptor_count = size.descriptor_count };
        }
        const create_fn = device.proc(CreatePoolFn, "vkCreateDescriptorPool") orelse return error.VulkanLoaderMissingEntryPoint;
        const destroy_fn = device.proc(DestroyPoolFn, "vkDestroyDescriptorPool") orelse return error.VulkanLoaderMissingEntryPoint;
        const info = PoolCreateInfo{
            .max_sets = max_sets,
            .pool_size_count = @intCast(native_sizes.len),
            .pool_sizes = native_sizes.ptr,
        };
        var handle: Handle = null;
        if (create_fn(device.handle, &info, null, &handle) != 0 or handle == null)
            return error.VulkanDescriptorPoolCreationFailed;
        errdefer destroy_fn(device.handle, handle, null);
        const allocate_fn = device.proc(AllocateSetsFn, "vkAllocateDescriptorSets") orelse return error.VulkanLoaderMissingEntryPoint;
        const free_fn = device.proc(FreeSetsFn, "vkFreeDescriptorSets") orelse return error.VulkanLoaderMissingEntryPoint;
        return .{
            .allocator = allocator,
            .handle = handle,
            .device = device.handle,
            .destroy_fn = destroy_fn,
            .allocate_fn = allocate_fn,
            .free_fn = free_fn,
        };
    }

    pub fn allocate(self: *const Pool, layouts: []const Handle) ![]Handle {
        if (layouts.len == 0) return error.InvalidDescriptorSetCount;
        const sets = try self.allocator.alloc(Handle, layouts.len);
        errdefer self.allocator.free(sets);
        const info = AllocateInfo{
            .pool = self.handle,
            .set_count = @intCast(layouts.len),
            .layouts = layouts.ptr,
        };
        if (self.allocate_fn(self.device, &info, sets.ptr) != 0)
            return error.VulkanDescriptorAllocationFailed;
        return sets;
    }

    pub fn free(self: *const Pool, sets: []Handle) !void {
        if (sets.len == 0) return;
        if (self.free_fn(self.device, self.handle, @intCast(sets.len), sets.ptr) != 0)
            return error.VulkanDescriptorFreeFailed;
        self.allocator.free(sets);
    }

    pub fn deinit(self: *Pool) void {
        self.destroy_fn(self.device, self.handle, null);
        self.handle = null;
    }
};
