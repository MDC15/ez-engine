const std = @import("std");
const Device = @import("device.zig").Device;
const Handle = @import("instance.zig").Handle;

pub const LayoutInfo = struct {
    set_layouts: []const Handle = &.{},
    push_constant_ranges: []const PushConstantRange = &.{},
};

pub const PushConstantRange = struct {
    stage_flags: u32,
    offset: u32,
    size: u32,
};

const NativePushConstantRange = extern struct { stage_flags: u32, offset: u32, size: u32 };
const CreateInfo = extern struct {
    s_type: u32 = 30,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    set_layout_count: u32,
    set_layouts: ?[*]const Handle,
    push_constant_range_count: u32,
    push_constant_ranges: ?[*]const NativePushConstantRange,
};
const CreateLayoutFn = *const fn (Handle, *const CreateInfo, ?*const anyopaque, *Handle) callconv(.c) i32;
const DestroyLayoutFn = *const fn (Handle, Handle, ?*const anyopaque) callconv(.c) void;
const ShaderStage = extern struct {
    s_type: u32 = 18,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: u32,
    module: Handle,
    entry_point: [*:0]const u8,
    specialization: ?*const anyopaque = null,
};
const VertexInputState = extern struct {
    s_type: u32 = 19,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    binding_count: u32 = 0,
    bindings: ?*const anyopaque = null,
    attribute_count: u32 = 0,
    attributes: ?*const anyopaque = null,
};
const InputAssemblyState = extern struct {
    s_type: u32 = 20,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    topology: u32,
    primitive_restart: u32 = 0,
};
const Viewport = extern struct { x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32 };
const Rect2D = extern struct { offset: extern struct { x: i32, y: i32 }, extent: extern struct { width: u32, height: u32 } };
const ViewportState = extern struct {
    s_type: u32 = 22,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    viewport_count: u32 = 1,
    viewports: *const Viewport,
    scissor_count: u32 = 1,
    scissors: *const Rect2D,
};
const RasterizationState = extern struct {
    s_type: u32 = 23,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    depth_clamp: u32 = 0,
    discard: u32 = 0,
    polygon_mode: u32 = 0,
    cull_mode: u32,
    front_face: u32,
    depth_bias: u32 = 0,
    depth_bias_constant: f32 = 0,
    depth_bias_clamp: f32 = 0,
    depth_bias_slope: f32 = 0,
    line_width: f32 = 1,
};
const MultisampleState = extern struct {
    s_type: u32 = 24,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    rasterization_samples: u32 = 1,
    sample_shading: u32 = 0,
    min_sample_shading: f32 = 0,
    sample_mask: ?*const u32 = null,
    alpha_to_coverage: u32 = 0,
    alpha_to_one: u32 = 0,
};
const ColorBlendAttachment = extern struct {
    blend_enable: u32 = 0,
    src_color_factor: u32 = 1,
    dst_color_factor: u32 = 0,
    color_op: u32 = 0,
    src_alpha_factor: u32 = 1,
    dst_alpha_factor: u32 = 0,
    alpha_op: u32 = 0,
    color_write_mask: u32 = 0xf,
};
const ColorBlendState = extern struct {
    s_type: u32 = 26,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    logic_op_enable: u32 = 0,
    logic_op: u32 = 0,
    attachment_count: u32 = 1,
    attachments: *const ColorBlendAttachment,
    blend_constants: [4]f32 = @splat(0),
};
const GraphicsCreateInfo = extern struct {
    s_type: u32 = 28,
    next: ?*const anyopaque = null,
    flags: u32 = 0,
    stage_count: u32,
    stages: [*]const ShaderStage,
    vertex_input: *const VertexInputState,
    input_assembly: *const InputAssemblyState,
    tessellation: ?*const anyopaque = null,
    viewport: *const ViewportState,
    rasterization: *const RasterizationState,
    multisample: *const MultisampleState,
    depth_stencil: ?*const anyopaque = null,
    color_blend: *const ColorBlendState,
    dynamic_state: ?*const anyopaque = null,
    layout: Handle,
    render_pass: Handle,
    subpass: u32 = 0,
    base_pipeline: Handle = null,
    base_pipeline_index: i32 = -1,
};
const CreateGraphicsFn = *const fn (Handle, u64, u32, *const GraphicsCreateInfo, ?*const anyopaque, *Handle) callconv(.c) i32;
const DestroyPipelineFn = *const fn (Handle, Handle, ?*const anyopaque) callconv(.c) void;

pub const ShaderStageInfo = struct {
    stage: u32,
    module: Handle,
    entry_point: [*:0]const u8 = "main",
};

