const std = @import("std");

const Drm = @import("Drm.zig");
const Arena = @import("Arena.zig");
const interface = @import("wl-interface.zig");
const GraphicsContext = @import("GraphicsContext.zig");
const input = @import("input.zig");
const SysEvent = @import("event.zig");
const platform = @import("platform.zig");
const xkb = @import("xkb.zig");
const math = @import("math.zig");

const BufCount = GraphicsContext.BufferCount;

const protocols = @import("generated/protocols.zig");

const msg = @import("wl-msg.zig");

const log = std.log.scoped(.@"wayland-client");

const Client = @This();

pub const nil: Client = .{
    // Client arena
    .arena = undefined,
    .keymap_arena = undefined,

    // Base Wayland Connection
    .socket = -1,
    .sock_writer = @constCast(@ptrCast(@alignCast(&{}))),

    // Required Wayland Global Objects
    .display = undefined,
    .registry = undefined,
    .compositor = undefined,
    .seat = undefined,
    .wm_base = undefined,
    .decorations = undefined,
    .dmabuf = undefined,

    // Windows
    .surfaces = undefined,

    // Display/Graphics formats
    .gfx_format = undefined,
    .format_mod_pairs = undefined,
    .supported_format_mod_pairs = undefined,

    // Input
    // Devices
    .keyboard = undefined, // Keyboard/OtherDevice input
    .pointer = undefined, // Mouse/Trackpad input
    .touch = undefined, // Touchscreen input

    // State
    .keymap = undefined,
    .xkb_keymap = null,
    .exit_key = undefined,

    .should_exit = false,

    // Wayland event handling
    .ev_thread = undefined,
    .callbacks = undefined,
    .sys_ev_queue = undefined,
};

// Arena for longer-lived allocations
arena: *Arena,
keymap_arena: *Arena, // Temporary until I implement a free list in my Arena implementation

// Base wayland connection
socket: std.posix.fd_t,
sock_writer: *anyopaque,

// Required interfaces (Global objects)
display: wl.Display,
registry: *interface.Registry,
compositor: wl.Compositor,
seat: wl.Seat,
wm_base: xdg.WmBase,
decorations: xdgd.DecorationManagerV1,
dmabuf: dmab.LinuxDmabufV1,

// Windows
surfaces: std.ArrayList(*Surface),
focused_surface: usize = 0,

// Display/Graphics formats
gfx_format: Drm.Format,
format_mod_pairs: []FormatModPair,
supported_format_mod_pairs: []FormatModPair,

// Input
// Devices
keyboard: wl.Keyboard, // Keyboard/OtherDevice input
pointer: wl.Pointer, // Mouse/Trackpad input
touch: wl.Touch, // Touchscreen input

// State
keymap: []input.Key.State,
xkb_keymap: ?xkb.Keymap,
exit_key: input.Key,

should_exit: bool = false,
// Wayland event handling
ev_thread: Thread,
callbacks: std.ArrayList(CallbackEntry),
sys_ev_queue: *SysEvent.Queue,

pub var ev_iter: EventIterator = undefined;

