const std = @import("std");
const builtin = @import("builtin");

const Arena = @import("Arena.zig");

// BEGIN Wayland
const protocols = @import("generated/protocols.zig");

/// General wayland connection.
/// This namespace is also home to Wire event parsing
pub const Connection = struct {
    sock: posix.socket_t,
    addr: posix.sockaddr.un,
    registry: Registry,

    pub fn init(arena: *Arena) !Connection {
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
            .registry = .init(arena, .{ .id = 1 }),
        };
    }
    pub fn parse_wire_ev(comptime T: type, data: []const u8) !T {
        var event_result: T = undefined;
        var data_iter: EventDataIter = .{ .buf = data };

        // File descriptor left undefined here, to be added in by generalized
        // event processing code.
        if (@hasField(T, "fd")) {
            inline for (std.meta.fields(T)) |field| {
                if (!std.mem.eql(u8, "fd", field.name))
                    @field(event_result, field.name) = switch (field.type) {
                        u32 => try data_iter.get_u32(),
                        i32 => try data_iter.get_i32(),
                        f32 => try data_iter.get_f32(),
                        [:0]const u8 => try data_iter.get_string(),
                        []const u8 => try data_iter.get_arr(),
                        else => parse: {
                            switch (@typeInfo(field.type)) {
                                .@"enum" => break :parse @enumFromInt(try data_iter.get_u32()),
                                .@"struct" => |@"struct"| if (@"struct".layout == .@"packed") {
                                    break :parse @bitCast(try data_iter.get_u32());
                                },
                                else => @compileLog("Data Parse Not Implemented for field {s} of type {}", .{ field.name, field.type }),
                            }
                        },
                    };
            }
        } else {
            inline for (std.meta.fields(T)) |field| {
                @field(event_result, field.name) = switch (field.type) {
                    u32 => try data_iter.get_u32(),
                    i32 => try data_iter.get_i32(),
                    f32 => try data_iter.get_f32(),
                    [:0]const u8 => try data_iter.get_string(),
                    []const u8 => try data_iter.get_arr(),
                    else => parse: {
                        switch (@typeInfo(field.type)) {
                            .@"enum" => break :parse @enumFromInt(try data_iter.get_u32()),
                            .@"struct" => |@"struct"| if (@"struct".layout == .@"packed") {
                                break :parse @bitCast(try data_iter.get_u32());
                            },
                            else => @compileLog("Data Parse Not Implemented for field {s} of type {}", .{ field.name, field.type }),
                        }
                    },
                };
            }
        }

        return event_result;
    }

    pub fn write(
        noalias conn: *const Connection,
        object: anytype,
        id: u32,
        op: u16,
    ) !void {
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

        const scratch = Thread.scratch_begin(0, .{}).?;
        defer scratch.end();
        var msg_buf = scratch.arena.push(u8, msg_size);
        @memcpy(msg_buf[0..@sizeOf(Header)], std.mem.asBytes(&header));
        // TODO:
        // - Write object's data into the msg_buf
        // - No fd: Write msg_buf to socket directly
        // - fd: Write msg_buf to socket through iov
        if (@hasField(T, "fd")) {
            // control message
            var idx: usize = @sizeOf(Header);
            var fd: std.posix.fd_t = undefined;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const val = @field(object, field.name);
                if (std.mem.eql(u8, field.name, "fd")) {
                    fd = val;
                } else {
                    const field_as_bytes = if (@typeInfo(field.type) == .optional)
                        std.mem.asBytes(&(val.?))
                    else
                        std.mem.asBytes(&val);
                    @memcpy(msg_buf[idx .. idx + field_as_bytes.len], field_as_bytes);
                    idx += field_as_bytes.len;
                }
            }

            try write_control_msg(conn.sock, &msg_buf, fd);
        } else {
            var idx: usize = @sizeOf(Header);
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const field_type: type = switch (@typeInfo(field.type)) {
                    .@"enum" => u32,
                    .@"struct" => |@"struct"| if (@"struct".layout == .@"packed") u32 else field.type,
                    .optional => |Optional| Optional.child,
                    else => field.type,
                };

                const field_val = @field(object, field.name);
                const msg_val = switch (@typeInfo(field.type)) {
                    .@"enum" => @intFromEnum(field_val),
                    .@"struct" => @as(u32, @bitCast(field_val)),
                    .optional => field_val.?,
                    else => field_val,
                };
                switch (field_type) {
                    f32 => {
                        write_float(msg_buf[idx..], msg_val);
                        idx += @sizeOf(u32);
                    },
                    u32 => {
                        write_int(msg_buf[idx..], msg_val);
                        idx += @sizeOf(u32);
                    },
                    i32 => {
                        write_int(msg_buf[idx..], @bitCast(msg_val));
                        idx += @sizeOf(u32);
                    },
                    [:0]const u8 => {
                        write_str(msg_buf[idx..], msg_val);
                        idx += str_write_len(msg_val);
                    },
                    []const u8 => {
                        write_arr(msg_buf[idx..], msg_val);
                        idx += arr_write_len(msg_val);
                    },
                    void => {}, // skip -- should be cmsg
                    else => @compileLog("Unsupported field {s} of type {}", .{ field.name, field.type }),
                }
            }
            const bytes_written = std.posix.write(conn.sock, msg_buf) catch |err| {
                log.err("Write failed with err :: {s}", .{@errorName(err)});
                return err;
            };

            log.debug("Successfully wrote {d} bytes to socket", .{bytes_written});
        }
    }

    fn arr_write_len(arr: []const u8) usize {
        return round_up(@sizeOf(u32) + arr.len, @sizeOf(u32));
    }
    fn str_write_len(str: [:0]const u8) usize {
        return arr_write_len(str[0 .. str.len + 1]);
    }

    fn write_arr(buf: []u8, arr: []const u8) void {
        const to_write = arr_write_len(arr);
        @memcpy(buf[0..@sizeOf(u32)], std.mem.toBytes(&to_write));

        @memcpy(buf[@sizeOf(u32)..], arr);
        const written = @sizeOf(u32) + arr.len;
        const padding_needed = to_write - written;
        @memset(buf[written..][0..padding_needed], 0);
    }

    fn write_str(buf: []u8, str: [:0]const u8) void {
        write_arr(buf, @ptrCast(str[0 .. str.len + 1]));
    }

    fn write_float(buf: []u8, float: f32) void {
        const val: i32 = @intFromFloat(float * 256);
        write_int(buf, @bitCast(val));
    }

    fn write_int(buf: []u8, int: u32) void {
        @memcpy(buf[0..@sizeOf(u32)], std.mem.asBytes(&int));
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

        const bytes_written = try std.posix.sendmsg(sock, &sock_msg, 0);
        log.debug("Control Message :: Wrote {d} bytes", .{bytes_written});
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

    const EventDataIter = struct {
        buf: []const u8,

        pub inline fn get_f32(iter: *EventDataIter) !f32 {
            if (iter.buf.len < @sizeOf(u32)) {
                return error.InvalidLength;
            }

            const val = std.mem.bytesToValue(i32, iter.buf[0..@sizeOf(u32)]);
            const float_val: f32 = @floatFromInt(val);
            iter.consume(@sizeOf(u32));
            return (float_val / 256);
        }

        pub inline fn get_u32(iter: *EventDataIter) !u32 {
            if (iter.buf.len < @sizeOf(u32)) {
                return error.InvalidLength;
            }

            const val = std.mem.bytesToValue(u32, iter.buf[0..@sizeOf(u32)]);
            iter.consume(@sizeOf(u32));
            return val;
        }

        pub inline fn get_i32(iter: *EventDataIter) !i32 {
            return @intCast(try iter.get_u32());
        }

        pub inline fn get_arr(iter: *EventDataIter) ![]const u8 {
            if (iter.buf.len < @sizeOf(u32)) {
                return error.NoLengthPrefix;
            }

            const msg_len = std.mem.bytesToValue(u32, iter.buf[0..@sizeOf(u32)]);
            const rounded_len = round_up(msg_len, @sizeOf(u32));
            const consume_len = rounded_len + @sizeOf(u32);

            if (consume_len > iter.buf.len) {
                return error.BufferTooShort;
            }

            defer iter.consume(consume_len);
            const arr = iter.buf[@sizeOf(u32)..][0..msg_len];
            return arr;
        }

        pub inline fn get_string(iter: *EventDataIter) ![:0]const u8 {
            const arr = try iter.get_arr();
            return @ptrCast(arr[0..(arr.len - 1) :0]);
        }

        inline fn consume(iter: *EventDataIter, len: usize) void {
            if (iter.buf.len == len) {
                iter.buf = &.{};
            } else {
                iter.buf = iter.buf[len..];
            }
        }
    };

    pub const WireEvent = struct {
        header: Header,
        data: []const u8,
    };

    const Header = packed struct(u64) {
        id: u32,
        op: u16,
        size: u16,
    };

    const log = std.log.scoped(.Wayland);
};

