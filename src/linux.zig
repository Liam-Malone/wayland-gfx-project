const std = @import("std");
const builtin = @import("builtin");

const Arena = @import("Arena.zig");

const Connection = struct {
    sock: posix.socket_t,
    addr: posix.sockaddr.un,

    pub fn write(object: anytype, id: u32, op: u16) !void {
        const T = @TypeOf(object);
        const msg_size: u16 = size: {
            var size: u16 = @sizeOf(Header);
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const field_type: type = switch (@typeInfo(field.type)) {
                    .@"enum" => u32,
                    .@"struct" => |@"struct"| if (@"struct".layout == .@"packed")
                            std.meta.Int(.unsigned, @bitSizeOf(T))
                        else
                            field.type,
                    .optional => |Optional| Optional.child,
                    else => field.type,
                };
                switch (field_type) {
                    i32, u32, f32 => {
                        if (!std.mem.eql(u8, field.name, "fd")) size += @sizeOf(u32);
                    },
                    [:0]const u8 => size += str_write_len(@field(object, field.name)),
                    []const u8 => size += arr_write_len(@field(object, field.name)),
                    else => @compileLog("Unsupported field {s} of type {}", .{ field.name, field.type }),
                }
            }
            break :size size;
        };

        const header: Header = .{
            .id = id,
            .op = op,
            .size = msg_size,
        };

        var msg_buf: [msg_size]u8 = @splat(0);
        // TODO: 
        // - Write object's data into the msg_buf
        // - No fd: Write msg_buf to socket directly 
        // - fd: Write msg_buf to socket through iov 
        if (@hasField(T, "fd")) {
            // control message
        } else {
        }
    }

    fn arr_write_len(arr: []const u8) usize {
        return round_up(@sizeOf(u32) + arr.len, @sizeOf(u32));
    }
    fn str_write_len(str: [:0]const u8) usize {
        return arr_write_len(str[0 .. str.len + 1]);
    }

    fn write_arr(writer: anytype, arr: []const u8) !void {
        const to_write = arr_write_len(arr);
        try writer.writeInt(u32, @intCast(arr.len), endian);
        try writer.writeAll(arr);
        const written = @sizeOf(u32) + arr.len;
        try writer.writeByteNTimes(0, to_write - written);
    }

    fn write_str(writer: anytype, str: [:0]const u8) !void {
        try write_arr(writer, @ptrCast(str[0 .. str.len + 1]));
    }

    fn write_float(writer: anytype, float: f32) !void {
        const val: i32 = @intFromFloat(float * 256);
        try writer.writeInt(i32, val, endian);
    }

    fn write_control_msg(sock: std.posix.socket_t, msg_bytes: []const u8, fd: std.posix.fd_t) !void {
        const control_msg: cmsg(@TypeOf(fd)) = .init(
            std.posix.SOL.SOCKET,
            SCM_RIGHTS,
            fd,
        );

        const iov = [_]std.posix.iovec_const{
            .{
                .base = msg_bytes.ptr,
                .len = msg_bytes.len,
            },
        };

        const cmsg_bytes = std.mem.asBytes(&control_msg);
        const sock_msg: std.posix.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = cmsg_bytes.ptr,
            .controllen = cmsg_bytes.len,
            .flags = 0,
        };

        _ = try std.posix.sendmsg(sock, &sock_msg, 0);
    }

    inline fn round_up(val: anytype, mul: @TypeOf(val)) @TypeOf(val) {
        if (val == 0)
            return 0
        else
            return if (val % mul == 0)
                val
            else
                val + (mul - (val % mul));
    }

    const Header = packed struct (u64) {
        id: u32,
        op: u16,
        size: u16,
    };
};

pub fn connect_wayland(arena: *Arena) !Connection {
    const scratch = Thread.scratch_begin(1, .{arena}).?;
    defer scratch.end();
    const xdg_runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR").?;
    const wayland_display = std.posix.getenv("WAYLAND_DISPLAY").?;

    const sock_path = try std.mem.join(scratch.arena.allocator(), "/", &[_][]const u8{ xdg_runtime_dir, wayland_display });

    const opt_non_block = 0;
    const sockfd = try std.posix.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | opt_non_block,
        0,
    );

    var addr: std.posix.sockaddr.un = addr: {
        var sock_addr: std.posix.sockaddr.un = .{
            .family = std.posix.AF.UNIX,
            .path = undefined,
        };

        if (sock_path.len + 1 > sock_addr.path.len) return error.SocketPathTooLong;

        @memset(&sock_addr.path, 0);
        @memcpy(sock_addr.path[0..sock_path.len], sock_path);
        break :addr sock_addr;
    };

    std.posix.connect(
        sockfd,
        @ptrCast(&addr),
        @as(std.posix.socklen_t, @intCast(@sizeOf(std.posix.sockaddr.un))),
    ) catch |err| {
        log.err("Failed to connect to Wayland Socket with err :: {s}", .{@errorName(err)});
        return err;
    };

    return .{
        .sock = sockfd,
        .addr = addr,
    };
}

pub const Context = struct {
    scratch_arenas: [2]*Arena = undefined,

    pub fn init() Context {
        var result: Context = undefined;
        for (0..result.scratch_arenas.len) |idx| {
            result.scratch_arenas[idx] = .init(.default);
        }

        return result;
    }

    pub fn deinit(ctx: *const Context) void {
        for (ctx.scratch_arenas) |scratch| {
            scratch.release();
        }
    }
};

