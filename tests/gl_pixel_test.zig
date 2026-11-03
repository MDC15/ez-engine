const std = @import("std");
const fixture = @import("render_pixel_fixture.zig");
const GlApp = @import("gl_app").GlApp;

test "OpenGL backend renders expected sprite pixels" {
    try fixture.run(GlApp);
}

test "GlApp initialization failure cleans every completed stage" {
    for (0..3) |fail_at| {
        var app: GlApp = undefined;
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
