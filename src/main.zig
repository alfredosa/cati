const std = @import("std");
const lib = @import("newzig_lib");
const c = @cImport({
    @cInclude("Imlib2.h");
    @cInclude("fcntl.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
});

fn load_img(file: [*c]const u8) !c.Imlib_Image {
    const img = c.imlib_load_image_immediately(file);
    if (img == null) {
        std.debug.print("Failed to load image {s}\n", .{file});
        return error.ImageLoadFailed;
    }
    return img;
}

const size = struct { x: c_int, y: c_int };

fn get_terminal_size() !c.winsize {
    // Find out and return the number of columns in the terminal
    // int terminal_width() {
    // int cols = 80
    // #ifdef TIOCGSIZE
    // struct ttysize ts;
    // ioctl(STDIN_FILENO, TIOCGSIZE, &ts);
    // cols = ts.ts_cols;
    // #elif defined(TIOCGWINSZ)
    // struct winsize ts;
    // ioctl(STDIN_FILENO, TIOCGWINSZ, &ts);
    // cols = ts.ws_col;
    // #endif /* TIOCGSIZE */
    // return cols;
    // }
    var w: c.winsize = undefined;
    const res = c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &w);

    if (res == -1) {
        return error.UnableToReadWinzise;
    }

    std.debug.print("cols {}, rows {}\n", .{ w.ws_col, w.ws_row });
    return w;
}

fn print_image() !void {}

fn detect_kitty_graphics_protocol() !bool {
    var old_termios: std.c.termios = undefined;
    var buf: [256]u8 = undefined;
    var supports_kitty = false;

    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    // Save terminal settings
    // can I assing a value so that It can be reused?
    if (std.c.tcgetattr(std.c.STDIN_FILENO, &old_termios) != 0) {
        std.debug.print("failed to getattr STDIN_FILENO on old_termios", .{});
        return error.TCGetAttributeError;
    }

    // Make a copy of the old termios with flags, and modify them.
    // We set new termios with minor timeouts and changes.
    var new_termios = old_termios;
    new_termios.lflag.ECHO = false;
    new_termios.lflag.ICANON = false;
    new_termios.cc[c.VTIME] = 1;
    new_termios.cc[c.VMIN] = 0;

    // Change the current terminal with the modified terminal.
    if (std.c.tcsetattr(std.c.STDIN_FILENO, .NOW, &new_termios) != 0) {
        std.debug.print("failed to setattr STDIN_FILENO on old_termios", .{});
        return error.TCSetAttributeError;
    }

    // Get the old flags. so that we can set the NONBLOCK flag
    const old_flags = std.c.fcntl(std.c.STDIN_FILENO, std.c.F.GETFL, @as(c_int, 0));
    // NOTE: I can't use the provided std.c.O :( so I need ot use C directly.
    if (std.c.fcntl(std.c.STDIN_FILENO, std.c.F.SETFL, old_flags | c.O_NONBLOCK) != 0) {
        std.debug.print("SetFlags with fcntl failed", .{});
        return error.FCNTLErrror;
    }

    // Important command to see if kitty Graphics protocol is supported:
    //
    //  See https://sw.kovidgoyal.net/kitty/graphics-protocol/
    //  <ESC>_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA<ESC>\<ESC>[c
    try stdout.writeAll("\x1B_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1B\\");

    const start_time = std.time.milliTimestamp();
    const timeout_ms: i64 = 500;
    var total_read: usize = 0;

    while (std.time.milliTimestamp() - start_time < timeout_ms) {
        const read_result = stdin.read(buf[total_read..]);

        if (read_result) |b| {
            // Several edge cases.
            if (b == 0) {
                // b has no data so let's continue
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            total_read += b;
            std.debug.print("Read {d} bytes. Raw data: ", .{b});
            for (buf[total_read - b .. total_read]) |byte| {
                std.debug.print("{x:0>2} ", .{byte});
            }
            std.debug.print("\n", .{});

            var found_marker = false;
            var i: usize = 0;

            while (i < total_read - 3) : (i += 1) {
                // Check for _Gi pattern
                if (buf[i] == '_' and buf[i + 1] == 'G' and buf[i + 2] == 'i') {
                    supports_kitty = true;
                    found_marker = true;
                    break;
                }
            }

            if (supports_kitty) {
                break;
            }
        } else |err| {
            if (err == error.WouldBlock) {
                std.debug.print("currently retrying as input is blocked\n", .{});
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            } else {
                return err;
            }
        }
    }

    if (supports_kitty) {
        std.debug.print("Kitty terminal detected\n", .{});
    } else {
        std.debug.print("No Kitty terminal detected\n", .{});
    }

    if (total_read > 0) {
        std.debug.print("Response from termios: {s}\n", .{buf[0..total_read]});
    }

    while (true) {
        var drain_buf: [256]u8 = undefined;
        const drain_result = stdin.read(&drain_buf) catch |err| {
            if (err == error.WouldBlock) {
                break;
            } else {
                break;
            }
        };

        if (drain_result == 0) {
            // Need a small sleep here to make sure we really got everything
            std.time.sleep(20 * std.time.ns_per_ms);
            // Try one more time after sleep
            const final_check = stdin.read(&drain_buf) catch 0;
            if (final_check == 0) {
                break;
            }
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

    // Parse command line arguments
    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    const kgp = try detect_kitty_graphics_protocol();
    std.debug.print("Kitty Graphics Protocol is supported: {}\n", .{kgp});
    if (!kgp) {
        std.debug.print("ASCII printing will be enabled", .{});
    }

    // NOTE: For now I guess don't care. We neeed to resize later
    _ = try get_terminal_size();

    // Skip program name
    _ = args_iter.next();

    // Check if we have at least one argument (image path)
    if (args_iter.next()) |image_path| {
        // Use the image path
        std.debug.print("Loading image: {s}\n", .{image_path});
        c.imlib_context_set_colormap(0);

        // Load the image
        const img = load_img(image_path) catch {
            std.debug.print("Error loading image\n", .{});
            return error.UnableToLoadImage;
        };
        defer c.imlib_free_image();

        c.imlib_context_set_image(img);

        // Get image dimensions
        const width = c.imlib_image_get_width();
        const height = c.imlib_image_get_height();
        std.debug.print("Image dimensions: {d}x{d}\n", .{ width, height });

        if (!kgp) {
            return;
        }
        // for (0..width) |x| {
        //     for (0..height) |y| {
        //
        //         // draw pixel
        //     }
        // }
    } else {
        std.debug.print("Usage: newzig <image_path>\n", .{});
        return error.MissingArgument;
    }

    std.debug.print("Processing complete.\n", .{});
}

// print_image requires that c.imlib_context_set_image(img) was called and it's part of the context.

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