const Registry = struct {
    cur_idx: u32,
    objects: []Object,
    parse_fns: []?EventParseFn,
    free_list: IndexFreeQueue = .{},

    pub fn init(arena: *Arena, display: protocols.wayland.Display) Registry {
        const objects = arena.push(Object, 256);
        const parse_fns = arena.push(?EventParseFn, 256);
        for (objects) |*obj| {
            obj.* = .{ .nil = {} };
        }
        objects[1] = .{ .wl_display = display };
        objects[2] = .{ .wl_registry = .{ .id = 2 } };

        parse_fns[1] = @unionInit(EventParseFn, "wl_display", protocols.wayland.Display.Event.parse);
        parse_fns[2] = @unionInit(EventParseFn, "wl_registry", protocols.wayland.Registry.Event.parse);

        return .{
            .cur_idx = 2,
            .objects = objects,
            .parse_fns = parse_fns,
        };
    }

    pub fn register(self: *Registry, comptime T: type) !T {
        const idx = if (self.free_list.next()) |freed_id|
            freed_id
        else blk: {
            defer self.cur_idx += 1;
            break :blk self.cur_idx;
        };

        self.objects[idx] = @unionInit(Object, @field(T, "Name"), .{ .id = idx });
        return .{
            .id = idx,
        };
    }

    pub fn get_parse_fn(self: *const Registry, idx: u32) ?EventParseFn {
        return self.parse_fns[idx];
    }

    const IndexFreeQueue = struct {
        buf: [QueueSize]u32 = @splat(0),
        read: usize = 0,
        write: usize = 0,

        const QueueSize = 32;

        pub fn push(q: *IndexFreeQueue, idx: u32) void {
            q.buf[(q.write % QueueSize)] = idx;
            q.write += 1;
        }

        pub fn next(q: *IndexFreeQueue) ?u32 {
            const res = blk: {
                if (q.buf[(q.read % QueueSize)] == 0) {
                    break :blk null;
                } else {
                    defer q.read += 1;
                    defer q.buf[(q.read % QueueSize)] = 0;
                    break :blk q.buf[(q.read % QueueSize)];
                }
            };
            return res;
        }
    };

    // Meta-Programmed Types
    const ObjectTag = blk: {
        const meta = std.meta;
        const enum_len = len_blk: {
            var decl_count: usize = 0;
            for (std.meta.declarations(protocols)) |protocol_decl| {
                const protocol = @field(protocols, protocol_decl.name);
                const interfaces = meta.fields(meta.DeclEnum(protocol));
                decl_count += interfaces.len;
            }
            break :len_blk decl_count;
        };

        var idx: u32 = 1;
        var fields: [enum_len + 1]std.builtin.Type.EnumField = undefined;

        fields[0] = .{
            .name = "nil",
            .value = 0,
        };

        for (std.meta.declarations(protocols)) |protocol_decl| {
            const protocol = @field(protocols, protocol_decl.name);

            for (std.meta.declarations(protocol)) |interface_decl| {
                const interface = @field(protocol, interface_decl.name);
                fields[idx] = .{
                    .name = @field(interface, "Name") ++ "",
                    .value = idx,
                };
                idx += 1;
            }
        }

        const T = @Type(.{
            .@"enum" = .{
                .tag_type = std.math.IntFittingRange(0, enum_len + 1),
                .fields = &fields,
                .decls = &.{},
                .is_exhaustive = true,
            },
        });
        break :blk T;
    };

    pub const Object = blk: {
        const meta = std.meta;
        const union_len = len_blk: {
            var decl_count: usize = 0;
            for (std.meta.declarations(protocols)) |protocol_decl| {
                const protocol = @field(protocols, protocol_decl.name);
                const interfaces = meta.fields(meta.DeclEnum(protocol));
                decl_count += interfaces.len;
            }
            break :len_blk decl_count;
        };

        var idx: u32 = 1;
        var fields: [union_len + 1]std.builtin.Type.UnionField = undefined;

        fields[0] = .{
            .name = "nil",
            .type = void,
            .alignment = @alignOf(void),
        };

        for (std.meta.declarations(protocols)) |protocol_decl| {
            const protocol = @field(protocols, protocol_decl.name);

            for (@typeInfo(protocol).@"struct".decls) |interface_decl| {
                const interface = @field(protocol, interface_decl.name);
                fields[idx] = .{
                    .name = @field(interface, "Name") ++ "",
                    .type = interface,
                    .alignment = @alignOf(interface),
                };
                idx += 1;
            }
        }

        const T = @Type(.{
            .@"union" = .{
                .layout = .auto,
                .tag_type = ObjectTag,
                .fields = &fields,
                .decls = &.{},
            },
        });
        break :blk T;
    };
};

