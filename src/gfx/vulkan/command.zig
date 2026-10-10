const Instance = @import("instance.zig").Instance;
const Device = @import("device.zig").Device;
const Handle = @import("instance.zig").Handle;

const PoolCreateInfo = extern struct {
    s_type: u32 = 39,
    next: ?*const anyopaque = null,
    flags: u32 = 2,
    queue_family_index: u32,
};
const AllocateInfo = extern struct {
    s_type: u32 = 40,
    next: ?*const anyopaque = null,
    pool: Handle,
    level: u32 = 0,
    count: u32,
};
const BeginInfo = extern struct {
    s_type: u32 = 42,
    next: ?*const anyopaque = null,
    flags: u32 = 1,
    inheritance_info: ?*const anyopaque = null,
};

const CreatePoolFn = *const fn (Handle, *const PoolCreateInfo, ?*const anyopaque, *Handle) callconv(.c) i32;
const DestroyPoolFn = *const fn (Handle, Handle, ?*const anyopaque) callconv(.c) void;
const AllocateBuffersFn = *const fn (Handle, *const AllocateInfo, [*]Handle) callconv(.c) i32;
const FreeBuffersFn = *const fn (Handle, Handle, u32, [*]const Handle) callconv(.c) void;
const BeginFn = *const fn (Handle, *const BeginInfo) callconv(.c) i32;
const EndFn = *const fn (Handle) callconv(.c) i32;
const ResetFn = *const fn (Handle, u32) callconv(.c) i32;
const SubmitInfo = extern struct {
    s_type: u32 = 4,
    next: ?*const anyopaque = null,
    wait_count: u32 = 0,
    waits: ?[*]const u64 = null,
    wait_stages: ?[*]const u32 = null,
    command_count: u32 = 1,
    commands: *const Handle,
    signal_count: u32 = 0,
    signals: ?[*]const u64 = null,
};
const QueueSubmitFn = *const fn (Handle, u32, *const SubmitInfo, u64) callconv(.c) i32;
const ClearColor = extern union {
    float32: [4]f32,
    int32: [4]i32,
    uint32: [4]u32,
};
const ClearValue = extern union { color: ClearColor, depth_stencil: extern struct { depth: f32, stencil: u32 } };
const RenderPassBeginInfo = extern struct {
    s_type: u32 = 43,
    next: ?*const anyopaque = null,
    render_pass: Handle,
    framebuffer: Handle,
    area: extern struct {
        offset: extern struct { x: i32, y: i32 },
        extent: extern struct { width: u32, height: u32 },
    },
    clear_count: u32,
    clear_values: *const ClearValue,
};
const CmdBeginRenderPassFn = *const fn (Handle, *const RenderPassBeginInfo, u32) callconv(.c) void;
const CmdEndRenderPassFn = *const fn (Handle) callconv(.c) void;
const CmdBindPipelineFn = *const fn (Handle, u32, Handle) callconv(.c) void;
const CmdDrawFn = *const fn (Handle, u32, u32, u32, u32) callconv(.c) void;

pub const CommandPool = struct {
    handle: Handle,
    device: Handle,
    queue: Handle,
    destroy_pool: DestroyPoolFn,
    free_buffers: FreeBuffersFn,

    pub fn init(instance: *const Instance, device: *const Device) !CommandPool {
        const create_fn = device.proc(CreatePoolFn, "vkCreateCommandPool") orelse return error.VulkanLoaderMissingEntryPoint;
        const destroy_fn = device.proc(DestroyPoolFn, "vkDestroyCommandPool") orelse return error.VulkanLoaderMissingEntryPoint;
        const create_info = PoolCreateInfo{ .queue_family_index = device.graphics_queue_family };
        var handle: Handle = null;
        if (create_fn(device.handle, &create_info, null, &handle) != 0 or handle == null)
            return error.VulkanCommandPoolCreationFailed;
        errdefer destroy_fn(device.handle, handle, null);
        _ = instance;
        const free_fn = device.proc(FreeBuffersFn, "vkFreeCommandBuffers") orelse return error.VulkanLoaderMissingEntryPoint;
        return .{
            .handle = handle,
            .device = device.handle,
            .queue = device.graphics_queue,
            .destroy_pool = destroy_fn,
            .free_buffers = free_fn,
        };
    }

    pub fn allocate(self: *const CommandPool, device: *const Device) !CommandBuffer {
        const allocate_fn = device.proc(AllocateBuffersFn, "vkAllocateCommandBuffers") orelse return error.VulkanLoaderMissingEntryPoint;
        const begin_fn = device.proc(BeginFn, "vkBeginCommandBuffer") orelse return error.VulkanLoaderMissingEntryPoint;
        const end_fn = device.proc(EndFn, "vkEndCommandBuffer") orelse return error.VulkanLoaderMissingEntryPoint;
        const reset_fn = device.proc(ResetFn, "vkResetCommandBuffer") orelse return error.VulkanLoaderMissingEntryPoint;
        var handle: Handle = null;
        const info = AllocateInfo{ .pool = self.handle, .count = 1 };
        if (allocate_fn(self.device, &info, @ptrCast(&handle)) != 0 or handle == null)
            return error.VulkanCommandBufferAllocationFailed;
        return .{
            .handle = handle,
            .device = self.device,
            .pool = self.handle,
            .queue = self.queue,
            .begin_fn = begin_fn,
            .end_fn = end_fn,
            .reset_fn = reset_fn,
            .free_fn = self.free_buffers,
        };
    }

    pub fn deinit(self: *CommandPool) void {
        self.destroy_pool(self.device, self.handle, null);
        self.handle = null;
    }
};

