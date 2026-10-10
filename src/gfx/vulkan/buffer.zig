const std = @import("std");
const Instance = @import("instance.zig").Instance;
const Device = @import("device.zig").Device;
const PhysicalDevice = @import("physical_device.zig").PhysicalDevice;
const MemoryType = @import("allocator.zig").MemoryType;
const Handle = @import("instance.zig").Handle;

const CreateInfo = extern struct {
    s_type: u32 = 12,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    size: u64,
    usage: u32,
    sharing_mode: u32 = 0,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
};
const Requirements = extern struct { size: u64, alignment: u64, memory_type_bits: u32 };
const AllocateInfo = extern struct {
    s_type: u32 = 5,
    next: ?*const anyopaque = null,
    allocation_size: u64,
    memory_type_index: u32,
};
const MemoryProperties = extern struct {
    memory_type_count: u32,
    memory_types: [32]MemoryType,
    memory_heap_count: u32,
    memory_heaps: [16]extern struct { size: u64, flags: u32, padding: u32 },
};

const CreateBufferFn = *const fn (Handle, *const CreateInfo, ?*const anyopaque, *Handle) callconv(.c) i32;
const DestroyBufferFn = *const fn (Handle, Handle, ?*const anyopaque) callconv(.c) void;
const GetRequirementsFn = *const fn (Handle, Handle, *Requirements) callconv(.c) void;
const AllocateMemoryFn = *const fn (Handle, *const AllocateInfo, ?*const anyopaque, *u64) callconv(.c) i32;
const FreeMemoryFn = *const fn (Handle, u64, ?*const anyopaque) callconv(.c) void;
const BindMemoryFn = *const fn (Handle, Handle, u64, u64) callconv(.c) i32;
const GetMemoryPropertiesFn = *const fn (Handle, *MemoryProperties) callconv(.c) void;

/// RAII-style VkBuffer and dedicated VkDeviceMemory allocation.
pub const Buffer = struct {
    handle: Handle,
    memory: u64,
    size: u64,
    device: Handle,
    host_visible: bool,
    host_coherent: bool,
    destroy_buffer: DestroyBufferFn,
    free_memory: FreeMemoryFn,

    pub fn init(instance: *const Instance, device: *const Device, physical: PhysicalDevice, size: u64, usage: u32, required_memory_flags: u32) !Buffer {
        if (size == 0) return error.InvalidBufferSize;
        const create_buffer = device.proc(CreateBufferFn, "vkCreateBuffer") orelse return error.VulkanLoaderMissingEntryPoint;
        const destroy_buffer = device.proc(DestroyBufferFn, "vkDestroyBuffer") orelse return error.VulkanLoaderMissingEntryPoint;
        const get_requirements = device.proc(GetRequirementsFn, "vkGetBufferMemoryRequirements") orelse return error.VulkanLoaderMissingEntryPoint;
        const allocate_memory = device.proc(AllocateMemoryFn, "vkAllocateMemory") orelse return error.VulkanLoaderMissingEntryPoint;
        const free_memory = device.proc(FreeMemoryFn, "vkFreeMemory") orelse return error.VulkanLoaderMissingEntryPoint;
        const bind_memory = device.proc(BindMemoryFn, "vkBindBufferMemory") orelse return error.VulkanLoaderMissingEntryPoint;
        const get_memory_properties = instance.proc(GetMemoryPropertiesFn, "vkGetPhysicalDeviceMemoryProperties") orelse return error.VulkanLoaderMissingEntryPoint;

        const create_info = CreateInfo{ .size = size, .usage = usage };
        var buffer: Handle = null;
        if (create_buffer(device.handle, &create_info, null, &buffer) != 0 or buffer == null)
            return error.VulkanBufferCreationFailed;
        errdefer destroy_buffer(device.handle, buffer, null);

        var requirements: Requirements = undefined;
        get_requirements(device.handle, buffer, &requirements);
        var native_properties: MemoryProperties = undefined;
        get_memory_properties(physical.handle, &native_properties);
        const memory_index = try @import("allocator.zig").findMemoryType(.{
            .memory_type_count = native_properties.memory_type_count,
            .memory_types = native_properties.memory_types[0..],
        }, requirements.memory_type_bits, required_memory_flags);

        const allocation_info = AllocateInfo{
            .allocation_size = requirements.size,
            .memory_type_index = memory_index,
        };
        var memory: u64 = 0;
        if (allocate_memory(device.handle, &allocation_info, null, &memory) != 0)
            return error.VulkanMemoryAllocationFailed;
        errdefer free_memory(device.handle, memory, null);
        if (bind_memory(device.handle, buffer, memory, 0) != 0) return error.VulkanMemoryBindingFailed;
        return .{
            .handle = buffer,
            .memory = memory,
            .size = size,
            .device = device.handle,
            .host_visible = required_memory_flags & 0x2 != 0,
            .host_coherent = required_memory_flags & 0x4 != 0,
            .destroy_buffer = destroy_buffer,
            .free_memory = free_memory,
        };
    }

    pub fn mapWrite(self: *const Buffer, device: *const Device) ![]u8 {
        if (!self.host_visible) return error.MemoryNotHostVisible;
        if (!self.host_coherent) return error.MemoryNotHostCoherent;
        const MapMemoryFn = *const fn (Handle, u64, u64, u64, u32, *?*anyopaque) callconv(.c) i32;
        const map_fn = device.proc(MapMemoryFn, "vkMapMemory") orelse return error.VulkanLoaderMissingEntryPoint;
        var pointer: ?*anyopaque = null;
        if (map_fn(self.device, self.memory, 0, self.size, 0, &pointer) != 0 or pointer == null)
            return error.VulkanMemoryMapFailed;
        const bytes: [*]u8 = @ptrCast(pointer.?);
        return bytes[0..@intCast(self.size)];
    }

    pub fn unmap(self: *const Buffer, device: *const Device) !void {
        const UnmapMemoryFn = *const fn (Handle, u64) callconv(.c) void;
        const unmap_fn = device.proc(UnmapMemoryFn, "vkUnmapMemory") orelse return error.VulkanLoaderMissingEntryPoint;
        unmap_fn(self.device, self.memory);
    }

    pub fn deinit(self: *Buffer) void {
        self.destroy_buffer(self.device, self.handle, null);
        self.free_memory(self.device, self.memory, null);
        self.handle = null;
        self.memory = 0;
    }
};
