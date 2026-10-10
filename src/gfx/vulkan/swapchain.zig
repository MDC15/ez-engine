const std = @import("std");
const Instance = @import("instance.zig").Instance;
const Device = @import("device.zig").Device;
const PhysicalDevice = @import("physical_device.zig").PhysicalDevice;
const Handle = @import("instance.zig").Handle;

pub const SurfaceHandle = u64;
pub const Extent = extern struct { width: u32, height: u32 };
pub const Format = extern struct { format: u32, color_space: u32 };

const Capabilities = extern struct {
    min_image_count: u32,
    max_image_count: u32,
    current_extent: Extent,
    min_image_extent: Extent,
    max_image_extent: Extent,
    max_image_array_layers: u32,
    supported_transforms: u32,
    current_transform: u32,
    supported_composite_alpha: u32,
    supported_usage_flags: u32,
};
const CreateInfo = extern struct {
    s_type: u32 = 1000001000,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    surface: SurfaceHandle,
    min_image_count: u32,
    image_format: u32,
    image_color_space: u32,
    image_extent: Extent,
    image_array_layers: u32 = 1,
    image_usage: u32,
    image_sharing_mode: u32,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
    pre_transform: u32,
    composite_alpha: u32,
    present_mode: u32,
    clipped: u32 = 1,
    old_swapchain: SurfaceHandle = 0,
};
const GetCapabilitiesFn = *const fn (Handle, SurfaceHandle, *Capabilities) callconv(.c) i32;
const GetFormatsFn = *const fn (Handle, SurfaceHandle, *u32, ?[*]Format) callconv(.c) i32;
const GetPresentModesFn = *const fn (Handle, SurfaceHandle, *u32, ?[*]u32) callconv(.c) i32;
const CreateSwapchainFn = *const fn (Handle, *const CreateInfo, ?*const anyopaque, *SurfaceHandle) callconv(.c) i32;
const DestroySwapchainFn = *const fn (Handle, SurfaceHandle, ?*const anyopaque) callconv(.c) void;
const GetImagesFn = *const fn (Handle, SurfaceHandle, *u32, ?[*]Handle) callconv(.c) i32;
const AcquireNextImageFn = *const fn (Handle, SurfaceHandle, u64, u64, u64, *u32) callconv(.c) i32;
const PresentInfo = extern struct {
    s_type: u32 = 1000001001,
    next: ?*const anyopaque = null,
    wait_count: u32,
    waits: ?[*]const u64,
    swapchain_count: u32 = 1,
    swapchains: *const SurfaceHandle,
    image_indices: *const u32,
    result_array: ?[*]i32 = null,
};
const QueuePresentFn = *const fn (Handle, *const PresentInfo) callconv(.c) i32;

