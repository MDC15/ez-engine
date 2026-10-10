const Device = @import("device.zig").Device;
const Handle = @import("instance.zig").Handle;

const Components = extern struct { r: u32 = 0, g: u32 = 0, b: u32 = 0, a: u32 = 0 };
const SubresourceRange = extern struct {
    aspect_mask: u32,
    base_mip_level: u32 = 0,
    level_count: u32 = 1,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};
const CreateInfo = extern struct {
    s_type: u32 = 15,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    image: Handle,
    view_type: u32 = 1,
    format: u32,
    components: Components = .{},
    subresource_range: SubresourceRange,
};
const CreateFn = *const fn (Handle, *const CreateInfo, ?*const anyopaque, *Handle) callconv(.c) i32;
const DestroyFn = *const fn (Handle, Handle, ?*const anyopaque) callconv(.c) void;

pub const ImageView = struct {
    handle: Handle,
    device: Handle,
    destroy_fn: DestroyFn,

    pub fn init(device: *const Device, image: Handle, format: u32, aspect_mask: u32, mip_levels: u32) !ImageView {
        if (image == null or aspect_mask == 0 or mip_levels == 0) return error.InvalidImageView;
        const create_fn = device.proc(CreateFn, "vkCreateImageView") orelse return error.VulkanLoaderMissingEntryPoint;
        const destroy_fn = device.proc(DestroyFn, "vkDestroyImageView") orelse return error.VulkanLoaderMissingEntryPoint;
        const info = CreateInfo{
            .image = image,
            .format = format,
            .subresource_range = .{ .aspect_mask = aspect_mask, .level_count = mip_levels },
        };
        var handle: Handle = null;
        if (create_fn(device.handle, &info, null, &handle) != 0 or handle == null)
            return error.VulkanImageViewCreationFailed;
        return .{ .handle = handle, .device = device.handle, .destroy_fn = destroy_fn };
    }

    pub fn deinit(self: *ImageView) void {
        self.destroy_fn(self.device, self.handle, null);
        self.handle = null;
    }
};
