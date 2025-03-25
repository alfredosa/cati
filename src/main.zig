const std = @import("std");
const lib = @import("newzig_lib");
const c = @cImport({
    @cInclude("Imlib2.h");
});

fn load_img(file: [*c]const u8) !c.Imlib_Image {
    const img = c.imlib_load_image_immediately(file);
    if (img == null) {
        std.debug.print("Failed to load image {s}\n", .{file});
        return error.ImageLoadFailed;
    }
    return img;
}

fn detect_kitty_graphics_protocol() !bool {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    // Save terminal settings
    var old_termios: std.c.termios = undefined;
    // can I assing a value so that It can be reused?
    if (std.c.tcgetattr(std.c.STDIN_FILENO, &old_termios) != 0) {
        std.debug.print("failed to set attr STDIN_FILENO on old_termios", .{});
        std.process.exit(1);
    }

    var new_termios = old_termios;
    new_termios.lflag.ECHO = false;
    new_termios.lflag.ICANON = false;
    new_termios.cc[5] = 1;
    new_termios.cc[4] = 0;
    _ = std.c.tcsetattr(std.c.STDIN_FILENO, .NOW, &new_termios);

    const old_flags = std.c.fcntl(std.c.STDIN_FILENO, std.c.F.GETFL, @as(c_int, 0));
    _ = std.c.fcntl(std.c.STDIN_FILENO, std.c.F.SETFL, old_flags | 0x4);

    var discard_buf: [100]u8 = undefined;
    while (stdin.readAll(&discard_buf)) |_| {} else |_| {}

    // Important command to see if kitty Graphics protocol is supported:
    //
    //  See https://sw.kovidgoyal.net/kitty/graphics-protocol/
    //  <ESC>_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA<ESC>\<ESC>[c
    try stdout.writeAll("\x1B_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1B\\");

    // TODO: Is 100 ms good?
    std.time.sleep(100 * std.time.ns_per_ms);

    var buf: [100]u8 = undefined;
    var supports_kitty = false;

    const read_bytes = stdin.readAll(&buf) catch 0;
    if (read_bytes > 0) {
        const response = buf[0..read_bytes];
        if (std.mem.indexOf(u8, response, "\x1B_Gi=31;OK")) |_| {
            supports_kitty = true;
        }
    }

    // Restore terminal settings
    _ = std.c.tcsetattr(std.c.STDIN_FILENO, std.c.TCSA.NOW, &old_termios);
    _ = std.c.fcntl(std.c.STDIN_FILENO, std.c.F.SETFL, old_flags);

    return supports_kitty;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("Memory leak detected");
    }

    const kgp = try detect_kitty_graphics_protocol();
    std.debug.print("Kitty Graphics Protocol is supported: {}\n", .{kgp});

    // Parse command line arguments
    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    // Skip program name
    _ = args_iter.next();

    // Check if we have at least one argument (image path)
    if (args_iter.next()) |image_path| {
        // Use the image path
        std.debug.print("Loading image: {s}\n", .{image_path});

        // Initialize Imlib
        c.imlib_context_set_colormap(0);

        // Load the image
        const img = load_img(image_path) catch {
            std.debug.print("Error loading image\n", .{});
            return;
        };

        // Set the loaded image on the context
        c.imlib_context_set_image(img);

        // Get image dimensions
        const width = c.imlib_image_get_width();
        const height = c.imlib_image_get_height();
        std.debug.print("Image dimensions: {d}x{d}\n", .{ width, height });

        // Free the image
        c.imlib_free_image();
    } else {
        std.debug.print("Usage: newzig <image_path>\n", .{});
        return error.MissingArgument;
    }

    std.debug.print("Processing complete.\n", .{});
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "use other module" {
    try std.testing.expectEqual(@as(i32, 150), lib.add(100, 50));
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