pub fn init(arena: *Arena, sys_ev_queue: *SysEvent.Queue) *Client {
    const client_ptr = arena.create(Client);
    const connection = {
        const scratch = Thread.scratch_begin(1, .{arena}).?;
        defer scratch.end();
        const xdg_runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return @constCast(&Client.nil);
        const wayland_display = std.posix.getenv("WAYLAND_DISPLAY") orelse return @constCast(&Client.nil);

        const sock_path = std.mem.join(scratch.arena.allocator(), "/", &[_][]const u8{ xdg_runtime_dir, wayland_display }) catch return @constCast(&Client.nil);

        const opt_non_block = 0;
        const sockfd = std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | opt_non_block,
            0,
        ) catch return @constCast(&Client.nil);

        var addr: std.posix.sockaddr = addr: {
            var sock_addr: std.posix.sockaddr.un = .{
                .family = std.posix.AF.UNIX,
                .path = undefined,
            };

            if (sock_path.len + 1 > sock_addr.path.len) return @constCast(&Client.nil);

            @memset(&sock_addr.path, 0);
            @memcpy(sock_addr.path[0..sock_path.len], sock_path);
            break :addr .{ .family = sock_addr.family, .data = sock_addr.path };
        };

        std.posix.connect(
            sockfd,
            &addr,
            @as(std.posix.socklen_t, @intCast(@sizeOf(std.posix.sockaddr.un))),
        ) catch {
            log.err("Failed to connect to Wayland Socket", .{});
            return @constCast(&Client.nil);
        };
    };
    const connection_writer = .{};

    const display: wl.Display = .{ .id = 1 };
    interface.registry = interface.Registry.init(arena, display) catch return @constCast(&Client.nil);
    _ = display.get_registry(connection_writer, .{}) catch return @constCast(&Client.nil);

    var compositor_opt: ?wl.Compositor = null;
    var seat_opt: ?wl.Seat = null;
    var wm_base_opt: ?xdg.WmBase = null;
    var decorations_opt: ?xdgd.DecorationManagerV1 = null;
    var dmabuf_opt: ?dmab.LinuxDmabufV1 = null;

    ev_iter = .init(arena, client_ptr, 2048);
    ev_iter.load_events() catch return @constCast(&Client.nil);

    // Bind interfaces
    while (ev_iter.next()) |ev| switch (ev) {
        .wl_registry => |registry_ev| switch (registry_ev) {
            .global => |global| {
                if (std.mem.eql(u8, global.interface, wl.Seat.Name)) {
                    seat_opt = interface.registry.bind(wl.Seat, connection_writer, global) catch |err| nil: {
                        log.err("Failed to bind compositor with error: {s}", .{@errorName(err)});
                        break :nil null;
                    };
                } else if (std.mem.eql(u8, global.interface, wl.Compositor.Name)) {
                    compositor_opt = interface.registry.bind(wl.Compositor, connection_writer, global) catch |err| nil: {
                        log.err("Failed to bind compositor with error: {s}", .{@errorName(err)});
                        break :nil null;
                    };
                } else if (std.mem.eql(u8, global.interface, xdg.WmBase.Name)) {
                    wm_base_opt = interface.registry.bind(xdg.WmBase, connection_writer, global) catch |err| nil: {
                        log.err("Failed to bind xdg_wm_base with error: {s}", .{@errorName(err)});
                        break :nil null;
                    };
                } else if (std.mem.eql(u8, global.interface, xdgd.DecorationManagerV1.Name)) {
                    decorations_opt = interface.registry.bind(xdgd.DecorationManagerV1, connection_writer, global) catch |err| nil: {
                        log.err("Failed to bind zxdg_decoration_manager with error: {s}", .{@errorName(err)});
                        break :nil null;
                    };
                } else if (std.mem.eql(u8, global.interface, dmab.LinuxDmabufV1.Name)) {
                    dmabuf_opt = interface.registry.bind(dmab.LinuxDmabufV1, connection_writer, global) catch |err| nil: {
                        log.err("Failed to bind linux_dmabuf with error: {s}", .{@errorName(err)});
                        break :nil null;
                    };
                }
            },
            .global_remove => {
                log.warn("Unexpected global remove event during interface bind stage", .{});
            },
        },
        else => log.debug("received unhandle-able event", .{}),
    };

    const wl_compositor = compositor_opt orelse {
        log.err("Failed to bind wl_compositor, cannot continue", .{});
        return @constCast(&Client.nil);
    };
    const wl_seat = seat_opt orelse {
        log.err("Failed to bind wl_seat, cannot continue", .{});
        return @constCast(&Client.nil);
    };
    const xdg_wm_base = wm_base_opt orelse {
        log.err("Failed to bind xdg_wm_base, cannot continue", .{});
        return @constCast(&Client.nil);
    };
    const xdg_decorations = decorations_opt orelse {
        log.err("Failed to bind xdg_decorations, cannot continue", .{});
        return @constCast(&Client.nil);
    };
    const linux_dmabuf = dmabuf_opt orelse {
        log.err("Failed to bind linux_dmabuf, cannot continue", .{});
        return @constCast(&Client.nil);
    };

    const wl_keyboard = wl_seat.get_keyboard(connection_writer, .{}) catch |err| {
        log.err("Failed to write wl_seat.get_keyboard() request with err :: {s}", .{@errorName(err)});
        return @constCast(&Client.nil);
    };
    const wl_pointer = wl_seat.get_pointer(connection_writer, .{}) catch |err| {
        log.err("Failed to write wl_seat.get_pointer() request with err :: {s}", .{@errorName(err)});
        return @constCast(&Client.nil);
    };
    const wl_touch = wl_seat.get_touch(connection_writer, .{}) catch |err| {
        log.err("Failed to write wl_seat.get_touch() request with err :: {s}", .{@errorName(err)});
        return @constCast(&Client.nil);
    };

    client_ptr.* = .{
        // Arena
        .arena = arena,
        .keymap_arena = .init(.default),

        // Base Wayland Connection
        .socket = connection.handle,
        .sock_writer = @constCast(@ptrCast(@alignCast(&{}))),

        // Global Wayland Objects
        .display = display,
        .registry = &interface.registry,
        .compositor = wl_compositor,
        .seat = wl_seat,
        .wm_base = xdg_wm_base,
        .decorations = xdg_decorations,
        .dmabuf = linux_dmabuf,

        // Windows
        .surfaces = undefined,
        .focused_surface = 0,

        // Graphics/Display formats
        .gfx_format = undefined,
        .format_mod_pairs = undefined,
        .supported_format_mod_pairs = undefined,

        // Inputs
        .keyboard = wl_keyboard,
        .pointer = wl_pointer,
        .touch = wl_touch,

        .keymap = arena.push(input.Key.State, input.Key.Count),
        .xkb_keymap = null,
        .exit_key = .q,

        // Event-Handling
        .ev_thread = undefined,
        .callbacks = .init(arena.allocator()),
        .sys_ev_queue = sys_ev_queue,
    };

    const initial_surface: *Surface = arena.create(Surface);
    initial_surface.* = .init(.{
        .id = 0,
        .app_id = "simple-client",
        .surface_title = "Simple Client",
        .client = client_ptr,
        .compositor = wl_compositor,
        .wm_base = xdg_wm_base,
        .decoration_manager = xdg_decorations,
        .dims = .{ .x = 800, .y = 600 },
    });

    var surfaces: std.ArrayList(*Surface) = .init(arena.allocator());
    surfaces.append(initial_surface) catch {
        log.err("Failed to add initial surface to surfaces list", .{});
    };
    client_ptr.surfaces = surfaces;

    const ev_thread = Thread.spawn(.{}, ev_handle_thread, .{client_ptr}) catch |err| {
        log.err("Wayland Event Thread Spawn Failed :: {s}", .{@errorName(err)});
        return @constCast(&Client.nil);
    };

    client_ptr.ev_thread = ev_thread;

    return client_ptr;
}

