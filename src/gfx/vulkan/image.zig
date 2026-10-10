const Instance = @import("instance.zig").Instance;
const Device = @import("device.zig").Device;
const PhysicalDevice = @import("physical_device.zig").PhysicalDevice;
const MemoryType = @import("allocator.zig").MemoryType;
const Handle = @import("instance.zig").Handle;

const Extent3D = extern struct { width: u32, height: u32, depth: u32 };
const CreateInfo = extern struct {
    s_type: u32 = 14,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    image_type: u32 = 1,
    format: u32,
    extent: Extent3D,
    mip_levels: u32 = 1,
    array_layers: u32 = 1,
    samples: u32 = 1,
    tiling: u32 = 0,
    usage: u32,
    sharing_mode: u32 = 0,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
    initial_layout: u32 = 0,
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

const CreateImageFn = *const fn (Handle, *const CreateInfo, ?*const anyopaque, *Handle) callconv(.c) i32;
const DestroyImageFn = *const fn (Handle, Handle, ?*const anyopaque) callconv(.c) void;
const GetRequirementsFn = *const fn (Handle, Handle, *Requirements) callconv(.c) void;
const AllocateMemoryFn = *const fn (Handle, *const AllocateInfo, ?*const anyopaque, *u64) callconv(.c) i32;
const FreeMemoryFn = *const fn (Handle, u64, ?*const anyopaque) callconv(.c) void;
const BindMemoryFn = *const fn (Handle, Handle, u64, u64) callconv(.c) i32;
const GetMemoryPropertiesFn = *const fn (Handle, *MemoryProperties) callconv(.c) void;

pub const Image = struct {
    handle: Handle,
    memory: u64,
    device: Handle,
    destroy_image: DestroyImageFn,
    free_memory: FreeMemoryFn,

    pub fn init(
        instance: *const Instance,
        device: *const Device,
        physical: PhysicalDevice,
        width: u32,
        height: u32,
        format: u32,
        usage: u32,
        required_memory_flags: u32,
    ) !Image {
        if (width == 0 or height == 0) return error.InvalidImageExtent;
        const create_image = device.proc(CreateImageFn, "vkCreateImage") orelse return error.VulkanLoaderMissingEntryPoint;
        const destroy_image = device.proc(DestroyImageFn, "vkDestroyImage") orelse return error.VulkanLoaderMissingEntryPoint;
        const get_requirements = device.proc(GetRequirementsFn, "vkGetImageMemoryRequirements") orelse return error.VulkanLoaderMissingEntryPoint;
        const allocate_memory = device.proc(AllocateMemoryFn, "vkAllocateMemory") orelse return error.VulkanLoaderMissingEntryPoint;
        const free_memory = device.proc(FreeMemoryFn, "vkFreeMemory") orelse return error.VulkanLoaderMissingEntryPoint;
        const bind_memory = device.proc(BindMemoryFn, "vkBindImageMemory") orelse return error.VulkanLoaderMissingEntryPoint;
        const get_memory_properties = instance.proc(GetMemoryPropertiesFn, "vkGetPhysicalDeviceMemoryProperties") orelse return error.VulkanLoaderMissingEntryPoint;
        const info = CreateInfo{
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .usage = usage,
        };

        var handle: Handle = null;
        if (create_image(device.handle, &info, null, &handle) != 0 or handle == null)
            return error.VulkanImageCreationFailed;
        errdefer destroy_image(device.handle, handle, null);
        var requirements: Requirements = undefined;
        get_requirements(device.handle, handle, &requirements);
        var properties: MemoryProperties = undefined;
        get_memory_properties(physical.handle, &properties);
        const type_index = try @import("allocator.zig").findMemoryType(.{
            .memory_type_count = properties.memory_type_count,
            .memory_types = &properties.memory_types,
        }, requirements.memory_type_bits, required_memory_flags);
        const allocation = AllocateInfo{
            .allocation_size = requirements.size,
            .memory_type_index = type_index,
        };
        var memory: u64 = 0;
        if (allocate_memory(device.handle, &allocation, null, &memory) != 0)
            return error.VulkanMemoryAllocationFailed;
        errdefer free_memory(device.handle, memory, null);
        if (bind_memory(device.handle, handle, memory, 0) != 0) return error.VulkanMemoryBindingFailed;
        return .{ .handle = handle, .memory = memory, .device = device.handle, .destroy_image = destroy_image, .free_memory = free_memory };
    }

    pub fn deinit(self: *Image) void {
        self.destroy_image(self.device, self.handle, null);
        self.free_memory(self.device, self.memory, null);
        self.handle = null;
        self.memory = 0;
    }
};
