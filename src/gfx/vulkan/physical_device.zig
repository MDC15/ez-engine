const std = @import("std");
const Instance = @import("instance.zig").Instance;
const castProc = @import("instance.zig").castProc;
const Handle = @import("instance.zig").Handle;

const EnumerateFn = *const fn (Handle, *u32, ?[*]Handle) callconv(.c) i32;
const GetPropertiesFn = *const fn (Handle, *anyopaque) callconv(.c) void;
const Extent3D = extern struct { width: u32, height: u32, depth: u32 };
const QueueFamilyProperties = extern struct {
    queue_flags: u32,
    queue_count: u32,
    timestamp_valid_bits: u32,
    min_image_transfer_granularity: Extent3D,
};
const GetQueueFamiliesFn = *const fn (Handle, *u32, ?[*]QueueFamilyProperties) callconv(.c) void;

const PropertiesPrefix = extern struct {
    api_version: u32,
    driver_version: u32,
    vendor_id: u32,
    device_id: u32,
    device_type: u32,
    name: [256]u8,
};

pub const PhysicalDevice = struct {
    handle: Handle,
    api_version: u32,
    driver_version: u32,
    vendor_id: u32,
    device_id: u32,
    device_type: DeviceType,
    name: [256]u8,
    graphics_queue_family: ?u32,
};

pub const QueueFamily = QueueFamilyProperties;

pub fn queueFamilies(allocator: std.mem.Allocator, instance: *const Instance, physical: Handle) ![]QueueFamily {
    const get_queue_families = instance.proc(GetQueueFamiliesFn, "vkGetPhysicalDeviceQueueFamilyProperties") orelse
        return error.VulkanLoaderMissingEntryPoint;
    var count: u32 = 0;
    get_queue_families(physical, &count, null);
    const result = try allocator.alloc(QueueFamily, count);
    errdefer allocator.free(result);
    if (count > 0) get_queue_families(physical, &count, result.ptr);
    return result[0..count];
}

pub const DeviceType = enum(u32) {
    other = 0,
    integrated = 1,
    discrete = 2,
    virtual = 3,
    cpu = 4,
    _,
};

pub fn enumerate(allocator: std.mem.Allocator, instance: *const Instance) ![]PhysicalDevice {
    const enumerate_fn = instance.proc(EnumerateFn, "vkEnumeratePhysicalDevices") orelse
        return error.VulkanLoaderMissingEntryPoint;
    const get_properties = instance.proc(GetPropertiesFn, "vkGetPhysicalDeviceProperties") orelse
        return error.VulkanLoaderMissingEntryPoint;
    const get_queue_families = instance.proc(GetQueueFamiliesFn, "vkGetPhysicalDeviceQueueFamilyProperties") orelse
        return error.VulkanLoaderMissingEntryPoint;

    var count: u32 = 0;
    if (enumerate_fn(instance.handle, &count, null) != 0) return error.VulkanEnumerationFailed;
    const handles = try allocator.alloc(Handle, count);
    defer allocator.free(handles);
    if (count > 0 and enumerate_fn(instance.handle, &count, handles.ptr) != 0)
        return error.VulkanEnumerationFailed;
    const result = try allocator.alloc(PhysicalDevice, count);
    errdefer allocator.free(result);

    for (handles[0..count], 0..) |handle, index| {
        var properties: [1024]u64 align(8) = @splat(0);
        get_properties(handle, @ptrCast(&properties));
        const prefix: *const PropertiesPrefix = @ptrCast(&properties);
        var family_count: u32 = 0;
        get_queue_families(handle, &family_count, null);
        const families = try allocator.alloc(QueueFamilyProperties, family_count);
        defer allocator.free(families);
        if (family_count > 0) get_queue_families(handle, &family_count, families.ptr);

        var graphics_family: ?u32 = null;
        for (families[0..family_count], 0..) |family, family_index| {
            if (family.queue_count > 0 and family.queue_flags & 1 != 0) {
                graphics_family = @intCast(family_index);
                break;
            }
        }
        result[index] = .{
            .handle = handle,
            .api_version = prefix.api_version,
            .driver_version = prefix.driver_version,
            .vendor_id = prefix.vendor_id,
            .device_id = prefix.device_id,
            .device_type = @enumFromInt(prefix.device_type),
            .name = prefix.name,
            .graphics_queue_family = graphics_family,
        };
    }
    return result;
}
