const Device = @import("device.zig").Device;
const Handle = @import("instance.zig").Handle;

const AttachmentDescription = extern struct {
    flags: u32 = 0,
    format: u32,
    samples: u32 = 1,
    load_op: u32 = 1,
    store_op: u32 = 0,
    stencil_load_op: u32 = 2,
    stencil_store_op: u32 = 1,
    initial_layout: u32 = 0,
    final_layout: u32,
};
const AttachmentReference = extern struct { attachment: u32 = 0, layout: u32 = 2 };
const SubpassDescription = extern struct {
    flags: u32 = 0,
    pipeline_bind_point: u32 = 0,
    input_count: u32 = 0,
    inputs: ?*const anyopaque = null,
    color_count: u32 = 1,
    colors: *const AttachmentReference,
    resolves: ?*const anyopaque = null,
    depth_stencil: ?*const anyopaque = null,
    preserve_count: u32 = 0,
    preserve_attachments: ?[*]const u32 = null,
};
const RenderPassCreateInfo = extern struct {
    s_type: u32 = 38,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    attachment_count: u32 = 1,
    attachments: *const AttachmentDescription,
    subpass_count: u32 = 1,
    subpasses: *const SubpassDescription,
    dependency_count: u32 = 0,
    dependencies: ?*const anyopaque = null,
};
const CreateRenderPassFn = *const fn (Handle, *const RenderPassCreateInfo, ?*const anyopaque, *Handle) callconv(.c) i32;
const DestroyRenderPassFn = *const fn (Handle, Handle, ?*const anyopaque) callconv(.c) void;

pub const RenderPass = struct {
    handle: Handle,
    device: Handle,
    destroy_fn: DestroyRenderPassFn,

    /// Single color attachment render pass. `final_layout` is caller-selected
    /// (commonly COLOR_ATTACHMENT_OPTIMAL or PRESENT_SRC_KHR).
    pub fn init(device: *const Device, format: u32, final_layout: u32) !RenderPass {
        const attachment = AttachmentDescription{ .format = format, .final_layout = final_layout };
        const color_reference = AttachmentReference{};
        const subpass = SubpassDescription{ .colors = &color_reference };
        const info = RenderPassCreateInfo{ .attachments = &attachment, .subpasses = &subpass };
        const create_fn = device.proc(CreateRenderPassFn, "vkCreateRenderPass") orelse return error.VulkanLoaderMissingEntryPoint;
        const destroy_fn = device.proc(DestroyRenderPassFn, "vkDestroyRenderPass") orelse return error.VulkanLoaderMissingEntryPoint;
        var handle: Handle = null;
        if (create_fn(device.handle, &info, null, &handle) != 0 or handle == null)
            return error.VulkanRenderPassCreationFailed;
        return .{ .handle = handle, .device = device.handle, .destroy_fn = destroy_fn };
    }

    pub fn deinit(self: *RenderPass) void {
        self.destroy_fn(self.device, self.handle, null);
        self.handle = null;
    }
};

const FramebufferCreateInfo = extern struct {
    s_type: u32 = 37,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    render_pass: Handle,
    attachment_count: u32,
    attachments: [*]const Handle,
    width: u32,
    height: u32,
    layers: u32 = 1,
};
const CreateFramebufferFn = *const fn (Handle, *const FramebufferCreateInfo, ?*const anyopaque, *Handle) callconv(.c) i32;
const DestroyFramebufferFn = *const fn (Handle, Handle, ?*const anyopaque) callconv(.c) void;

pub const Framebuffer = struct {
    handle: Handle,
    device: Handle,
    destroy_fn: DestroyFramebufferFn,

    pub fn init(device: *const Device, render_pass: Handle, attachments: []const Handle, width: u32, height: u32) !Framebuffer {
        if (render_pass == null or attachments.len == 0 or width == 0 or height == 0)
            return error.InvalidFramebuffer;
        const create_fn = device.proc(CreateFramebufferFn, "vkCreateFramebuffer") orelse return error.VulkanLoaderMissingEntryPoint;
        const destroy_fn = device.proc(DestroyFramebufferFn, "vkDestroyFramebuffer") orelse return error.VulkanLoaderMissingEntryPoint;
        const info = FramebufferCreateInfo{
            .render_pass = render_pass,
            .attachment_count = @intCast(attachments.len),
            .attachments = attachments.ptr,
            .width = width,
            .height = height,
        };
        var handle: Handle = null;
        if (create_fn(device.handle, &info, null, &handle) != 0 or handle == null)
            return error.VulkanFramebufferCreationFailed;
        return .{ .handle = handle, .device = device.handle, .destroy_fn = destroy_fn };
    }

    pub fn deinit(self: *Framebuffer) void {
        self.destroy_fn(self.device, self.handle, null);
        self.handle = null;
    }
};
