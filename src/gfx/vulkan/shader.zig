const std = @import("std");
const Instance = @import("instance.zig").Instance;
const Device = @import("device.zig").Device;
const Handle = @import("instance.zig").Handle;

const CreateInfo = extern struct {
    s_type: u32 = 16,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    code_size: usize,
    code: [*]const u32,
};
const CreateShaderModuleFn = *const fn (Handle, *const CreateInfo, ?*const anyopaque, *Handle) callconv(.c) i32;
const DestroyShaderModuleFn = *const fn (Handle, Handle, ?*const anyopaque) callconv(.c) void;

pub const ShaderModule = struct {
    handle: Handle,
    device: Handle,
    destroy_fn: DestroyShaderModuleFn,

    pub fn init(instance: *const Instance, device: *const Device, words: []const u32) !ShaderModule {
        if (words.len == 0 or words[0] != 0x07230203) return error.InvalidShader;
        const create_fn = device.proc(CreateShaderModuleFn, "vkCreateShaderModule") orelse return error.VulkanLoaderMissingEntryPoint;
        const destroy_fn = device.proc(DestroyShaderModuleFn, "vkDestroyShaderModule") orelse return error.VulkanLoaderMissingEntryPoint;
        const create_info = CreateInfo{ .code_size = try std.math.mul(usize, words.len, @sizeOf(u32)), .code = words.ptr };
        var handle: Handle = null;
        if (create_fn(device.handle, &create_info, null, &handle) != 0 or handle == null)
            return error.VulkanShaderCreationFailed;
        _ = instance;
        return .{ .handle = handle, .device = device.handle, .destroy_fn = destroy_fn };
    }

    pub fn deinit(self: *ShaderModule) void {
        self.destroy_fn(self.device, self.handle, null);
        self.handle = null;
    }
};
