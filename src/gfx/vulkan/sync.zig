const Device = @import("device.zig").Device;

const CreateInfo = extern struct {
    s_type: u32,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
};
const CreateFn = *const fn (?*anyopaque, *const CreateInfo, ?*const anyopaque, *u64) callconv(.c) i32;
const DestroyFn = *const fn (?*anyopaque, u64, ?*const anyopaque) callconv(.c) void;
const WaitFencesFn = *const fn (?*anyopaque, u32, [*]const u64, u32, u64) callconv(.c) i32;
const ResetFencesFn = *const fn (?*anyopaque, u32, [*]const u64) callconv(.c) i32;

pub const Semaphore = struct {
    handle: u64,
    device: ?*anyopaque,
    destroy_fn: DestroyFn,

    pub fn init(device: *const Device) !Semaphore {
        const create_fn = device.proc(CreateFn, "vkCreateSemaphore") orelse return error.VulkanLoaderMissingEntryPoint;
        const destroy_fn = device.proc(DestroyFn, "vkDestroySemaphore") orelse return error.VulkanLoaderMissingEntryPoint;
        const info = CreateInfo{ .s_type = 9 };
        var handle: u64 = 0;
        if (create_fn(device.handle, &info, null, &handle) != 0 or handle == 0)
            return error.VulkanSemaphoreCreationFailed;
        return .{ .handle = handle, .device = device.handle, .destroy_fn = destroy_fn };
    }

    pub fn deinit(self: *Semaphore) void {
        self.destroy_fn(self.device, self.handle, null);
        self.handle = 0;
    }
};

pub const Fence = struct {
    handle: u64,
    device: ?*anyopaque,
    destroy_fn: DestroyFn,
    wait_fn: WaitFencesFn,
    reset_fn: ResetFencesFn,

    pub fn init(device: *const Device, initially_signaled: bool) !Fence {
        const create_fn = device.proc(CreateFn, "vkCreateFence") orelse return error.VulkanLoaderMissingEntryPoint;
        const destroy_fn = device.proc(DestroyFn, "vkDestroyFence") orelse return error.VulkanLoaderMissingEntryPoint;
        const wait_fn = device.proc(WaitFencesFn, "vkWaitForFences") orelse return error.VulkanLoaderMissingEntryPoint;
        const reset_fn = device.proc(ResetFencesFn, "vkResetFences") orelse return error.VulkanLoaderMissingEntryPoint;
        const info = CreateInfo{ .s_type = 8, .flags = if (initially_signaled) 1 else 0 };
        var handle: u64 = 0;
        if (create_fn(device.handle, &info, null, &handle) != 0 or handle == 0)
            return error.VulkanFenceCreationFailed;
        return .{ .handle = handle, .device = device.handle, .destroy_fn = destroy_fn, .wait_fn = wait_fn, .reset_fn = reset_fn };
    }

    pub fn wait(self: *const Fence, timeout_ns: u64) !void {
        if (self.wait_fn(self.device, 1, @ptrCast(&self.handle), 1, timeout_ns) != 0) return error.VulkanFenceWaitFailed;
    }

    pub fn reset(self: *const Fence) !void {
        if (self.reset_fn(self.device, 1, @ptrCast(&self.handle)) != 0) return error.VulkanFenceResetFailed;
    }

    pub fn deinit(self: *Fence) void {
        self.destroy_fn(self.device, self.handle, null);
        self.handle = 0;
    }
};
