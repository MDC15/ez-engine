const std = @import("std");
const builtin = @import("builtin");

pub const Handle = ?*anyopaque;
pub const Result = i32;
pub const success: Result = 0;

const ApplicationInfo = extern struct {
    s_type: u32 = 0,
    next: ?*const anyopaque = null,
    application_name: ?[*:0]const u8 = null,
    application_version: u32 = 0,
    engine_name: ?[*:0]const u8 = null,
    engine_version: u32 = 0,
    api_version: u32 = 0,
};

const InstanceCreateInfo = extern struct {
    s_type: u32 = 1,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    application_info: ?*const ApplicationInfo,
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    enabled_extension_names: ?[*]const [*:0]const u8 = null,
};

const CreateInstanceFn = *const fn (*const InstanceCreateInfo, ?*const anyopaque, *Handle) callconv(.c) Result;
const DestroyInstanceFn = *const fn (Handle, ?*const anyopaque) callconv(.c) void;
pub const GetInstanceProcAddrFn = *const fn (Handle, [*:0]const u8) callconv(.c) ?*const anyopaque;

/// Owns a dynamically loaded Vulkan loader and VkInstance. This core bootstrap
/// needs no Vulkan headers and supports externally supplied instance extension
/// names (for example the extension requested by a platform surface adapter).
pub const Instance = struct {
    library: std.DynLib,
    handle: Handle,
    get_instance_proc_addr: GetInstanceProcAddrFn,
    destroy_instance: DestroyInstanceFn,

    pub fn init(
        application_name: [*:0]const u8,
        extensions: []const [*:0]const u8,
    ) !Instance {
        var library = try openLoader();
        errdefer library.close();

        const get_proc = library.lookup(GetInstanceProcAddrFn, "vkGetInstanceProcAddr") orelse
            return error.VulkanLoaderMissingEntryPoint;
        const create_instance = castProc(CreateInstanceFn, get_proc(null, "vkCreateInstance")) orelse
            return error.VulkanLoaderMissingEntryPoint;

        const app_info = ApplicationInfo{
            .s_type = 0,
            .application_name = application_name,
            .engine_name = "game-lib",
            .api_version = makeApiVersion(1, 0, 0),
        };
        const create_info = InstanceCreateInfo{
            .application_info = &app_info,
            .enabled_extension_count = @intCast(extensions.len),
            .enabled_extension_names = if (extensions.len == 0) null else extensions.ptr,
        };
        var handle: Handle = null;
        const result = create_instance(&create_info, null, &handle);
        if (result != success or handle == null) return error.VulkanInstanceCreationFailed;

        const destroy_instance = castProc(DestroyInstanceFn, get_proc(handle, "vkDestroyInstance")) orelse {
            const destroy = castProc(DestroyInstanceFn, get_proc(handle, "vkDestroyInstance"));
            if (destroy) |destroy_fn| destroy_fn(handle, null);
            return error.VulkanLoaderMissingEntryPoint;
        };

        return .{
            .library = library,
            .handle = handle,
            .get_instance_proc_addr = get_proc,
            .destroy_instance = destroy_instance,
        };
    }

    pub fn deinit(self: *Instance) void {
        self.destroy_instance(self.handle, null);
        self.library.close();
        self.handle = null;
    }

    pub fn proc(self: *const Instance, comptime T: type, name: [:0]const u8) ?T {
        return castProc(T, self.get_instance_proc_addr(self.handle, name));
    }
};

fn openLoader() !std.DynLib {
    switch (builtin.os.tag) {
        .windows => return std.DynLib.openZ("vulkan-1.dll") catch error.VulkanLoaderUnavailable,
        .macos => return std.DynLib.openZ("libvulkan.1.dylib") catch error.VulkanLoaderUnavailable,
        .linux => {
            const paths: []const [:0]const u8 = switch (builtin.cpu.arch) {
                .x86_64 => &.{
                    "/lib/x86_64-linux-gnu/libvulkan.so.1",
                    "/usr/lib/x86_64-linux-gnu/libvulkan.so.1",
                    "/usr/local/lib/libvulkan.so.1",
                },
                .aarch64 => &.{
                    "/lib/aarch64-linux-gnu/libvulkan.so.1",
                    "/usr/lib/aarch64-linux-gnu/libvulkan.so.1",
                    "/usr/local/lib/libvulkan.so.1",
                },
                else => &.{ "/usr/lib/libvulkan.so.1", "/usr/local/lib/libvulkan.so.1" },
            };
            for (paths) |path| {
                if (std.DynLib.openZ(path)) |library| return library else |_| {}
            }
            return error.VulkanLoaderUnavailable;
        },
        else => return error.UnsupportedVulkanPlatform,
    }
}

pub fn makeApiVersion(major: u32, minor: u32, patch: u32) u32 {
    return (major << 22) | (minor << 12) | patch;
}

pub fn castProc(comptime T: type, proc: ?*const anyopaque) ?T {
    return if (proc) |pointer| @ptrCast(pointer) else null;
}

test "Vulkan API version encoding" {
    try std.testing.expectEqual(@as(u32, 1 << 22), makeApiVersion(1, 0, 0));
}
