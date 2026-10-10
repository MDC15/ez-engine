const std = @import("std");
const ZigImage = @import("ez_zigimg");

pub const PixelFormat = enum { rgba8, bgra8 };
pub const TextureData = struct {
    width: u32,
    height: u32,
    format: PixelFormat,
    pixels: []u8,

    pub fn deinit(self: *TextureData, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// Loads engine-owned "ZTEX" v1: magic, width, height, pixel format byte,
/// three reserved bytes, followed by tightly packed 4-channel pixels.
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !TextureData {
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..4], "ZTEX")) return error.InvalidTexture;
    if (std.mem.readInt(u32, bytes[4..8], .little) != 1) return error.UnsupportedVersion;
    const width = std.mem.readInt(u32, bytes[8..12], .little);
    const height = std.mem.readInt(u32, bytes[12..16], .little);
    if (width == 0 or height == 0) return error.InvalidDimensions;
    if (bytes.len < 20) return error.InvalidTexture;
    const format: PixelFormat = switch (bytes[16]) {
        0 => .rgba8,
        1 => .bgra8,
        else => return error.UnsupportedFormat,
    };
    const pixel_count = try std.math.mul(usize, width, height);
    const pixel_bytes = try std.math.mul(usize, pixel_count, 4);
    if (bytes.len != 20 + pixel_bytes) return error.InvalidTexture;
    const pixels = try allocator.dupe(u8, bytes[20..]);
    return .{ .width = width, .height = height, .format = format, .pixels = pixels };
}

/// Loads either the engine's uncompressed ZTEX format or an 8-bit PNG.
/// `max_decoded_bytes` also limits the expanded RGBA allocation for PNG input.
pub fn loadAny(allocator: std.mem.Allocator, bytes: []const u8, max_decoded_bytes: usize) !TextureData {
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "ZTEX")) {
        const texture = try load(allocator, bytes);
        if (texture.pixels.len > max_decoded_bytes) {
            var owned = texture;
            owned.deinit(allocator);
            return error.TextureTooLarge;
        }
        return texture;
    }

    const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], &png_signature) or
        !std.mem.eql(u8, bytes[12..16], "IHDR")) return error.UnsupportedImageFormat;
    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    if (width == 0 or height == 0) return error.InvalidDimensions;
    const pixel_count = try std.math.mul(usize, width, height);
    const decoded_bytes = try std.math.mul(usize, pixel_count, 4);
    if (decoded_bytes > max_decoded_bytes) return error.TextureTooLarge;
    if (bytes.len > std.math.maxInt(c_int)) return error.EncodedImageTooLarge;

    var image = try ZigImage.fromMemory(allocator, bytes);
    defer image.deinit(allocator);
    if (image.width != width or image.height != height) return error.InvalidDimensions;
    try image.convert(allocator, .rgba32);
    const raw_pixels = image.rawBytes();
    if (raw_pixels.len != decoded_bytes) return error.UnsupportedPixelLayout;
    const pixels = try allocator.dupe(u8, raw_pixels);
    return .{ .width = width, .height = height, .format = .rgba8, .pixels = pixels };
}

test "loads PNG data as bounded RGBA8 pixels" {
    const png = std.base64.standard.Decoder;
    const encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4HyD3HwAGLAJtzSfWCgAAAABJRU5ErkJggg==";
    const decoded_size = try png.calcSizeForSlice(encoded);
    const bytes = try std.testing.allocator.alloc(u8, decoded_size);
    defer std.testing.allocator.free(bytes);
    try png.decode(bytes, encoded);
    var texture = try loadAny(std.testing.allocator, bytes, 4);
    defer texture.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), texture.width);
    try std.testing.expectEqual(@as(u32, 1), texture.height);
    try std.testing.expectEqual(PixelFormat.rgba8, texture.format);
    try std.testing.expectEqual(@as(usize, 4), texture.pixels.len);
    try std.testing.expectError(error.TextureTooLarge, loadAny(std.testing.allocator, bytes, 3));
}
