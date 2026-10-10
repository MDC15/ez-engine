const Platform = @import("platform");

/// Vulkan surface creation is delegated to a host adapter so the library
/// never owns an OS window or hardcodes SDL/GLFW platform handles.
pub const Surface = struct {
    provider: Platform.VulkanSurface,
    instance: ?*anyopaque,
    handle: u64,

    pub fn init(provider: Platform.VulkanSurface, instance: ?*anyopaque) !Surface {
        return .{ .provider = provider, .instance = instance, .handle = try provider.create(instance) };
    }

    pub fn deinit(self: *Surface) void {
        if (self.handle != 0) self.provider.destroy(self.instance, self.handle);
        self.handle = 0;
    }
};