/// Vulkan WSI swapchain. The host creates the VkSurfaceKHR through a
/// platform-neutral surface provider; the caller supplies its selected
/// present-capable queue family to Device.initWithQueueFamilies.
pub const Swapchain = struct {
    allocator: std.mem.Allocator,
    handle: SurfaceHandle,
    images: []Handle,
    format: Format,
    extent: Extent,
    device: Handle,
    present_queue: Handle,
    destroy_fn: DestroySwapchainFn,
    acquire_fn: AcquireNextImageFn,
    present_fn: QueuePresentFn,

    pub fn init(
        allocator: std.mem.Allocator,
        instance: *const Instance,
        device: *const Device,
        physical: PhysicalDevice,
        surface: SurfaceHandle,
        requested_extent: Extent,
    ) !Swapchain {
        if (surface == 0 or requested_extent.width == 0 or requested_extent.height == 0)
            return error.InvalidSwapchainInput;
        const get_capabilities = instance.proc(GetCapabilitiesFn, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR") orelse return error.VulkanLoaderMissingEntryPoint;
        const get_formats = instance.proc(GetFormatsFn, "vkGetPhysicalDeviceSurfaceFormatsKHR") orelse return error.VulkanLoaderMissingEntryPoint;
        const get_modes = instance.proc(GetPresentModesFn, "vkGetPhysicalDeviceSurfacePresentModesKHR") orelse return error.VulkanLoaderMissingEntryPoint;
        const create_fn = device.proc(CreateSwapchainFn, "vkCreateSwapchainKHR") orelse return error.VulkanLoaderMissingEntryPoint;
        const destroy_fn = device.proc(DestroySwapchainFn, "vkDestroySwapchainKHR") orelse return error.VulkanLoaderMissingEntryPoint;
        const get_images = device.proc(GetImagesFn, "vkGetSwapchainImagesKHR") orelse return error.VulkanLoaderMissingEntryPoint;
        const acquire_fn = device.proc(AcquireNextImageFn, "vkAcquireNextImageKHR") orelse return error.VulkanLoaderMissingEntryPoint;
        const present_fn = device.proc(QueuePresentFn, "vkQueuePresentKHR") orelse return error.VulkanLoaderMissingEntryPoint;

        var capabilities: Capabilities = undefined;
        if (get_capabilities(physical.handle, surface, &capabilities) != 0)
            return error.VulkanSurfaceQueryFailed;
        var format_count: u32 = 0;
        if (get_formats(physical.handle, surface, &format_count, null) != 0 or format_count == 0)
            return error.NoSurfaceFormats;
        const formats = try allocator.alloc(Format, format_count);
        defer allocator.free(formats);
        if (get_formats(physical.handle, surface, &format_count, formats.ptr) != 0)
            return error.VulkanSurfaceQueryFailed;

        var mode_count: u32 = 0;
        if (get_modes(physical.handle, surface, &mode_count, null) != 0 or mode_count == 0)
            return error.NoPresentModes;
        const modes = try allocator.alloc(u32, mode_count);
        defer allocator.free(modes);
        if (get_modes(physical.handle, surface, &mode_count, modes.ptr) != 0)
            return error.VulkanSurfaceQueryFailed;

        const chosen_format = chooseFormat(formats[0..format_count]);
        const present_mode = choosePresentMode(modes[0..mode_count]);
        const extent = chooseExtent(capabilities, requested_extent);
        if (capabilities.supported_usage_flags & 0x10 == 0) return error.SurfaceCannotRenderColor;
        const image_count = if (capabilities.max_image_count == 0)
            capabilities.min_image_count + 1
        else
            @min(capabilities.min_image_count + 1, capabilities.max_image_count);
        const composite_alpha = chooseCompositeAlpha(capabilities.supported_composite_alpha) orelse
            return error.NoSupportedCompositeAlpha;
        const create_info = CreateInfo{
            .surface = surface,
            .min_image_count = image_count,
            .image_format = chosen_format.format,
            .image_color_space = chosen_format.color_space,
            .image_extent = extent,
            .image_usage = 0x10,
            .image_sharing_mode = if (device.graphics_queue_family == device.present_queue_family) 0 else 1,
            .queue_family_index_count = if (device.graphics_queue_family == device.present_queue_family) 0 else 2,
            .queue_family_indices = if (device.graphics_queue_family == device.present_queue_family)
                null
            else
                &.{ device.graphics_queue_family, device.present_queue_family },
            .pre_transform = capabilities.current_transform,
            .composite_alpha = composite_alpha,
            .present_mode = present_mode,
        };
        var handle: SurfaceHandle = 0;
        if (create_fn(device.handle, &create_info, null, &handle) != 0 or handle == 0)
            return error.VulkanSwapchainCreationFailed;
        errdefer destroy_fn(device.handle, handle, null);

        var actual_image_count: u32 = 0;
        if (get_images(device.handle, handle, &actual_image_count, null) != 0 or actual_image_count == 0)
            return error.VulkanSwapchainImageQueryFailed;
        const images = try allocator.alloc(Handle, actual_image_count);
        errdefer allocator.free(images);
        if (get_images(device.handle, handle, &actual_image_count, images.ptr) != 0)
            return error.VulkanSwapchainImageQueryFailed;
        return .{
            .allocator = allocator,
            .handle = handle,
            .images = images[0..actual_image_count],
            .format = chosen_format,
            .extent = extent,
            .device = device.handle,
            .present_queue = device.present_queue,
            .destroy_fn = destroy_fn,
            .acquire_fn = acquire_fn,
            .present_fn = present_fn,
        };
    }

    pub fn acquire(self: *const Swapchain, semaphore: u64, fence: u64) !u32 {
        var image_index: u32 = 0;
        const result = self.acquire_fn(self.device, self.handle, std.math.maxInt(u64), semaphore, fence, &image_index);
        if (result != 0 and result != 1000001003) return error.VulkanAcquireFailed;
        return image_index;
    }

    pub fn present(self: *const Swapchain, image_index: u32, wait_semaphores: []const u64) !void {
        if (image_index >= self.images.len) return error.InvalidSwapchainImage;
        const info = PresentInfo{
            .wait_count = @intCast(wait_semaphores.len),
            .waits = if (wait_semaphores.len == 0) null else wait_semaphores.ptr,
            .swapchains = &self.handle,
            .image_indices = &image_index,
        };
        const result = self.present_fn(self.present_queue, &info);
        if (result != 0 and result != 1000001003) return error.VulkanPresentFailed;
    }

    pub fn deinit(self: *Swapchain) void {
        self.destroy_fn(self.device, self.handle, null);
        self.allocator.free(self.images);
        self.handle = 0;
        self.images = &.{};
    }
};

fn chooseFormat(formats: []const Format) Format {
    for (formats) |format| {
        if (format.format == 50 and format.color_space == 0) return format;
    }
    return formats[0];
}

fn choosePresentMode(modes: []const u32) u32 {
    for (modes) |mode| if (mode == 1) return mode;
    return 2;
}

fn chooseExtent(capabilities: anytype, requested: Extent) Extent {
    if (capabilities.current_extent.width != std.math.maxInt(u32))
        return capabilities.current_extent;
    return .{
        .width = std.math.clamp(requested.width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
        .height = std.math.clamp(requested.height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
    };
}

fn chooseCompositeAlpha(flags: u32) ?u32 {
    for ([_]u32{ 1, 2, 4, 8 }) |flag| if (flags & flag != 0) return flag;
    return null;
}

test "swapchain helpers select preferred mode and bounded extent" {
    try std.testing.expectEqual(@as(u32, 1), choosePresentMode(&.{ 2, 1 }));
    const caps = .{
        .current_extent = Extent{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) },
        .min_image_extent = Extent{ .width = 320, .height = 200 },
        .max_image_extent = Extent{ .width = 1920, .height = 1080 },
    };
    try std.testing.expectEqual(Extent{ .width = 1920, .height = 200 }, chooseExtent(caps, .{ .width = 3000, .height = 100 }));
}
