const std = @import("std");
const builtin = @import("builtin");

const Arena = @import("Arena.zig");
const linux = @import("linux.zig");

const Header = packed struct {
    id: u32,
    op: u16,
    size: u16,
};

pub fn main() !void {
    Thread.ctx = .init();
    
    const arena: *Arena = .init(.default);
    defer arena.release();
    const conn: linux.Connection = try .init(arena);
    log.debug("successfully connected wayland socket :: fd={d}", .{@as(i32, conn.sock)});

    var buf: [2048]u8 = undefined;
    @memset(&buf, 0);

    // get_registry()
    {
        // write
        {
            // Manual Display.get_registry write
            // {
            //     const header: Header = .{
            //         .id = 1,
            //         .op = 1,
            //         .size = @sizeOf(Header) + @sizeOf(u32),
            //     };
            //     var write_buf: [@sizeOf(Header) + @sizeOf(u32)]u8 = @splat(0);
            //     const registry_id: u32 = 2;

            //     @memcpy(write_buf[0..@sizeOf(Header)], std.mem.asBytes(&header));
            //     @memcpy(write_buf[@sizeOf(Header)..], std.mem.asBytes(&registry_id));


            //     const bytes_written = std.posix.write(conn.sock, &write_buf) catch |err| {
            //         log.err("Write failed with err :: {s}", .{@errorName(err)});
            //         return err;
            //     };

            //     log.debug("Successfully wrote {d} bytes to socket", .{bytes_written});
            // }

            // Abstracted Display.get_registry
            {
                const Obj = struct {
                    id: u32,
                };

                const registry: Obj = .{ .id = 2 };
                try conn.write(registry, 1, 1);
            }
        }

        // read
        {
            var cmsg_buf: [@sizeOf(linux.cmsghdr) * 10]u8 = undefined;

            var iov = [_]std.posix.iovec{
                .{
                    .base = &buf,
                    .len = buf.len,
                },
            };

            var message: std.posix.msghdr = .{
                .name = null,
                .namelen = 0,
                .iov = &iov,
                .iovlen = @intCast(iov.len),
                .control = &cmsg_buf,
                .controllen = cmsg_buf.len,
                .flags = 0,
            };

            const rc = std.os.linux.recvmsg(conn.sock,
                &message,
                std.os.linux.MSG.WAITALL,
            );
            if (rc > buf.len) {
                const err = std.posix.errno(rc);
                log.debug("rc :: {d}", .{@as(isize, @bitCast(rc))});
                log.err("Socket read failed with err :: {s}", .{@tagName(err)});
                return error.SocketReadFailed;
            } else {
                log.debug("Received {d} bytes from socket", .{rc});
            }
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