pub const Thread = struct {
    pub threadlocal var ctx: Context = undefined;
    thread: std.Thread,

    pub fn spawn(config: SpawnConfig, function: anytype, args: anytype) SpawnError!Thread {
        return .{
            .thread = try std.Thread.spawn(config, thread_entry, .{ function, args }),
        };
    }

    pub fn join(thread: *const Thread) void {
        ctx.deinit();
        thread.thread.join();
    }

    pub fn scratch_begin(comptime N: comptime_int, conflicts: [N]*Arena) ?Arena.Temp {
        var result: ?Arena.Temp = null;
        outer: for (ctx.scratch_arenas) |scratch| {
            result = scratch.temp();
            for (conflicts) |conflict| {
                if (scratch == conflict) {
                    result = null;
                    break :outer;
                }
            }
        }

        return result;
    }

    fn thread_entry(function: anytype, args: anytype) void {
        ctx = .init();

        @call(.auto, function, args);
    }

    const SpawnError = std.Thread.SpawnError;
    const SpawnConfig = std.Thread.SpawnConfig;
};

/// Create container type for control messages
pub fn cmsg(comptime T: type) type {
    const msg_len = cmsghdr.msg_len(@sizeOf(T));
    const padded_bit_count = cmsghdr.padding_bits(msg_len, @bitSizeOf(T));

    return packed struct {
        /// Control message header
        header: cmsghdr,
        /// Data we actually want
        data: T,

        /// padding to reach data alignment
        __padding: @Type(.{
            .int = .{
                .bits = padded_bit_count,
                .signedness = .unsigned,
            },
        }) = 0,

        pub fn init(level: i32, @"type": i32, data: T) cmsg_t {
            return .{
                .header = .{
                    .len = msg_len,
                    .level = level,
                    .type = @"type",
                },
                .data = data,
            };
        }

        pub const Size = @sizeOf(cmsg_t);

        const cmsg_t = @This();
    };
}

const CmsgIterator = struct {
    buf: []const u8,
    idx: usize,

    const Iterator = @This();

    pub fn first(iter: *Iterator) ?cmsghdr {
        const result: ?cmsghdr = if (iter.buf[iter.idx..].len > @sizeOf(cmsghdr))
            std.mem.bytesToValue(cmsghdr, iter.buf[iter.idx..][0..@sizeOf(cmsghdr)])
        else
            null;

        return result;
    }

    pub fn next(iter: *Iterator) ?cmsghdr {
        const result: ?cmsghdr = if (iter.buf[iter.idx..].len > @sizeOf(cmsghdr)) hdr: { 
            const hdr = std.mem.bytesToValue(cmsghdr, iter.buf[iter.idx..][0..@sizeOf(cmsghdr)]);
            iter.idx += cmsghdr.__msg_len(&hdr);

            if (iter.idx >= iter.buf.len)
                iter.idx = iter.buf.len - 1;

            break :hdr hdr;
        } else
            null;

        return result;
    }

    pub fn reset(iter: *Iterator) void {
        iter.idx = 0;
    }
};

pub const cmsghdr = packed struct {
    /// Data byte count, including header
    len: usize,
    /// Originating protocol
    level: i32,
    /// Protocol-specific type
    type: i32,

    pub fn iter(buf: []const u8) CmsgIterator {
        return .{
            .buf = buf,
            .idx = 0,
        };
    }

    pub fn data(ptr: *const cmsghdr, comptime T: type) *const T {
        const buf: [*]const u8 = @ptrCast(@alignCast(ptr));

        return @ptrCast(@alignCast(buf[Size..][0..@sizeOf(T)].ptr));
    }

    /// Calculate length of control message given data of length `len`
    ///
    /// Port of musl libc's CMSG_LEN macro
    ///
    /// Macro Definition:
    /// #define CMSG_LEN(len)   (CMSG_ALIGN (sizeof (struct cmsghdr)) + (len))
    pub inline fn msg_len(len: usize) usize {
        return msg_align(cmsghdr.Size + len);
    }

    pub inline fn __msg_len(msg: *const cmsghdr) usize {
        return ((msg.len + @sizeOf(c_ulong) - 1) & ~@as(usize, (@sizeOf(c_ulong) - 1)));
    }

    /// Get the number of bits needed to pad out the message
    pub inline fn padding_bits(len: usize, data_t_size: usize) usize {
        return (8 * len) - (@bitSizeOf(cmsghdr) + data_t_size);
    }

    /// Calculate alignment of control message of length `len` to cmsghdr size
    ///
    /// Port of musl libc's CMSG_ALIGN macro
    ///
    /// Macro Definition:
    /// #define CMSG_ALIGN(len) (((len) + sizeof (size_t) - 1) & (size_t) ~(sizeof (size_t) - 1))
    inline fn msg_align(len: usize) usize {
        return (((len) + @sizeOf(size_t) - 1) & ~@as(usize, (@sizeOf(size_t) - 1)));
    }

    const size_t = usize;
    const Size = @sizeOf(@This());
};


const SCM_RIGHTS = 0x01;
const SCM_CREDENTIALS = 0x02;
const log = std.log.scoped(.linux);

// stdlib namespaces/constants
const posix = std.posix;
const endian = builtin.cpu.arch.endian();