pub const GraphicsInfo = struct {
    stages: []const ShaderStageInfo,
    layout: Handle,
    render_pass: Handle,
    width: u32,
    height: u32,
    topology: u32 = 3,
    cull_mode: u32 = 2,
    front_face: u32 = 1,
};

/// Vulkan pipeline layout, which is independent of a render pass/framebuffer.
pub const PipelineLayout = struct {
    handle: Handle,
    device: Handle,
    destroy_fn: DestroyLayoutFn,

    pub fn init(device: *const Device, allocator: std.mem.Allocator, info: LayoutInfo) !PipelineLayout {
        const ranges = try allocator.alloc(NativePushConstantRange, info.push_constant_ranges.len);
        defer allocator.free(ranges);
        for (info.push_constant_ranges, 0..) |range, index| {
            if (range.stage_flags == 0 or range.size == 0 or range.offset % 4 != 0 or range.size % 4 != 0)
                return error.InvalidPushConstantRange;
            ranges[index] = .{ .stage_flags = range.stage_flags, .offset = range.offset, .size = range.size };
        }
        const create_fn = device.proc(CreateLayoutFn, "vkCreatePipelineLayout") orelse return error.VulkanLoaderMissingEntryPoint;
        const destroy_fn = device.proc(DestroyLayoutFn, "vkDestroyPipelineLayout") orelse return error.VulkanLoaderMissingEntryPoint;
        const native = CreateInfo{
            .set_layout_count = @intCast(info.set_layouts.len),
            .set_layouts = if (info.set_layouts.len == 0) null else info.set_layouts.ptr,
            .push_constant_range_count = @intCast(ranges.len),
            .push_constant_ranges = if (ranges.len == 0) null else ranges.ptr,
        };

        var handle: Handle = null;
        if (create_fn(device.handle, &native, null, &handle) != 0 or handle == null)
            return error.VulkanPipelineLayoutCreationFailed;
        return .{ .handle = handle, .device = device.handle, .destroy_fn = destroy_fn };
    }

    pub fn deinit(self: *PipelineLayout) void {
        self.destroy_fn(self.device, self.handle, null);
        self.handle = null;
    }
};

pub const GraphicsPipeline = struct {
    handle: Handle,
    device: Handle,
    destroy_fn: DestroyPipelineFn,

    pub fn init(device: *const Device, allocator: std.mem.Allocator, description: GraphicsInfo) !GraphicsPipeline {
        if (description.stages.len == 0 or description.layout == null or description.render_pass == null or
            description.width == 0 or description.height == 0)
            return error.InvalidGraphicsPipeline;
        const stages = try allocator.alloc(ShaderStage, description.stages.len);
        defer allocator.free(stages);
        for (description.stages, 0..) |stage, index| {
            if (stage.module == null or stage.stage == 0) return error.InvalidGraphicsPipeline;
            stages[index] = .{
                .stage = stage.stage,
                .module = stage.module,
                .entry_point = stage.entry_point,
            };
        }

        const viewport = Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(description.width),
            .height = @floatFromInt(description.height),
            .min_depth = 0,
            .max_depth = 1,
        };
        const scissor = Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = description.width, .height = description.height },
        };
        const vertex_input: VertexInputState = .{};
        const input_assembly = InputAssemblyState{ .topology = description.topology };
        const viewport_state = ViewportState{ .viewports = &viewport, .scissors = &scissor };
        const rasterization = RasterizationState{
            .cull_mode = description.cull_mode,
            .front_face = description.front_face,
        };
        const multisample: MultisampleState = .{};
        const blend_attachment: ColorBlendAttachment = .{};
        const blend = ColorBlendState{ .attachments = &blend_attachment };
        const info = GraphicsCreateInfo{
            .stage_count = @intCast(stages.len),
            .stages = stages.ptr,
            .vertex_input = &vertex_input,
            .input_assembly = &input_assembly,
            .viewport = &viewport_state,
            .rasterization = &rasterization,
            .multisample = &multisample,
            .color_blend = &blend,
            .layout = description.layout,
            .render_pass = description.render_pass,
        };
        const create_fn = device.proc(CreateGraphicsFn, "vkCreateGraphicsPipelines") orelse return error.VulkanLoaderMissingEntryPoint;
        const destroy_fn = device.proc(DestroyPipelineFn, "vkDestroyPipeline") orelse return error.VulkanLoaderMissingEntryPoint;
        var handle: Handle = null;
        if (create_fn(device.handle, 0, 1, &info, null, &handle) != 0 or handle == null)
            return error.VulkanGraphicsPipelineCreationFailed;
        return .{ .handle = handle, .device = device.handle, .destroy_fn = destroy_fn };
    }

    pub fn deinit(self: *GraphicsPipeline) void {
        self.destroy_fn(self.device, self.handle, null);
        self.handle = null;
    }
};
