const RenderWorld = @import("../gfx/render_world.zig").RenderWorld;

pub const Stats = struct {
    frame_index: u64 = 0,
    frame_time_ms: f32 = 0,
    fps: f32 = 0,
    entity_count: usize = 0,
    extracted_render_items: usize = 0,
    visible_render_items: usize = 0,
    culled_render_items: usize = 0,
    render_batches: usize = 0,
};

/// Per-frame runtime diagnostics. Disabled by default; enable to collect a
/// smoothed FPS estimate and counts useful while tuning a game.
pub const Monitor = struct {
    enabled: bool = false,
    stats: Stats = .{},
    smoothed_fps: f32 = 0,

    pub fn captureFrame(
        self: *Monitor,
        frame_index: u64,
        dt: f32,
        entity_count: usize,
        extracted_render_items: usize,
        render_world: *const RenderWorld,
    ) void {
        if (!self.enabled) return;

        if (dt > 0) {
            const instant_fps = 1 / dt;
            if (self.smoothed_fps == 0) {
                self.smoothed_fps = instant_fps;
            } else {
                self.smoothed_fps += (instant_fps - self.smoothed_fps) * 0.1;
            }
        }

        var render_batches: usize = 0;
        var batches = render_world.batches();
        while (batches.next() != null) : (render_batches += 1) {}

        const visible_render_items = render_world.items.items.len;
        self.stats = .{
            .frame_index = frame_index,
            .frame_time_ms = dt * 1000,
            .fps = self.smoothed_fps,
            .entity_count = entity_count,
            .extracted_render_items = extracted_render_items,
            .visible_render_items = visible_render_items,
            .culled_render_items = extracted_render_items -| visible_render_items,
            .render_batches = render_batches,
        };
    }
};