pub fn deinit(client: *Client) void {
    // At exit:
    // - Close connection
    // - Free client arena
    defer {
        client.registry.deinit();
        client.connection.close();
        client.socket = -1;
        client.arena.release();
    }

    client.ev_thread.join();
    // Release input devices
    if (client.socket != -1) {
        const writer = client.connection.writer();
        client.keyboard.release(writer, .{}) catch |err| {
            log.err("wl_keyboard release failed with err :: {s}", .{@errorName(err)});
        };
        client.pointer.release(writer, .{}) catch |err| {
            log.err("wl_pointer release failed with err :: {s}", .{@errorName(err)});
        };
        client.touch.release(writer, .{}) catch |err| {
            log.err("wl_touch release failed with err :: {s}", .{@errorName(err)});
        };
    }

    // Destroy all surfaces
    {
        for (client.surfaces.items) |surface| {
            surface.destroy();
        }
        client.surfaces.deinit();
    }
}

fn ev_handle_thread(client: *Client) void {
    const ev_poll_time = 100;
    var ev_builder: SysEvent = .nil;

    while (!client.should_exit and client.socket != -1) {
        const time = std.time.microTimestamp();
        client.handle_event(&ev_builder) catch |err| {
            log.err("Wayland Event Thread Hit Error :: {s}", .{@errorName(err)});
            client.should_exit = true;
        };

        const time_elapsed = std.time.microTimestamp() - time;

        if (time_elapsed < ev_poll_time) {
            std.time.sleep(@bitCast((ev_poll_time - time_elapsed) * std.time.ns_per_us));
        }
    }
}

