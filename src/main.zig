const std = @import("std");
const builtin = @import("builtin");

const Arena = @import("Arena.zig");
const linux = @import("linux.zig");

pub fn main() !void {
    Thread.ctx = .init();
    
    const arena: *Arena = .init(.default);
    defer arena.release();
    const conn: linux.Connection = try .init(arena);
    log.debug("successfully connected wayland socket :: fd={d}", .{@as(i32, conn.sock)});

    // get_registry()
    {
        // write
        {
            const Obj = struct {
                id: u32,
            };

            const registry: Obj = .{ .id = 2 };
            try conn.write(registry, 1, 1);
        }

        // read
        {
            var event_iter: linux.EventIterator = .init(arena, &conn, 4096);
            try event_iter.load_events();
            while (event_iter.next()) |event| switch (event) {
                .wl_display => |wl_display_ev| {
                    log.debug("wl_display ev :: {any}", .{wl_display_ev});
                },
                .wl_registry => |registry_ev| switch (registry_ev) {
                    .global => |global| {
                        log.debug("global :: {{ .name={d}, .interface={s}, .version={d} }}", .{global.name, global.interface, global.version});
                    },
                    else => {
                        log.debug("unexpected registry event :: {any}", .{registry_ev});
                    },
                },
                else => {
                    log.debug("unexpected event received :: {any}", .{event});
                },
            };
        }
    }
}

const log = std.log.scoped(.app);

// -- General Codebase Types --
const Thread = linux.Thread;

// --- STD LIB OVERRIDES --
fn log_fn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const lvl_text = switch (message_level) {
        .err => "[ERROR] ",
        .warn => "[WARNING] ",
        .info => "[INFO] ",
        .debug => "[DEBUG] ",
    };
    const scope_text = @tagName(scope);
    const log_prefix = if (scope == .default)
        lvl_text ++ ":: "
    else
        lvl_text ++ scope_text ++ " :: ";

    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stderr);
    const writer = bw.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    nosuspend {
        writer.print(log_prefix ++ format ++ "\n", args) catch return;
        bw.flush() catch return;
    }
}

pub const std_options: std.Options = .{
    .logFn = log_fn,
};

