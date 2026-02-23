//! Stream implements a termio backend that uses external function pointers
//! for I/O instead of a local PTY subprocess. This is designed for iOS where
//! fork/exec is prohibited and terminal I/O goes over SSH.
//!
//! The host (Swift) provides:
//!   - write_fn: called when the terminal produces output (user keystrokes)
//!   - resize_fn: called when the terminal size changes
//!
//! The host feeds data into the terminal via ghostty_surface_write_output().
const Stream = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

const log = std.log.scoped(.io_stream);

/// The write callback. Called when the terminal wants to write data
/// (e.g. encoded keystrokes) that should be sent to the remote host.
write_fn: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,

/// The resize callback. Called when the terminal size changes.
/// The host should send an SSH window-change request.
resize_fn: ?*const fn (?*anyopaque, u16, u16, u16, u16) callconv(.c) void,

/// Opaque userdata passed to the callbacks.
userdata: ?*anyopaque,

pub fn init(_: Allocator, cfg: Config) !Stream {
    return .{
        .write_fn = cfg.write_fn,
        .resize_fn = cfg.resize_fn,
        .userdata = cfg.userdata,
    };
}

pub fn deinit(self: *Stream) void {
    _ = self;
}

/// Called before termio begins to set up initial terminal state.
pub fn initTerminal(self: *Stream, t: *terminal.Terminal) void {
    // Set initial size on the terminal (no PTY to resize).
    self.resize(.{
        .columns = t.cols,
        .rows = t.rows,
    }, .{
        .width = t.width_px,
        .height = t.height_px,
    }) catch {};
}

pub fn threadEnter(
    self: *Stream,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;

    // Initialize our thread-local data
    td.backend = .{ .stream = .{} };
}

pub fn threadExit(self: *Stream, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
    // No threads or file descriptors to clean up.
}

pub fn focusGained(
    self: *Stream,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
    // No termios timer or process watcher needed.
}

pub fn resize(
    self: *Stream,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    if (self.resize_fn) |resize_fn| {
        resize_fn(
            self.userdata,
            grid_size.columns,
            grid_size.rows,
            @intCast(@min(screen_size.width, std.math.maxInt(u16))),
            @intCast(@min(screen_size.height, std.math.maxInt(u16))),
        );
    }
}

/// Queue a write to the remote host. This is called when the terminal
/// produces output bytes (e.g. from encoded key events).
pub fn queueWrite(
    self: *Stream,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    _ = td;

    if (!linefeed) {
        // Fast path: send data directly via callback.
        self.write_fn(self.userdata, data.ptr, data.len);
        return;
    }

    // Slow path: need to convert \r to \r\n.
    // Use a stack buffer for small writes, which covers most cases.
    var buf: [256]u8 = undefined;
    var buf_i: usize = 0;
    var i: usize = 0;

    while (i < data.len) {
        const ch = data[i];
        i += 1;

        if (ch != '\r') {
            buf[buf_i] = ch;
            buf_i += 1;
        } else {
            buf[buf_i] = '\r';
            buf[buf_i + 1] = '\n';
            buf_i += 2;
        }

        // Flush when buffer is nearly full.
        if (buf_i >= buf.len - 1) {
            self.write_fn(self.userdata, &buf, buf_i);
            buf_i = 0;
        }
    }

    // Flush remaining.
    if (buf_i > 0) {
        self.write_fn(self.userdata, &buf, buf_i);
    }
}

pub fn childExitedAbnormally(
    self: *Stream,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
    // Stream backend has no child process.
}

/// Thread-local data for the Stream backend.
/// Minimal — no PTY, no read thread, no process watcher.
pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

/// Configuration for creating a Stream backend.
pub const Config = struct {
    /// Callback invoked when the terminal produces output bytes.
    write_fn: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,

    /// Callback invoked when the terminal size changes.
    resize_fn: ?*const fn (?*anyopaque, u16, u16, u16, u16) callconv(.c) void = null,

    /// Opaque userdata passed to both callbacks.
    userdata: ?*anyopaque = null,
};