pub const EventIterator = struct {
    conn: *const Connection,
    buf: []u8,
    write_idx: u32,
    ev_queue: EvQueue,
    fd_queue: FdQueue,

    pub fn init(arena: *Arena, conn: *const Connection, size: u32) EventIterator {
        return .{
            .conn = conn,
            .buf = arena.push(u8, size),
            .write_idx = 0,
            .ev_queue = .{},
            .fd_queue = .{},
        };
    }

    pub fn next(iter: *EventIterator) ?Event {
        return iter.ev_queue.next();
    }

    pub fn load_events(iter: *EventIterator) !void {
        var cmsg_buf: [@sizeOf(cmsghdr) * 10]u8 = undefined;

        var iov = [_]std.posix.iovec{
            .{
                .base = iter.buf[iter.write_idx..].ptr,
                .len = iter.buf[iter.write_idx..].len,
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

        const rc = std.os.linux.recvmsg(
            iter.conn.sock,
            &message,
            0,
        );
        if (rc > iter.buf.len) {
            const err = std.posix.errno(rc);
            log.debug("rc :: {d}", .{@as(isize, @bitCast(rc))});
            log.err("Socket read failed with err :: {s}", .{@tagName(err)});
            return error.SocketReadFailed;
        } else {
            const bytes_read: u32 = @intCast(rc);
            iter.write_idx += bytes_read;
            // check for file descriptors
            {
                log.debug("message controllen={d}", .{message.controllen});
                var cmsg_iter = cmsghdr.iter(cmsg_buf[0..message.controllen]);
                while (cmsg_iter.next()) |cmsg_header| {
                    if (cmsg_header.type == std.posix.SOL.SOCKET and cmsg_header.level == SCM_RIGHTS) {
                        iter.fd_queue.push(cmsg_header.data(std.posix.fd_t).*);
                        log.debug("Found file descriptor of value :: {d}", .{cmsg_header.data(std.posix.fd_t).*});
                    }
                }
            }

            // standard event processing
            {
                var read_idx: u32 = 0;
                while (read_idx < iter.write_idx) {
                    log.debug("START :: read_idx={d}, write_idx={d}", .{read_idx, iter.write_idx});
                    defer log.debug("END :: read_idx={d}, write_idx={d}", .{read_idx, iter.write_idx});
                    log.debug("reading event", .{});
                    const header = std.mem.bytesToValue(Connection.Header, iter.buf[read_idx..][0..@sizeOf(Connection.Header)]);
                    log.debug("Header :: {{ .id = {d}, .op = {d}, .size = {d} }}", .{
                        header.id,
                        header.op,
                        header.size,
                    });

                    const msg_size = header.size;
                    const data_end = read_idx + msg_size;

                    if (data_end >= iter.write_idx) {
                        break;
                    }

                    const msg_data = iter.buf[read_idx..][@sizeOf(Connection.Header)..msg_size];
                    defer read_idx += msg_size;

                    const parse_fn = iter.conn.registry.get_parse_fn(header.id).?;
                    const active_tag = std.meta.activeTag(parse_fn);
                    const event: Event = ev: {
                        inline for (@typeInfo(@TypeOf(parse_fn)).@"union".fields) |field| {
                            if (std.mem.eql(u8, field.name, @tagName(active_tag))) {
                                break :ev @unionInit(
                                    Event,
                                    field.name,
                                    try @field(parse_fn, field.name)(header.op, msg_data),
                                );
                            }
                        }
                        unreachable;
                    };
                    if (std.mem.eql(u8, @tagName(active_tag), "wl_registry")) {
                        log.debug("interface :: {s}", .{event.wl_registry.global.interface});
                    }
                    iter.ev_queue.push(event);
                }
            }
            log.debug("Received {d} bytes from socket", .{rc});
        }
    }

    const EvQueue = struct {
        data: [Size]Event = undefined,
        read: usize = 0,
        write: usize = 0,

        pub fn push(noalias queue: *EvQueue, event: Event) void {
            const write_idx = queue.write % queue.data.len;
            queue.data[write_idx] = event;
            queue.write += 1;
        }

        pub fn next(noalias queue: *EvQueue) ?Event {
            if (queue.read != queue.write) {
                defer queue.read += 1;

                const read_idx = queue.read % queue.data.len;
                return queue.data[read_idx];
            } else {
                return null;
            }
        }

        pub const Size = 128;
    };

    const FdQueue = struct {
        data: [Size]std.posix.fd_t = @splat(0),
        read: usize = 0,
        write: usize = 0,

        pub fn push(noalias queue: *FdQueue, fd: std.posix.fd_t) void {
            const write_idx = queue.write % queue.data.len;
            queue.data[write_idx] = fd;
            queue.write += 1;
        }

        pub fn next(noalias queue: *FdQueue) ?std.posix.fd_t {
            if (queue.read != queue.write) {
                defer queue.read += 1;

                const read_idx = queue.read % queue.data.len;
                return queue.data[read_idx];
            } else {
                return null;
            }
        }

        pub const Size = 64;
    };

    const log = std.log.scoped(.Event);
};

pub const ObjectEventTag = blk: {
    const enum_len = len_blk: {
        var decl_count: usize = 0;
        for (@typeInfo(protocols).@"struct".decls) |protocol_decl| {
            const protocol = @field(protocols, protocol_decl.name);
            for (@typeInfo(protocol).@"struct".decls) |interface_decl| {
                const wl_interface = @field(protocol, interface_decl.name);
                if (@hasDecl(wl_interface, "Event")) {
                    decl_count += 1;
                }
            }
        }
        break :len_blk decl_count;
    };

    var idx: u32 = 0;
    var fields: [enum_len]std.builtin.Type.EnumField = undefined;

    for (std.meta.declarations(protocols)) |protocol_decl| {
        const protocol = @field(protocols, protocol_decl.name);

        for (std.meta.declarations(protocol)) |interface_decl| {
            const wl_interface = @field(protocol, interface_decl.name);
            if (@hasDecl(wl_interface, "Event")) {
                fields[idx] = .{
                    .name = @field(wl_interface, "Name") ++ "",
                    .value = idx,
                };
                idx += 1;
            }
        }
    }

    const T = @Type(.{
        .@"enum" = .{
            .tag_type = std.math.IntFittingRange(0, enum_len),
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
    break :blk T;
};

const EventParseFn = blk: {
    const union_len = len_blk: {
        var decl_count: usize = 0;
        for (std.meta.declarations(protocols)) |protocol_decl| {
            const protocol = @field(protocols, protocol_decl.name);

            for (@typeInfo(protocol).@"struct".decls) |interface_decl| {
                const wl_interface = @field(protocol, interface_decl.name);
                if (@hasDecl(wl_interface, "Event")) {
                    decl_count += 1;
                }
            }
        }
        break :len_blk decl_count;
    };

    var idx: u32 = 0;
    var fields: [union_len]std.builtin.Type.UnionField = undefined;

    for (std.meta.declarations(protocols)) |protocol_decl| {
        const protocol = @field(protocols, protocol_decl.name);

        for (@typeInfo(protocol).@"struct".decls) |interface_decl| {
            const wl_interface = @field(protocol, interface_decl.name);

            if (@hasDecl(wl_interface, "Event")) {
                const event_t = @field(wl_interface, "Event");
                fields[idx] = .{
                    .name = @field(wl_interface, "Name") ++ "",
                    .type = *const @TypeOf(@field(event_t, "parse")),
                    .alignment = @alignOf(*const @TypeOf(@field(event_t, "parse"))),
                };
                idx += 1;
            }
        }
    }

    const T = @Type(.{
        .@"union" = .{
            .layout = .auto,
            .tag_type = ObjectEventTag,
            .fields = &fields,
            .decls = &.{},
        },
    });
    break :blk T;
};

const Event = blk: {
    const union_len = len_blk: {
        var decl_count: usize = 0;
        for (std.meta.declarations(protocols)) |protocol_decl| {
            const protocol = @field(protocols, protocol_decl.name);

            for (@typeInfo(protocol).@"struct".decls) |interface_decl| {
                const wl_interface = @field(protocol, interface_decl.name);
                if (@hasDecl(wl_interface, "Event")) {
                    decl_count += 1;
                }
            }
        }
        break :len_blk decl_count;
    };

    var idx: u32 = 0;
    var fields: [union_len]std.builtin.Type.UnionField = undefined;

    for (std.meta.declarations(protocols)) |protocol_decl| {
        const protocol = @field(protocols, protocol_decl.name);

        for (@typeInfo(protocol).@"struct".decls) |interface_decl| {
            const wl_interface = @field(protocol, interface_decl.name);
            if (@hasDecl(wl_interface, "Event")) {
                fields[idx] = .{
                    .name = @field(wl_interface, "Name") ++ "",
                    .type = @field(wl_interface, "Event"),
                    .alignment = @alignOf(@field(wl_interface, "Event")),
                };
                idx += 1;
            }
        }
    }

    const T = @Type(.{
        .@"union" = .{
            .layout = .auto,
            .tag_type = ObjectEventTag,
            .fields = &fields,
            .decls = &.{},
        },
    });
    break :blk T;
};
// END Wayland

// Linux Plaform-Specific Functionality

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
        } else null;

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
const glob_log = std.log.scoped(.linux);

// stdlib namespaces/constants
const posix = std.posix;
const endian = builtin.cpu.arch.endian();