fn handle_event(client: *Client, ev_builder: *SysEvent) !void {
    const event_iterator = &ev_iter;

    const focused_surface = client.surfaces.items[client.focused_surface];
    const writer = client.connection.writer();
    if (event_iterator.next()) |ev| switch (ev) {
        .wl_buffer => |wl_buffer_ev| switch (wl_buffer_ev) {
            .release => {
                log.debug("Compositor has released wl_buffer", .{});
            },
        },
        .wl_callback => |wl_callback_ev| switch (wl_callback_ev) {
            .done => |cb| {
                const entry = client.callbacks.items[0];
                @call(.auto, entry.listener.done, .{ entry.data, entry.callback, @as(i64, @intCast(cb.callback_data)) });
            },
        },
        .wl_display => |wl_display_ev| switch (wl_display_ev) {
            .delete_id => {},
            .@"error" => |err| {
                log.err("wl_display::error => object id: {d}, code: {d}, msg: {s}", .{
                    err.object_id,
                    err.code,
                    err.message,
                });
                return error.WlDisplayError;
            },
        },
        .wl_seat => |wl_seat_ev| switch (wl_seat_ev) {
            .name => |name| {
                log.info("wl_seat name :: {s}", .{name.name});
            },
            .capabilities => |capabilities| {
                log.info("wl_seat capabilities :: pointer : {s}, keyboard : {s}, touch : {s}", .{
                    if (capabilities.capabilities.pointer) "true" else "false",
                    if (capabilities.capabilities.keyboard) "true" else "false",
                    if (capabilities.capabilities.touch) "true" else "false",
                });
            },
        },
        .wl_keyboard => |wl_keyboard_ev| switch (wl_keyboard_ev) {
            .keymap => |keymap| {
                const format = keymap.format;

                client.keymap_arena.clear();
                const fd = keymap.fd;
                {
                    const keymap_data = std.posix.mmap(
                        null,
                        keymap.size,
                        std.posix.PROT.READ,
                        .{ .TYPE = .PRIVATE },
                        fd,
                        0,
                    ) catch |err| {
                        log.err("zwp_linux_dmabuf_feedback_v1 :: Failed to map format table :: {s}", .{@errorName(err)});
                        return err;
                    };
                    defer std.posix.munmap(keymap_data);

                    const map_data = try client.keymap_arena.allocator().dupe(u8, keymap_data);
                    client.xkb_keymap = try .init(client.keymap_arena, map_data);
                    log.debug("wl_keyboard :: Received keymap of size {d} for format: {s}", .{ keymap.size, @tagName(format) });
                }
            },
            .key => |key| {
                defer ev_builder.* = .nil;

                ev_builder.type = .keyboard;
                ev_builder.key = if (client.xkb_keymap) |keymap| blk: {
                    break :blk keymap.get_key(key.key);
                } else .invalid;
                ev_builder.key_state = key.state;

                client.sys_ev_queue.push(ev_builder.*);
            },
            .modifiers => |mods| {
                log.debug("wl_keyboard :: Modifiers Event :: {{ .serial = {d}, .mods_depressed = {d}, .mods_latched = {d}, .mods_locked = {d}, .group = {d} }}", .{
                    mods.serial,
                    mods.mods_depressed,
                    mods.mods_latched,
                    mods.mods_locked,
                    mods.group,
                });
            },
            .enter => {
                log.debug("wl_keyboard :: Enter focus", .{});
            },
            .leave => {
                log.debug("wl_keyboard :: Leave focus", .{});
            },
            else => {
                log.debug("Unused wl_keyboard event :: of type {s}", .{
                    @tagName(wl_keyboard_ev),
                });
            },
        },
        .wl_pointer => |wl_pointer_ev| switch (wl_pointer_ev) {
            .button => |mb| {
                ev_builder.type = .mouse_button;
                const button: input.MouseButton = @enumFromInt(mb.button);

                ev_builder.mouse_button = button;
                ev_builder.mouse_button_state = mb.state;
            },
            .enter => {
                log.debug("wl_pointer :: Enter focus", .{});
            },
            .leave => {
                log.debug("wl_pointer :: Leave focus", .{});
            },
            .motion => |motion| {
                ev_builder.type = .mouse_move;
                ev_builder.mouse_pos_prev = focused_surface.mouse_pos;
                ev_builder.mouse_pos_new = .{ .x = motion.surface_x, .y = motion.surface_y };
                focused_surface.mouse_pos.x = motion.surface_x;
                focused_surface.mouse_pos.y = motion.surface_y;
            },

            .frame => { // Signals end of current pointer event stream
                defer ev_builder.* = .nil;
                client.sys_ev_queue.push(ev_builder.*);
            },
            else => {
                log.debug("Unused wl_pointer event :: {s}", .{@tagName(wl_pointer_ev)});
            },
        },
        .wl_surface => |wl_surface_ev| switch (wl_surface_ev) {
            .enter => log.debug("wl_surface :: gained focus", .{}),
            .leave => log.debug("wl_surface :: lost focus", .{}),
            .preferred_buffer_scale => log.debug("wl_surface :: received preferred buffer scale", .{}),
            .preferred_buffer_transform => log.debug("wl_surface :: received preferred buffer transform", .{}),
        },
        .xdg_wm_base => |xdg_wm_base_ev| switch (xdg_wm_base_ev) {
            .ping => |ping| {
                client.wm_base.pong(writer, .{
                    .serial = ping.serial,
                }) catch |err| return err;
                log.debug("ponged ping from xdg_wm_base :: serial = {d}", .{ping.serial});
            },
        },
        .xdg_surface => |xdg_surface_ev| switch (xdg_surface_ev) {
            .configure => |configure| {
                focused_surface.xdg_surface.ack_configure(writer, .{
                    .serial = configure.serial,
                }) catch |err| return err;
                if (!focused_surface.flags.acked) {
                    log.debug("Acked configure for xdg_surface", .{});
                    focused_surface.flags.acked = true;
                }
            },
        },
        .xdg_toplevel => |xdg_toplevel_ev| switch (xdg_toplevel_ev) {
            .configure => |configure| {
                defer ev_builder.* = .nil;
                if (configure.width > focused_surface.dims.x or configure.height > focused_surface.dims.y) {
                    focused_surface.dims.x = configure.width;
                    focused_surface.dims.y = configure.height;
                }

                ev_builder.type = .surface;
                ev_builder.surface = .{
                    .id = focused_surface.id,
                    .type = .{ .resize = .{ .x = configure.width, .y = configure.height } },
                };

                client.sys_ev_queue.push(ev_builder.*);
            },
            .close => {
                defer ev_builder.* = .nil;

                ev_builder.type = .surface;
                ev_builder.surface = .{
                    .id = focused_surface.id,
                    .type = .close,
                };
                client.sys_ev_queue.push(ev_builder.*);
            },
            else => {
                log.debug("xdg_toplevel :: Unused Event", .{});
            },
        },
        .zxdg_toplevel_decoration_v1 => |zxdg_toplevel_decoration_v1_ev| switch (zxdg_toplevel_decoration_v1_ev) {
            .configure => |configure| {
                log.info("Toplevel decoration mode set :: {s}", .{@tagName(configure.mode)});
            },
        },
        .zwp_linux_buffer_params_v1 => |zwp_linux_buffer_params_v1_ev| switch (zwp_linux_buffer_params_v1_ev) {
            .created => |buf| {
                log.debug("zwp_linux_buffer_params_v1 :: successfully created buffer of id :: {d}", .{buf.buffer});
            },
            .failed => {
                log.debug("zwp_linux_buffer_params_v1 :: buffer creation failed", .{});
            },
        },
        .zwp_linux_dmabuf_feedback_v1 => |zwp_linux_dmabuf_feedback_v1_ev| switch (zwp_linux_dmabuf_feedback_v1_ev) {
            .done => {
                log.debug("zwp_linux_dmabuf_feedback_v1 :: All feedback received", .{});
            },
            .format_table => |table| {
                const fd = table.fd;
                {
                    const entry_count = table.size / 16;
                    log.debug("zwp_linux_dmabuf_feedback_v1 :: Received format table with {d} entries", .{entry_count});

                    const table_data = std.posix.mmap(
                        null,
                        table.size,
                        std.posix.PROT.READ,
                        .{ .TYPE = .PRIVATE },
                        fd,
                        0,
                    ) catch |err| {
                        log.err("zwp_linux_dmabuf_feedback_v1 :: Failed to map format table :: {s}", .{@errorName(err)});
                        return err;
                    };
                    defer std.posix.munmap(table_data);
                    client.format_mod_pairs = client.arena.push(FormatModPair, entry_count);

                    var cur_idx: u16 = 0;
                    var iter = std.mem.window(u8, table_data, 16, 16);
                    while (iter.next()) |pair| : (cur_idx += 1) {
                        const format: Drm.Format = @enumFromInt(std.mem.bytesToValue(u32, pair[0..4]));
                        const modifier: Drm.Modifier = @enumFromInt(std.mem.bytesToValue(u64, pair[8..]));
                        client.format_mod_pairs[cur_idx] = .{ .format = format, .modifier = modifier };
                    }

                    // TODO: Actual
                    client.gfx_format = .abgr8888;
                }
            },
            .main_device => |main_device| {
                log.debug("zwp_linux_dmabuf_feedback_v1 :: Received main_device: {s}", .{main_device.device});
            },
            .tranche_done => {
                log.debug("zwp_linux_dmabuf_feedback_v1 :: tranche_done event received", .{});
            },
            .tranche_target_device => |target_device| {
                log.debug("zwp_linux_dmabuf_feedback_v1 :: Received tranche_target_device: {s}", .{target_device.device});
            },
            .tranche_formats => |tranche_formats| {
                const entry_count = tranche_formats.indices.len / 2; // 16-bit entries in array of 8-bit values
                log.debug("zwp_linux_dmabuf_feedback_v1 :: Received supported format+modifier table indices with {d} entries", .{entry_count});

                client.supported_format_mod_pairs = client.arena.push(FormatModPair, entry_count);

                var cur_idx: u16 = 0;
                var iter = std.mem.window(u8, tranche_formats.indices, 2, 2);
                while (iter.next()) |entry| : (cur_idx += 1) {
                    const idx = std.mem.bytesToValue(u16, entry[0..]);
                    client.supported_format_mod_pairs[cur_idx] = client.format_mod_pairs[idx];
                }
            },
            .tranche_flags => |tranche_flags| {
                log.debug("zwp_linux_dmabuf_feedback_v1 :: Received tranche_flags: scanout = {s}", .{
                    if (tranche_flags.flags.scanout) "true" else "false",
                });
            },
        },
        else => {
            log.warn("Unhandled Event Type", .{});
        },
    } else {
        try event_iterator.load_events();
    }
}

