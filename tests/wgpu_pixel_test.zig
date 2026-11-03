const std = @import("std");
const fixture = @import("render_pixel_fixture.zig");
const App = @import("ez_app").App;

test "WGPU backend renders expected sprite pixels" {
    try fixture.run(App);
}

test "WGPU App initialization failure cleans every completed stage" {
    for (0..4) |fail_at| {
        var app: App = undefined;
        try std.testing.expectError(
            error.InjectedInitFailure,
            app.initWithFaultInjectionForTesting(
                std.testing.allocator,
                "ez-engine-init-failure",
                64,
                64,
                false,
                fail_at,
            ),
        );
    }
}