pub const CommandBuffer = struct {
    handle: Handle,
    device: Handle,
    pool: Handle,
    queue: Handle,
    begin_fn: BeginFn,
    end_fn: EndFn,
    reset_fn: ResetFn,
    free_fn: FreeBuffersFn,

    pub fn begin(self: *const CommandBuffer) !void {
        if (self.begin_fn(self.handle, &BeginInfo{}) != 0) return error.VulkanCommandBeginFailed;
    }

    pub fn end(self: *const CommandBuffer) !void {
        if (self.end_fn(self.handle) != 0) return error.VulkanCommandEndFailed;
    }

    pub fn submit(self: *const CommandBuffer, device: *const Device) !void {
        try self.submitWithSync(device, &.{}, &.{}, &.{}, 0);
    }

    pub fn submitWithSync(
        self: *const CommandBuffer,
        device: *const Device,
        wait_semaphores: []const u64,
        wait_stage_masks: []const u32,
        signal_semaphores: []const u64,
        fence: u64,
    ) !void {
        if (wait_semaphores.len != wait_stage_masks.len) return error.InvalidSemaphoreStages;
        const submit_fn = device.proc(QueueSubmitFn, "vkQueueSubmit") orelse return error.VulkanLoaderMissingEntryPoint;
        const submit_info = SubmitInfo{
            .wait_count = @intCast(wait_semaphores.len),
            .waits = if (wait_semaphores.len == 0) null else wait_semaphores.ptr,
            .wait_stages = if (wait_stage_masks.len == 0) null else wait_stage_masks.ptr,
            .commands = &self.handle,
            .signal_count = @intCast(signal_semaphores.len),
            .signals = if (signal_semaphores.len == 0) null else signal_semaphores.ptr,
        };
        if (submit_fn(self.queue, 1, &submit_info, fence) != 0) return error.VulkanQueueSubmitFailed;
    }

    pub fn reset(self: *const CommandBuffer) !void {
        if (self.reset_fn(self.handle, 0) != 0) return error.VulkanCommandResetFailed;
    }

    pub fn beginRenderPass(
        self: *const CommandBuffer,
        device: *const Device,
        render_pass: Handle,
        framebuffer: Handle,
        width: u32,
        height: u32,
        clear_color: [4]f32,
    ) !void {
        if (render_pass == null or framebuffer == null or width == 0 or height == 0)
            return error.InvalidRenderPassBegin;
        const begin_fn = device.proc(CmdBeginRenderPassFn, "vkCmdBeginRenderPass") orelse return error.VulkanLoaderMissingEntryPoint;
        const clear_value = ClearValue{ .color = .{ .float32 = clear_color } };
        const info = RenderPassBeginInfo{
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } },
            .clear_count = 1,
            .clear_values = &clear_value,
        };
        begin_fn(self.handle, &info, 0);
    }

    pub fn endRenderPass(self: *const CommandBuffer, device: *const Device) !void {
        const end_fn = device.proc(CmdEndRenderPassFn, "vkCmdEndRenderPass") orelse return error.VulkanLoaderMissingEntryPoint;
        end_fn(self.handle);
    }

    pub fn bindGraphicsPipeline(self: *const CommandBuffer, device: *const Device, pipeline: Handle) !void {
        if (pipeline == null) return error.InvalidPipeline;
        const bind_fn = device.proc(CmdBindPipelineFn, "vkCmdBindPipeline") orelse return error.VulkanLoaderMissingEntryPoint;
        bind_fn(self.handle, 0, pipeline);
    }

    pub fn draw(self: *const CommandBuffer, device: *const Device, vertex_count: u32, instance_count: u32) !void {
        if (vertex_count == 0 or instance_count == 0) return error.InvalidDrawCount;
        const draw_fn = device.proc(CmdDrawFn, "vkCmdDraw") orelse return error.VulkanLoaderMissingEntryPoint;
        draw_fn(self.handle, vertex_count, instance_count, 0, 0);
    }

    pub fn deinit(self: *CommandBuffer) void {
        self.free_fn(self.device, self.pool, 1, @ptrCast(&self.handle));
        self.handle = null;
    }
};
