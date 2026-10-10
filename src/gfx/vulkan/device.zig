const std = @import("std");
const InstanceModule = @import("instance.zig");
const Instance = InstanceModule.Instance;
const Handle = InstanceModule.Handle;
const PhysicalDevice = @import("physical_device.zig").PhysicalDevice;

const QueueCreateInfo = extern struct {
    s_type: u32 = 2,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_family_index: u32,
    queue_count: u32,
    priorities: [*]const f32,
};
const DeviceCreateInfo = extern struct {
    s_type: u32 = 3,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_create_info_count: u32,
    queue_create_infos: *const QueueCreateInfo,
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    enabled_extension_names: ?[*]const [*:0]const u8 = null,
    enabled_features: ?*const anyopaque = null,
};

const CreateDeviceFn = *const fn (Handle, *const DeviceCreateInfo, ?*const anyopaque, *Handle) callconv(.c) i32;
const DestroyDeviceFn = *const fn (Handle, ?*const anyopaque) callconv(.c) void;
const GetDeviceProcAddrFn = *const fn (Handle, [*:0]const u8) callconv(.c) ?*const anyopaque;
const GetDeviceQueueFn = *const fn (Handle, u32, u32, *Handle) callconv(.c) void;
const WaitIdleFn = *const fn (Handle) callconv(.c) i32;

pub const Device = struct {
    handle: Handle,
    graphics_queue: Handle,
    present_queue: Handle,
    graphics_queue_family: u32,
    present_queue_family: u32,
    get_device_proc_addr: GetDeviceProcAddrFn,
    destroy_device: DestroyDeviceFn,
    wait_idle: WaitIdleFn,

    pub fn init(instance: *const Instance, physical: PhysicalDevice, extensions: []const [*:0]const u8) !Device {
        const family = physical.graphics_queue_family orelse return error.NoGraphicsQueue;
        return initWithQueueFamilies(instance, physical, family, family, extensions);
    }

    pub fn initWithQueueFamilies(
        instance: *const Instance,
        physical: PhysicalDevice,
        graphics_family: u32,
        present_family: u32,
        extensions: []const [*:0]const u8,
    ) !Device {
        const create_device = instance.proc(CreateDeviceFn, "vkCreateDevice") orelse
            return error.VulkanLoaderMissingEntryPoint;
        const get_device_proc_addr = instance.proc(GetDeviceProcAddrFn, "vkGetDeviceProcAddr") orelse
            return error.VulkanLoaderMissingEntryPoint;

        const priority: f32 = 1;
        const queue_info = [_]QueueCreateInfo{
            .{ .queue_family_index = graphics_family, .queue_count = 1, .priorities = @ptrCast(&priority) },
            .{ .queue_family_index = present_family, .queue_count = 1, .priorities = @ptrCast(&priority) },
        };
        const queue_count: u32 = if (graphics_family == present_family) 1 else 2;
        const create_info = DeviceCreateInfo{
            .queue_create_info_count = queue_count,
            .queue_create_infos = &queue_info[0],
            .enabled_extension_count = @intCast(extensions.len),
            .enabled_extension_names = if (extensions.len == 0) null else extensions.ptr,
        };
        var handle: Handle = null;
        if (create_device(physical.handle, &create_info, null, &handle) != 0 or handle == null)
            return error.VulkanDeviceCreationFailed;
        errdefer if (InstanceModule.castProc(DestroyDeviceFn, get_device_proc_addr(handle, "vkDestroyDevice"))) |destroy|
            destroy(handle, null);

        const destroy_device = InstanceModule.castProc(DestroyDeviceFn, get_device_proc_addr(handle, "vkDestroyDevice")) orelse
            return error.VulkanLoaderMissingEntryPoint;
        const wait_idle = InstanceModule.castProc(WaitIdleFn, get_device_proc_addr(handle, "vkDeviceWaitIdle")) orelse
            return error.VulkanLoaderMissingEntryPoint;
        const get_device_queue = InstanceModule.castProc(GetDeviceQueueFn, get_device_proc_addr(handle, "vkGetDeviceQueue")) orelse
            return error.VulkanLoaderMissingEntryPoint;
        var graphics_queue: Handle = null;
        get_device_queue(handle, graphics_family, 0, &graphics_queue);
        var present_queue: Handle = null;
        get_device_queue(handle, present_family, 0, &present_queue);
        return .{
            .handle = handle,
            .graphics_queue = graphics_queue,
            .present_queue = present_queue,
            .graphics_queue_family = graphics_family,
            .present_queue_family = present_family,
            .get_device_proc_addr = get_device_proc_addr,
            .destroy_device = destroy_device,
            .wait_idle = wait_idle,
        };
    }

    pub fn proc(self: *const Device, comptime T: type, name: [:0]const u8) ?T {
        return InstanceModule.castProc(T, self.get_device_proc_addr(self.handle, name));
    }

    pub fn waitIdle(self: *const Device) !void {
        if (self.wait_idle(self.handle) != 0) return error.VulkanWaitFailed;
    }

    pub fn deinit(self: *Device) void {
        _ = self.wait_idle(self.handle);
        self.destroy_device(self.handle, null);
        self.handle = null;
        self.graphics_queue = null;
        self.present_queue = null;
    }
};
