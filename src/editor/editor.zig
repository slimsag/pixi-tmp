const std = @import("std");
const pixi = @import("pixi");
const zip = @import("zip");
const zstbi = @import("zstbi");
const zgpu = @import("zgpu");

pub const Style = @import("style.zig");

pub const menu = @import("panes/menu.zig");
pub const sidebar = @import("panes/sidebar.zig");
pub const explorer = @import("panes/explorer.zig");
pub const artboard = @import("panes/artboard.zig");
pub const infobar = @import("panes/infobar.zig");

pub fn draw() void {
    sidebar.draw();
    explorer.draw();
    artboard.draw();
}

pub fn setProjectFolder(path: [*:0]const u8) void {
    pixi.state.project_folder = path[0..std.mem.len(path) :0];
}

/// Returns true if a new file was opened.
pub fn openFile(path: [:0]const u8) !bool {
    if (!std.mem.eql(u8, std.fs.path.extension(path[0..path.len]), ".pixi"))
        return false;

    for (pixi.state.open_files.items) |file, i| {
        if (std.mem.eql(u8, file.path, path)) {
            // Free path since we aren't adding it to open files again.
            pixi.state.allocator.free(path);
            setActiveFile(i);
            return false;
        }
    }

    if (zip.zip_open(path.ptr, 0, 'r')) |pixi_file| {
        defer zip.zip_close(pixi_file);

        var buf: ?*anyopaque = null;
        var size: u64 = 0;
        _ = zip.zip_entry_open(pixi_file, "pixidata.json");
        _ = zip.zip_entry_read(pixi_file, &buf, &size);
        _ = zip.zip_entry_close(pixi_file);

        var content: []const u8 = @ptrCast([*]const u8, buf)[0..size];
        const options = std.json.ParseOptions{
            .allocator = pixi.state.allocator,
            .duplicate_field_behavior = .UseFirst,
            .ignore_unknown_fields = true,
            .allow_trailing_data = true,
        };

        var stream = std.json.TokenStream.init(content);
        const external = std.json.parse(pixi.storage.External.Pixi, &stream, options) catch unreachable;
        defer std.json.parseFree(pixi.storage.External.Pixi, external, options);

        var internal: pixi.storage.Internal.Pixi = .{
            .path = path,
            .width = external.width,
            .height = external.height,
            .tile_width = external.tileWidth,
            .tile_height = external.tileHeight,
            .layers = std.ArrayList(pixi.storage.Internal.Layer).init(pixi.state.allocator),
            .sprites = std.ArrayList(pixi.storage.Internal.Sprite).init(pixi.state.allocator),
            .animations = std.ArrayList(pixi.storage.Internal.Animation).init(pixi.state.allocator),
            .dirty = false,
        };

        for (external.layers) |layer| {
            const layer_image_name = try std.fmt.allocPrintZ(pixi.state.allocator, "{s}.png", .{layer.name});
            defer pixi.state.allocator.free(layer_image_name);

            var img_buf: ?*anyopaque = null;
            var img_len: usize = 0;

            _ = zip.zip_entry_open(pixi_file, layer_image_name.ptr);
            _ = zip.zip_entry_read(pixi_file, &img_buf, &img_len);
            defer _ = zip.zip_entry_close(pixi_file);

            if (img_buf) |data| {
                const texture_handle = pixi.state.gctx.createTexture(.{
                    .usage = .{ .texture_binding = true, .copy_dst = true },
                    .size = .{
                        .width = external.width,
                        .height = external.height,
                        .depth_or_array_layers = 1,
                    },
                    .format = zgpu.imageInfoToTextureFormat(4, 1, false),
                });

                const texture_view_handle = pixi.state.gctx.createTextureView(texture_handle, .{});

                var image = try zstbi.Image.initFromData(@ptrCast([*]u8, data)[0..img_len], 4);

                pixi.state.gctx.queue.writeTexture(
                    .{ .texture = pixi.state.gctx.lookupResource(texture_handle).? },
                    .{
                        .bytes_per_row = image.bytes_per_row,
                        .rows_per_image = image.height,
                    },
                    .{ .width = image.width, .height = image.height },
                    u8,
                    image.data,
                );

                try internal.layers.append(.{
                    .name = try pixi.state.allocator.dupeZ(u8, layer.name),
                    .texture_handle = texture_handle,
                    .texture_view_handle = texture_view_handle,
                    .image = image,
                });
            }
        }

        for (external.sprites) |sprite, i| {
            try internal.sprites.append(.{
                .name = try pixi.state.allocator.dupeZ(u8, sprite.name),
                .index = i,
                .origin_x = sprite.origin_x,
                .origin_y = sprite.origin_y,
            });
        }

        for (external.animations) |animation| {
            try internal.animations.append(.{
                .name = try pixi.state.allocator.dupeZ(u8, animation.name),
                .start = animation.start,
                .length = animation.length,
                .fps = animation.fps,
            });
        }

        try pixi.state.open_files.insert(0, internal);
        setActiveFile(0);
        return true;
    }

    pixi.state.allocator.free(path);
    return error.FailedToOpenFile;
}

pub fn setActiveFile(index: usize) void {
    if (index >= pixi.state.open_files.items.len) return;
    pixi.state.open_file_index = index;
}

pub fn getFileIndex(path: [:0]const u8) ?usize {
    for (pixi.state.open_files.items) |file, i| {
        if (std.mem.eql(u8, file.path, path))
            return i;
    }
    return null;
}

pub fn getFile(index: usize) ?*pixi.storage.Internal.Pixi {
    if (index >= pixi.state.open_files.items.len) return null;

    return &pixi.state.open_files.items[index];
}

pub fn closeFile(index: usize) !void {
    pixi.state.open_file_index = 0;
    var file = pixi.state.open_files.swapRemove(index);
    for (file.layers.items) |*layer| {
        pixi.state.gctx.releaseResource(layer.texture_handle);
        pixi.state.gctx.releaseResource(layer.texture_view_handle);
        pixi.state.allocator.free(layer.name);
        layer.image.deinit();
    }
    for (file.sprites.items) |*sprite| {
        pixi.state.allocator.free(sprite.name);
    }
    for (file.animations.items) |*animation| {
        pixi.state.allocator.free(animation.name);
    }
    file.layers.deinit();
    file.sprites.deinit();
    file.animations.deinit();
    pixi.state.allocator.free(file.path);
}

pub fn deinit() void {
    for (pixi.state.open_files.items) |_| {
        try closeFile(0);
    }
    pixi.state.open_files.deinit();
}