pub fn remove_surface(client: *Client, buf_id: u32) void {
    client.surfaces.items[buf_id].destroy();
    _ = client.surfaces.orderedRemove(buf_id);
}

pub fn callback_destroy(client: *Client, cb: *wl.Callback) void {
    _ = client.callbacks.orderedRemove(0);
    client.registry.remove(cb.*);
}
pub fn callback_add_listener(client: *Client, cb: *wl.Callback, listener: *const CallbackListener, data: *anyopaque) !void {
    try client.callbacks.append(.{ .listener = listener, .callback = cb, .data = data });
}

const CallbackEntry = struct {
    listener: *const CallbackListener,
    callback: *wl.Callback,
    data: *anyopaque,
};

pub const CallbackListener = struct {
    done: *const fn (data: *anyopaque, callback: *wl.Callback, milli_time: i64) void,
};

const FormatModPair = struct {
    format: Drm.Format,
    modifier: Drm.Modifier,
};

const WireEvent = struct {
    header: msg.Header,
    data: []const u8,
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

    var idx: u32 = 1;
    var fields: [enum_len + 1]std.builtin.Type.EnumField = undefined;

    fields[0] = .{
        .name = "wire_event",
        .value = 0,
    };

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
            .tag_type = std.math.IntFittingRange(0, enum_len + 1),
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = true,
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

    var idx: u32 = 1;
    var fields: [union_len + 1]std.builtin.Type.UnionField = undefined;

    fields[0] = .{
        .name = "wire_event",
        .type = WireEvent,
        .alignment = @alignOf(WireEvent),
    };

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

pub const EventIterator = struct {
    client: *Client,
    socket: std.posix.socket_t,
    buf: []u8,
    write: u32,
    ev_queue: EvQueue,
    fd_queue: FdQueue,

    pub fn init(arena: *Arena, client: *Client, size: u32) EventIterator {
        return .{
            .socket = client.connection.handle,
            .client = client,
            .buf = arena.push(u8, @sizeOf(Event) * size),
            .write = 0,
            .fd_queue = .{},
            .ev_queue = .{},
        };
    }

    // NEW APPROACH TO EVENTS:
    // - if no events present (ie, iter.first() returns `null`), caller should invoke iter.load_events()
    // - otherwise, use while (iter.next()) for events

    /// Read from socket, to fill up ev_queue and fd_queue
    ///
    /// This should only be invoked if `iter.first()` returns null;
    pub fn load_events(iter: *EventIterator) !void {
        {
            var cmsg_buf: [fd_msg.Size * 24]u8 = undefined;

            var iov = [_]std.posix.iovec{
                .{
                    .base = iter.buf[iter.write..].ptr,
                    .len = iter.buf[iter.write..].len,
                },
            };

            var message: std.posix.msghdr = .{
                .name = null,
                .namelen = 0,
                .iov = &iov,
                .iovlen = 1,
                .control = &cmsg_buf,
                .controllen = cmsg_buf.len,
                .flags = 0,
            };

            const rc = std.os.linux.recvmsg(iter.socket, &message, std.os.linux.MSG.DONTWAIT);
            log.debug("recvmsg return value :: {d}", .{@as(isize, @bitCast(rc))});
            if (std.posix.errno(rc) == .SUCCESS) {
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

                // standard event handling
                {
                    var read_idx: u32 = 0;
                    while (read_idx < iter.write) {
                        log.debug("reading event", .{});
                        const header = std.mem.bytesToValue(msg.Header, iter.buf[read_idx..][0..msg.Header.Size]);
                        log.debug("Header :: {{ .id = {d}, .op = {d}, .len = {d} }}", .{
                            header.id,
                            header.op,
                            header.msg_size,
                        });

                        const msg_size = header.msg_size;
                        if (read_idx + msg.Header.Size + msg_size <= iter.write) {
                            break;
                        }
                        read_idx += msg.Header.Size;

                        const wire_ev: WireEvent = .{
                            .header = header,
                            .data = iter.buf[read_idx..][0..msg_size],
                        };

                        const obj = interface.registry.get(header.id);

                        const tag = std.meta.activeTag(obj);
                        const union_info = @typeInfo(@TypeOf(obj)).@"union";
                        const event = inline for (union_info.fields) |field| ev: {
                            if (!std.mem.eql(u8, field.name, "nil") and
                                std.mem.eql(u8, field.name, @tagName(tag)))
                            {
                                const T = field.type;

                                switch (@typeInfo(T)) {
                                    .@"struct" => {
                                        var ev: T.Event = @unionInit(Event, @field(T, "Name"), T.Event.parse(header.op, wire_ev.data));
                                        const ev_tag = std.meta.activeTag(ev);
                                        inline for (@typeInfo(T).fields) |ev_field| {
                                            if (std.mem.eql(u8, ev_field.name, @tagName(ev_tag)) and
                                                @hasField(ev_field.type, "fd"))
                                            {
                                                @field(ev, "fd") = iter.fd_queue.next();
                                            }
                                        }

                                        break :ev @unionInit(Event, @field(T, "Name"), ev);
                                    },
                                    else => unreachable,
                                }
                            }
                            unreachable;
                        };

                        iter.ev_queue.push(event);
                    }

                    @memmove(iter.buf, iter.buf[read_idx..]);
                    iter.write = iter.write - read_idx;
                    @memset(iter.buf[iter.write..], 0);
                }
            } else {
                return error.SocketClosed;
            }
        }
    }

    pub fn next(noalias iter: *EventIterator) ?Event {
        return iter.ev_queue.next();
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

    const cmsg = msg.cmsg;
    const cmsghdr = msg.cmsghdr;
    const fd_msg = cmsg(std.posix.fd_t);
    const SCM_RIGHTS = 0x01;
};

const OldEvent = struct {
    header: msg.Header,
    data: []const u8,

    pub const nil: Event = .{
        .header = .{
            .id = 0,
            .op = 0,
            .msg_size = 0,
        },
        .data = &.{},
    };

    pub fn eql(ev_1: *const Event, ev_2: *const Event) bool {
        return (std.mem.eql(u8, std.mem.asBytes(&ev_1.header), std.mem.asBytes(&ev_2.header)) and std.mem.eql(u8, ev_1.data, ev_2.data));
    }

    /// Iterator over Wayland events
    pub fn iter(comptime buf_size: comptime_int) type {
        return struct {
            /// Read into buffer happens from offset pointer
            /// Read from buffer happens from start of buffer
            const ShiftBuf = struct {
                data: [buf_size]u8 = undefined,
                start: usize = 0,
                end: usize = 0,

                /// Remove already used bytes to allow space for next data read
                /// Any incomplete data is moved to the front, and all other bytes are zeroed out
                pub fn shift(sb: *ShiftBuf) void {
                    std.mem.copyForwards(u8, &sb.data, sb.data[sb.start..]);
                    sb.end -= sb.start;
                    sb.start = 0;
                }
            };

            const FdQueue = struct {
                data: [Len]std.posix.fd_t = undefined,
                read: usize = 0,
                write: usize = 0,
                pub const Len = 64;
            };

            const Iterator = @This();

            stream: std.net.Stream,
            buf: ShiftBuf = .{},
            fd_queue: FdQueue = .{},
            fd_buf: [FdQueue.Len * @sizeOf(std.posix.fd_t)]u8 = undefined,

            pub fn init(stream: std.net.Stream) Iterator {
                return .{
                    .stream = stream,
                };
            }

            /// Calls `.shift()` on data buffer, and reads in new bytes from stream
            fn load_events(it: *Iterator) !void {
                if (receive_cmsg(it.stream.handle, &it.fd_buf)) |fd| {
                    const idx = it.fd_queue.write % FdQueue.Len;
                    it.fd_queue.data[idx] = fd;
                    it.fd_queue.write += 1;
                }

                it.buf.shift();

                const bytes_read: usize = try it.stream.read(it.buf.data[it.buf.end..]);
                it.buf.end += bytes_read;
                it.buf.end = if (it.buf.end > buf_size) buf_size else it.buf.end;
            }

            /// Get next stored message from buffer
            ///
            /// When the buffer is filled, the follwing call to `.next()` will
            /// overwrite all messages that have already been read.
            ///
            /// See: `ShiftBuf.shift()`
            pub fn next(it: *Iterator) !?Event {
                while (true) {
                    const buffered_ev: ?Event = blk: {
                        const header_end = it.buf.start + msg.Header.Size;
                        if (header_end > it.buf.end) {
                            break :blk null;
                        }

                        const header = std.mem.bytesToValue(msg.Header, it.buf.data[it.buf.start..header_end]);

                        const data_end = it.buf.start + header.msg_size;

                        if (data_end > it.buf.end) {
                            log.err("data too big: {d} ... end: {d}", .{ data_end, it.buf.end });
                            if (it.buf.start == 0) {
                                return error.BufTooSmol;
                            }

                            break :blk null;
                        }

                        it.buf.start = data_end;

                        break :blk .{
                            .header = header,
                            .data = it.buf.data[header_end..data_end],
                        };
                    };

                    if (buffered_ev) |ev| return ev;

                    const data_in_stream = blk: {
                        var poll: [1]std.posix.pollfd = [_]std.posix.pollfd{.{
                            .fd = it.stream.handle,
                            .events = std.posix.POLL.IN,
                            .revents = 0,
                        }};
                        const bytes_ready = std.posix.poll(&poll, 0) catch |err| poll_blk: {
                            log.warn("  Event Iterator :: Socket Poll Error :: {s}", .{@errorName(err)});
                            break :poll_blk 0;
                        };
                        break :blk bytes_ready > 0;
                    };

                    if (data_in_stream) {
                        it.load_events() catch |err| {
                            log.err("  Event Iterator :: {s}", .{@errorName(err)});
                            return err;
                        };
                    } else {
                        return null;
                    }
                }
            }

            pub fn next_fd(it: *Iterator) ?std.posix.fd_t {
                if (it.fd_queue.read == it.fd_queue.write)
                    return null;

                defer it.fd_queue.read += 1;
                return it.fd_queue.data[it.fd_queue.read];
            }
            pub fn peek_fd(it: *Iterator) ?std.posix.fd_t {
                if (it.fd_queue.read == it.fd_queue.write)
                    return null;

                return it.fd_queue.data[it.fd_queue.read];
            }

            const cmsg = msg.cmsg;
            const fd_msg = cmsg(std.posix.fd_t);
            const SCM_RIGHTS = 0x01;
            fn receive_cmsg(socket: std.posix.socket_t, buf: []u8) ?std.posix.fd_t {
                var cmsg_buf: [fd_msg.Size * 12]u8 = undefined;

                var iov = [_]std.posix.iovec{
                    .{
                        .base = buf.ptr,
                        .len = buf.len,
                    },
                };

                var message: std.posix.msghdr = .{
                    .name = null,
                    .namelen = 0,
                    .iov = &iov,
                    .iovlen = 1,
                    .control = &cmsg_buf,
                    .controllen = cmsg_buf.len,
                    .flags = 0,
                };

                const rc = std.os.linux.recvmsg(socket, &message, std.os.linux.MSG.PEEK | std.os.linux.MSG.DONTWAIT);

                const res = res: {
                    if (@as(isize, @bitCast(rc)) < 0) {
                        const err = std.posix.errno(rc);
                        log.err("recvmsg failed with err: {s}", .{@tagName(err)});
                        break :res null;
                    } else {
                        const cmsg_size = fd_msg.Size;
                        var offset: usize = 0;
                        while (offset + cmsg_size <= message.controllen) {
                            const ctrl_buf: [*]u8 = @ptrCast(message.control.?);
                            const ctrl_msg: *align(1) fd_msg = @ptrCast(@alignCast(ctrl_buf[offset..][0..fd_msg.Size]));

                            if (ctrl_msg.type == std.posix.SOL.SOCKET and ctrl_msg.level == SCM_RIGHTS)
                                break :res ctrl_msg.data;
                        }
                        offset += 1;
                    }
                    break :res null;
                };

                return res;
            }
        };
    }
};

pub const Surface = struct {
    pub const Flags = packed struct {
        acked: bool = false,
        closed: bool = false,
        focused: bool = true,
    };

    flags: Flags = .{},
    client: *const Client,
    id: u32,
    app_id: []const u8,
    title: []const u8,
    wl_surface: wl.Surface,
    xdg_surface: xdg.Surface,
    toplevel: xdg.Toplevel,
    decorations: xdgd.ToplevelDecorationV1,
    cur_buf: usize,
    dims: Vec2i32,
    pos: Vec2i32,
    mouse_pos: Vec2f32 = .zero,
    fps_target: i32 = 60,

    pub const nil: Surface = .{
        .id = 0,
        .app_id = "",
        .title = "",
        .client = &Client.nil,
        .wl_surface = .{ .id = 0 },
        .xdg_surface = .{ .id = 0 },
        .toplevel = .{ .id = 0 },
        .decorations = .{ .id = 0 },
        .cur_buf = 0,
        .dims = .zero,
        .pos = .zero,
        .fps_target = 0,
    };

    const init_params = struct {
        client: *Client,
        id: u32,
        app_id: ?[:0]const u8 = null,
        surface_title: ?[:0]const u8 = null,
        compositor: wl.Compositor,
        wm_base: xdg.WmBase,
        decoration_manager: xdgd.DecorationManagerV1,
        dims: ?Vec2i32 = null,
        pos: ?Vec2i32 = null,
        fps_target: ?i32 = null,
    };

    pub fn init(
        params: init_params,
    ) Surface {
        const writer = params.client.connection.writer();
        const wl_surface = params.compositor.create_surface(writer, .{}) catch |err| {
            log.err("Failed to create new surface due to err :: {s}", .{@errorName(err)});
            return .nil;
        };

        const xdg_surface = params.wm_base.get_xdg_surface(writer, .{ .surface = wl_surface.id }) catch |err| {
            log.err("failed to create new xdg_surface due to err :: {s}", .{@errorName(err)});
            wl_surface.destroy(writer, .{}) catch |derr| {
                log.err("Failed to send destroy message for wl_surface with err :: {s}", .{@errorName(derr)});
            };
            return .nil;
        };

        const xdg_toplevel = xdg_surface.get_toplevel(writer, .{}) catch |err| {
            log.err("failed to create new xdg_toplevel due to err :: {s}", .{@errorName(err)});
            wl_surface.destroy(writer, .{}) catch |derr| {
                log.err("Failed to send destroy message for wl_surface with err :: {s}", .{@errorName(derr)});
            };
            xdg_surface.destroy(writer, .{}) catch |derr| {
                log.err("Failed to send destroy message for xdg_surface with err :: {s}", .{@errorName(derr)});
            };
            return .nil;
        };

        if (params.app_id) |id| xdg_toplevel.set_app_id(writer, .{ .app_id = id }) catch |err| {
            log.warn("Failed to set app_id due to err: {s}", .{@errorName(err)});
        };
        if (params.surface_title) |title| xdg_toplevel.set_title(writer, .{ .title = title }) catch |err| {
            log.warn("Failed to set toplevel title due to err: {s}", .{@errorName(err)});
        };

        wl_surface.commit(writer, .{}) catch |err| {
            log.warn("Failed to commit wl_surface due to err: {s}", .{@errorName(err)});
        };

        const decorations = params.decoration_manager.get_toplevel_decoration(writer, .{ .toplevel = xdg_toplevel.id }) catch |err| {
            log.err("Failed to create toplevel_decorations due to err :: {s}", .{@errorName(err)});
            wl_surface.destroy(writer, .{}) catch |derr| {
                log.err("Failed to send destroy message for wl_surface with err :: {s}", .{@errorName(derr)});
            };
            xdg_surface.destroy(writer, .{}) catch |derr| {
                log.err("Failed to send destroy message for xdg_surface with err :: {s}", .{@errorName(derr)});
            };
            xdg_toplevel.destroy(writer, .{}) catch |derr| {
                log.err("Failed to send destroy message for xdg_toplevel with err :: {s}", .{@errorName(derr)});
            };
            return .nil;
        };

        return .{
            .client = params.client,
            .id = params.id,
            .app_id = params.app_id orelse "",
            .title = params.surface_title orelse "",
            .wl_surface = wl_surface,
            .xdg_surface = xdg_surface,
            .toplevel = xdg_toplevel,
            .decorations = decorations,
            .cur_buf = 0,
            .dims = params.dims orelse .zero,
            .pos = params.pos orelse .zero,
            .fps_target = params.fps_target orelse 60,
        };
    }

    pub fn destroy(surface: *Surface) void {
        const writer = surface.client.connection.writer();
        surface.decorations.destroy(writer, .{}) catch |err| {
            log.err("Surface :: deinit() :: failed to send xdg_decorations.destroy() message with err :: {s}", .{@errorName(err)});
        };
        surface.toplevel.destroy(writer, .{}) catch |err| {
            log.err("Surface :: deinit() :: failed to send xdg_toplevel.destroy() message with err :: {s}", .{@errorName(err)});
        };
        surface.xdg_surface.destroy(writer, .{}) catch |err| {
            log.err("Surface :: deinit() :: failed to send xdg_surface.destroy() message with err :: {s}", .{@errorName(err)});
        };
        surface.wl_surface.destroy(writer, .{}) catch |err| {
            log.err("Surface :: deinit() :: failed to send wl_surface.destroy() message with err :: {s}", .{@errorName(err)});
        };
    }
};

// TESTS
const testing = std.testing;

test "Event Comparisons" {
    const ev: Event = .nil;
    const ev2: Event = .nil;

    const sim_ev_data = "wl_compositor";
    const sim_ev: Event = .{
        .header = .{
            .id = 2, // always the Registry ID
            .op = 0, // global announce op
            .msg_size = sim_ev_data.len,
        },
        .data = sim_ev_data,
    };
    try testing.expect(ev.eql(&ev2));
    try testing.expect(!ev.eql(&sim_ev));
    try testing.expect(sim_ev.eql(&sim_ev));
}

test "Event Iter" {
    const registry: wl.Registry = .{ .id = 2 };

    const sim_ev_str: [:0]const u8 = "wl_compositor";
    const len = 20;
    var sim_ev_data: [len]u8 = undefined;
    const strlen: u32 = sim_ev_str.len;
    const strlen_bytes = std.mem.asBytes(&strlen);

    @memset(&sim_ev_data, 0);
    @memcpy(sim_ev_data[0..4], strlen_bytes);
    @memcpy(sim_ev_data[4 .. 4 + sim_ev_str.len], sim_ev_str);

    const nil_ev: Event = .nil;
    const registry_global = 0;
    const header: msg.Header = .{
        .id = registry.id,
        .op = registry_global, // global announce op
        .msg_size = msg.Header.Size + sim_ev_data.len,
    };
    const sim_ev: Event = .{
        .header = header,
        .data = &sim_ev_data,
    };

    var sim_ev_bytes: [msg.Header.Size + len]u8 = undefined;
    @memcpy(sim_ev_bytes[0..msg.Header.Size], std.mem.asBytes(&header));
    @memcpy(sim_ev_bytes[msg.Header.Size..][0..], &sim_ev_data);

    const iter_buf_len = 256;
    var buf_data: [iter_buf_len]u8 = undefined;
    @memcpy(buf_data[0..sim_ev_bytes.len], &sim_ev_bytes);

    var iter: Event.iter(iter_buf_len) = .{
        .stream = undefined,
        .buf = .{
            .data = buf_data,
            .end = sim_ev_bytes.len,
        },
    };

    const ev = try iter.next() orelse return error.EventIterFailedToReadEvent;

    try testing.expect(sim_ev.eql(&ev));
    try testing.expect(!sim_ev.eql(&nil_ev));
}

fn getActiveTagType(u: anytype) type {
    const tag = std.meta.activeTag(u);
    const union_info = @typeInfo(@TypeOf(u)).Union;
    inline for (union_info.fields) |field| {
        if (std.mem.eql(u8, field.name, @tagName(tag))) {
            return field.type;
        }
    }
    unreachable; // Should never happen if union is well-formed
}

const Thread = platform.Thread;
const Context = platform.Context;
const Vec2f32 = math.Vec2f32;
const Vec2i32 = math.Vec2i32;

const wl = protocols.wayland;
const xdg = protocols.xdg_shell;
const dmab = protocols.linux_dmabuf_v1;
const xdgd = protocols.xdg_decoration_unstable_v1;
