const std = @import("std");

/// Per-frame color adjustments applied after the scene has been rendered.
/// Defaults are an identity transform, preserving the existing sprite output.
pub const Settings = struct {
    grayscale: f32 = 0,
    vignette: f32 = 0,
    exposure: f32 = 1,

    pub fn validate(self: Settings) !void {
        if (!std.math.isFinite(self.grayscale) or self.grayscale < 0 or self.grayscale > 1)
            return error.InvalidPostProcessSettings;
        if (!std.math.isFinite(self.vignette) or self.vignette < 0 or self.vignette > 1)
            return error.InvalidPostProcessSettings;
        if (!std.math.isFinite(self.exposure) or self.exposure < 0 or self.exposure > 8)
            return error.InvalidPostProcessSettings;
    }
};

test "post-process settings default to identity and validate supported ranges" {
    const defaults: Settings = .{};
    try defaults.validate();
    try (Settings{ .grayscale = 1, .vignette = 1, .exposure = 8 }).validate();
    try std.testing.expectError(error.InvalidPostProcessSettings, (Settings{ .grayscale = 1.1 }).validate());
    try std.testing.expectError(error.InvalidPostProcessSettings, (Settings{ .exposure = std.math.nan(f32) }).validate());
}
