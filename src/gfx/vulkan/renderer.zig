const std = @import("std");
const InstanceModule = @import("instance.zig");
const PhysicalDeviceModule = @import("physical_device.zig");
const DeviceModule = @import("device.zig");

/// Owns Vulkan loader, instance, selected physical device, and logical device.
/// Surface/swapchain creation is intentionally delegated to a platform adapter.
pub const Context = struct {
    allocator: std.mem.Allocator,
    instance: InstanceModule.Instance,
    physical_device: PhysicalDeviceModule.PhysicalDevice,
    device: DeviceModule.Device,

    pub fn init(application_name: [*:0]const u8, instance_extensions: []const [*:0]const u8, device_extensions: []const [*:0]const u8) !Context {
        return initWithAllocator(std.heap.page_allocator, application_name, instance_extensions, device_extensions);
    }

    pub fn initWithAllocator(allocator: std.mem.Allocator, application_name: [*:0]const u8, instance_extensions: []const [*:0]const u8, device_extensions: []const [*:0]const u8) !Context {
        var instance = try InstanceModule.Instance.init(application_name, instance_extensions);
        errdefer instance.deinit();
        const physical_devices = try PhysicalDeviceModule.enumerate(allocator, &instance);
        defer allocator.free(physical_devices);

        var selected: ?PhysicalDeviceModule.PhysicalDevice = null;
        for (physical_devices) |physical| {
            if (physical.graphics_queue_family == null) continue;
            if (selected == null or (physical.device_type == .discrete and selected.?.device_type != .discrete))
                selected = physical;
        }
        const physical = selected orelse return error.NoSuitableVulkanDevice;
        var device = try DeviceModule.Device.init(&instance, physical, device_extensions);
        errdefer device.deinit();
        return .{ .allocator = allocator, .instance = instance, .physical_device = physical, .device = device };
    }

    pub fn deinit(self: *Context) void {
        self.device.deinit();
        self.instance.deinit();
    }
};
