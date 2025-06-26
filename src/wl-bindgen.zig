const std = @import("std");
const Allocator = std.mem.Allocator;
const Arena = @import("Arena.zig");

const xml = @import("xml.zig");
const stdout = std.io.getStdOut().writer();

const Type = enum {
    int,
    uint,
    fixed,
    string,
    object,
    new_id,
    array,
    fd,

    pub fn from_string(s: []const u8) !Type {
        return std.meta.stringToEnum(Type, s) orelse {
            return error.UnknownType;
        };
    }
    pub fn to_zig_type_string(self: Type) ?[]const u8 {
        return switch (self) {
            .fd => "std.posix.fd_t", // fd will be sent through cmsg, not main send
            .int => "i32",
            .fixed => "f32",
            .array => "[]const u8",
            .string => "[:0]const u8",
            .uint, .object, .new_id => "u32",
        };
    }
};

fn enum_to_str(enum_str: []const u8) []const u8 {
    const upper_idx = blk: {
        for (enum_str, 0..) |char, idx| {
            if (char == '.')
                break :blk idx + 1;
        }
        break :blk 0;
    };
    const underscore_idx = if (upper_idx == 0) 0 else blk: {
        for (enum_str, 0..) |char, idx| {
            if (char == '_')
                break :blk idx + 1;
        }
        break :blk 0;
    };
    var name = @constCast(enum_str[underscore_idx..]);
    name[0] = std.ascii.toUpper(name[0]);
    name[upper_idx - underscore_idx] = std.ascii.toUpper(name[upper_idx - underscore_idx]);
    return name;
}

pub fn generate(allocator: Allocator, spec_xml: []const u8, writer: anytype) !void {
    const spec = try xml.parse(allocator, spec_xml);
    defer spec.deinit();
    const protocol_name = spec.root.getAttribute("name").?;
    try writer.print(
        \\ 
        \\// ----------------------- BEGIN PROTOCOL: {s} --------------------------
        \\ 
        \\pub const {s} = struct {{
        \\const log = std.log.scoped(.@"{s}");
        \\ 
    , .{
        protocol_name,
        protocol_name,
        protocol_name,
    });

    {
        // ------------------------ BEGIN PROTOCOL ------------------------
        // Initial generation pass
        var interface_iter = spec.root.findChildrenByTag("interface");
        while (interface_iter.next()) |interface| {
            const interface_name = interface.getAttribute("name").?;
            const interface_version = interface.getAttribute("version").?;
            const underscore_idx = blk: {
                for (interface_name, 0..) |char, idx| {
                    if (char == '_')
                        break :blk idx + 1;
                }
                break :blk 0;
            };
            const name = interface_name[underscore_idx..];

            if (interface.findChildByTag("description")) |description| {
                if (description.getAttribute("summary")) |summary| {
                    try writer.print(
                        \\
                        \\///{s}
                        \\
                    , .{IgnoreNewline{ .str = summary }});
                }
            } else {
                try writer.writeAll("\n");
            }
            // ------------------------ BEGIN INTERFACE ------------------------
            try writer.print(
                \\pub const {s} = struct {{
                \\    // Actual advertised 'name' of interface
                \\    pub const Name: [:0]const u8 = "{s}";
                \\    // Version of interface this code was generated from
                \\    pub const Version: u32 = {s};
                \\
                \\    id: u32,
                \\
            ,
                .{
                    snakeToPascal(name),
                    interface_name,
                    interface_version,
                },
            );

            var enum_iter = interface.findChildrenByTag("enum");
            while (enum_iter.next()) |enum_type| {
                const enum_name = enum_type.getAttribute("name").?;
                if (enum_type.findChildByTag("description")) |description|
                    if (description.getAttribute("summary")) |summary| {
                        try writer.print(
                            \\
                            \\    ///{s}
                            \\
                        , .{IgnoreNewline{ .str = summary }});
                    } else {
                        try writer.print("\n", .{});
                    };

                var enum_field_iter = enum_type.findChildrenByTag("entry");
                if (enum_type.getAttribute("bitfield")) |_| {
                    // bitfield
                    try writer.print("    pub const {s} = packed struct(u32) {{\n", .{snakeToPascal(enum_name)});
                    var idx: u8 = 0;
                    while (enum_field_iter.next()) |bit_entry| : (idx += 1) {
                        if (bit_entry.getAttribute("summary")) |summary| {
                            try writer.print(
                                \\
                                \\        ///{s}
                                \\
                            , .{IgnoreNewline{ .str = summary }});
                        } else {
                            try writer.print("\n", .{});
                        }
                        const entry_name = bit_entry.getAttribute("name").?;
                        try writer.print("        @\"{s}\": bool = false,", .{entry_name});
                    }

                    while (idx < 32) : (idx += 1) {
                        try writer.print("        __reserved_bit_{d}: bool = false,", .{idx});
                    }
                } else {
                    try writer.print("    pub const {s} = enum (u32) {{\n", .{snakeToPascal(enum_name)});
                    while (enum_field_iter.next()) |enum_entry| {
                        if (enum_entry.getAttribute("summary")) |summary| {
                            try writer.print(
                                \\
                                \\        ///{s}
                                \\
                            , .{IgnoreNewline{ .str = summary }});
                        } else {
                            try writer.print("\n", .{});
                        }
                        const entry_name = enum_entry.getAttribute("name").?;
                        const entry_value = enum_entry.getAttribute("value").?;
                        try writer.print("        @\"{s}\" = {s},", .{ entry_name, entry_value });
                    }
                }
                try writer.print("\n    }};", .{});
            }

            var idx: usize = 0;
            var request_iter = interface.findChildrenByTag("request");
            var id_param: []const u8 = undefined;
            while (request_iter.next()) |req| : (idx += 1) {
                const req_name = req.getAttribute("name").?;
                var req_interface_opt: ?[]const u8 = null;

                // write params object for function
                {
                    try writer.print(
                        \\
                        \\    pub const {s}_params = struct {{
                        \\        pub const op = {d};
                        \\
                    ,
                        .{
                            req.getAttribute("name").?,
                            idx,
                        },
                    );
                    var arg_iter = req.findChildrenByTag("arg");
                    while (arg_iter.next()) |arg| {
                        const arg_interface_opt = arg.getAttribute("interface");
                        const arg_name = arg.getAttribute("name").?;
                        const arg_type: Type = try Type.from_string(arg.getAttribute("type").?);
                        const arg_enum_type = arg.getAttribute("enum");

                        if (arg.getAttribute("summary")) |summary| {
                            try writer.print(
                                \\        ///{s}
                                \\
                            , .{IgnoreNewline{ .str = summary }});
                        }
                        if (arg_type == .new_id and arg_interface_opt == null) {
                            try writer.print(
                                \\
                                \\        {s}_interface: [:0]const u8,
                                \\        {s}_interface_version: u32,
                                \\
                            , .{ arg_name, arg_name });
                        }
                        try writer.print("        {s}: ", .{arg_name});
                        if (arg_enum_type) |enum_type| {
                            try writer.print("{s},\n", .{snakeToPascal(enum_to_str(enum_type))});
                        } else if (arg_type == .new_id) {
                            if (arg_interface_opt) |arg_interface| {
                                try writer.print("?{s} = null, // id for new {s} object\n", .{
                                    arg_type.to_zig_type_string().?,
                                    arg_interface,
                                });
                                req_interface_opt = arg_interface;
                                id_param = arg_name;
                            } else {
                                try writer.print("{s},\n", .{arg_type.to_zig_type_string().?});
                            }
                        } else {
                            try writer.print("{s},\n", .{arg_type.to_zig_type_string().?});
                        }
                    }
                    try writer.print(
                        \\    }};
                        \\
                    , .{});
                }

                if (req.findChildByTag("description")) |description| {
                    if (description.getAttribute("summary")) |summary| {
                        try writer.print(
                            \\
                            \\    ///{s}
                            \\
                        , .{IgnoreNewline{ .str = summary }});
                    }
                } else {
                    try writer.writeAll("\n");
                }

                if (req.getAttribute("type")) |_| { // only appears with destructors
                    try writer.print(
                        \\
                        \\    pub fn {s}(self: *const {s}, connection: Connection, params: {s}_params,) !void {{
                        \\        try connection.write(params, self.id, @TypeOf(params).op);
                        \\        connection.registry.remove(self.*);
                        \\    }}
                        \\
                        \\
                    , .{
                        req_name,
                        snakeToPascal(name),
                        req_name,
                    });
                } else if (req_interface_opt) |interface_t| {
                    try writer.print(
                        \\
                        \\    pub fn {s}(self: *const {s}, connection: Connection, params: {s}_params,) !{s} {{
                        \\        const res_id = init: {{
                        \\            if (params.{s}) |id| {{
                        \\                try connection.write(params, self.id, @TypeOf(params).op);
                        \\                try connection.registry.insert(id, {s});
                        \\                break :init id;
                        \\            }} else {{
                        \\                const _res = try connection.registry.register({s});
                        \\                var write_params: {s}_params = params;
                        \\                write_params.{s} = _res.id;
                        \\                try connection.write(write_params, self.id, @TypeOf(params).op);
                        \\                break :init _res.id;
                        \\            }}
                        \\        }};
                        \\        return .{{ .id = res_id }};
                        \\    }}
                        \\
                        \\
                    , .{
                        req_name,
                        snakeToPascal(name),
                        req_name,
                        interface_t,
                        id_param,
                        interface_t,
                        interface_t,
                        req_name,
                        id_param,
                    });
                } else {
                    try writer.print(
                        \\
                        \\    pub fn {s}(self: *const {s}, connection: Connection, params: {s}_params,) !void {{
                        \\        try connection.write(params, self.id, @TypeOf(params).op);
                        \\    }}
                        \\
                        \\
                    , .{
                        req_name,
                        snakeToPascal(name),
                        req_name,
                    });
                }
            }

            idx = 0;
            if (interface.findChildByTag("event")) |_| {
                var event_iter = interface.findChildrenByTag("event");
                try writer.print("pub const Event = union (enum) {{\n", .{});
                // Declare fields
                while (event_iter.next()) |ev| {
                    const ev_name = ev.getAttribute("name").?;

                    try writer.print(
                        \\    @"{s}": Event.@"{s}",
                        \\
                    , .{ ev_name, snakeToPascal(ev_name) });
                }

                // Declare Types
                event_iter = interface.findChildrenByTag("event"); // reset
                while (event_iter.next()) |ev| {
                    const ev_name = ev.getAttribute("name").?;

                    if (ev.findChildByTag("description")) |description|
                        if (description.getAttribute("summary")) |summary|
                            try writer.print(
                                \\
                                \\
                                \\        ///{s}
                            , .{IgnoreNewline{ .str = summary }});
                    try writer.print(
                        \\
                        \\        pub const {s} = struct {{
                    , .{snakeToPascal(ev_name)});

                    var ev_arg_iter = ev.findChildrenByTag("arg");
                    while (ev_arg_iter.next()) |ev_arg| {
                        const arg_name = ev_arg.getAttribute("name").?;
                        try writer.print("\n             {s}", .{arg_name});
                        const arg_t_opt = ev_arg.getAttribute("type");
                        const arg_enum_t_opt = ev_arg.getAttribute("enum");
                        if (arg_enum_t_opt) |arg_enum_t| {
                            if (std.mem.eql(u8, "wl_", arg_enum_t[0..3]))
                                try writer.print(": {s},", .{snakeToPascal(arg_enum_t[3..])})
                            else
                                try writer.print(": {s}.{s},", .{ snakeToPascal(name), snakeToPascal(arg_enum_t) });
                        } else if (arg_t_opt) |arg_t|
                            try writer.print(": {s},", .{(try Type.from_string(arg_t)).to_zig_type_string().?})
                        else
                            try writer.print(",", .{});
                    }
                    try writer.print("        }};", .{});
                }

                event_iter = interface.findChildrenByTag("event"); // reset
                try writer.print(
                    \\
                    \\        pub fn parse(op: u32, data: []const u8) !Event {{
                    \\            return switch (op) {{
                    \\
                , .{});
                while (event_iter.next()) |ev| : (idx += 1) {
                    const ev_name = ev.getAttribute("name").?;

                    try writer.print(
                        \\                {d} => .{{ .@"{s}" = try Connection.parse_wire_ev(Event.@"{s}", data) }},
                        \\
                    , .{ idx, ev_name, snakeToPascal(ev_name) });
                }
                try writer.print(
                    \\                else => {{
                    \\                    log.warn("Unknown {s} event: {{d}}", .{{op}});
                    \\                    return error.UnknownEvent;
                    \\                }},
                    \\
                , .{name});
                try writer.print("\n            }};\n", .{});
                try writer.print("\n        }}\n", .{});
                try writer.print("    }};\n", .{});
            }
            idx = 0;

            // ------------------------  END INTERFACE  ------------------------
            try writer.print("\n}};\n", .{});
        }
        try writer.print("}};\n", .{});

        // Alias pass
        interface_iter = spec.root.findChildrenByTag("interface"); // reset iterator to go for second loop
        while (interface_iter.next()) |interface| {
            const interface_name = interface.getAttribute("name").?;
            const underscore_idx = blk: {
                for (interface_name, 0..) |char, idx| {
                    if (char == '_')
                        break :blk idx + 1;
                }
                break :blk 0;
            };
            const name = interface_name[underscore_idx..];
            try writer.print("const @\"{s}\" = {s}.{s};\n", .{
                interface_name,
                protocol_name,
                snakeToPascal(name),
            });
        }

        try writer.print(
            \\ 
            \\// ----------------------- END PROTOCOL: {s} --------------------------
            \\ 
            \\ 
        , .{protocol_name});
        // ------------------------  END PROTOCOL  ------------------------
    }
}

pub fn main() !void {
    var arena = Arena.init(.default);
    defer arena.release();
    const allocator = arena.allocator();

    var args = std.process.argsWithAllocator(allocator) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
    };
    const prog_name = args.next() orelse "wl-zig-bindgen";

    var xml_opts = std.ArrayList([]const u8).init(arena.allocator());
    var file_outs = std.ArrayList(?[]const u8).init(arena.allocator());
    var absolute_protocol_paths = false;
    var out_is_cli = false;
    var file_in = true;
    var debug = false;
    var out_pref_opt: ?[]const u8 = null;
    var protocol_filename: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help_msg(prog_name) catch |err| {
                std.log.err("Failed to write to stdout with err: {s}", .{@errorName(err)});
            };
            std.process.exit(1);
        } else if (std.mem.eql(u8, arg, "--cli")) {
            out_is_cli = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            file_in = false;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            try stdout.print("[debug mode]\n", .{});
            debug = true;
        } else if (std.mem.eql(u8, arg, "--absolute-protocol-paths")) {
            absolute_protocol_paths = true;
        } else if (std.mem.eql(u8, arg, "--prefix") or std.mem.eql(u8, arg, "-p")) {
            out_pref_opt = args.next() orelse blk: {
                help_msg(prog_name) catch |err| {
                    std.log.err("Failed to write to stdout with err: {s}", .{@errorName(err)});
                };
                break :blk null;
            };
        } else {
            if (file_in) try xml_opts.append(arg) else protocol_filename = arg;
        }
    }

    while (file_outs.items.len < xml_opts.items.len) {
        try file_outs.append(null);
    }

    const cwd = std.fs.cwd();

    {
        var file_data: std.ArrayList(u8) = .init(allocator);
        const file_writer = file_data.writer();

        try file_writer.print(
            \\// WARNING: This file is auto-generated by wl-bindgen,
            \\//          based on the supplied wayland protocols.
            \\//          It is recommended that you do NOT edit this file.
            \\//
            \\
            \\const std = @import("std");
            \\const linux = @import("../linux.zig"); // assume provided by user"
            \\const Connection = linux.Connection;
            \\
        , .{});

        for (xml_opts.items) |xml_file| {
            const xml_src = if (!absolute_protocol_paths) cwd.readFileAlloc(allocator, xml_file, std.math.maxInt(usize)) catch |err| {
                std.log.err("Failed to open input file '{s}' with err: {s}", .{ xml_file, @errorName(err) });
                std.process.exit(1);
            } else file: {
                const fin = std.fs.openFileAbsolute(xml_file, .{ .mode = .read_only }) catch |err| {
                    std.log.err("Failed to open input file '{s}' with err: {s}", .{ xml_file, @errorName(err) });
                    std.process.exit(1);
                };
                defer fin.close();
                break :file fin.readToEndAlloc(allocator, std.math.maxInt(usize)) catch |err| {
                    std.log.err("Failed to read input file '{s}' with err: {s}", .{ xml_file, @errorName(err) });
                    std.process.exit(1);
                };
            };
            generate(allocator, xml_src, file_data.writer()) catch |err| {
                std.log.err("XML parse err: {s}", .{@errorName(err)});
            };
        }

        file_data.append(0) catch @panic("oom");
        const src = file_data.items[0 .. file_data.items.len - 1 :0];
        const tree = std.zig.Ast.parse(allocator, src, .zig) catch |err| switch (err) {
            error.OutOfMemory => @panic("oom"),
        };

        const formatted = if (tree.errors.len > 0) blk: {
            std.log.err("generated invalid zig code", .{});

            reportParseErrors(tree) catch |err| {
                std.log.err("failed to dump ast errors: {s}", .{@errorName(err)});
                std.process.exit(1);
            };

            if (debug) {
                break :blk src;
            }
            std.process.exit(1);
        } else tree.render(allocator) catch |err| switch (err) {
            error.OutOfMemory => @panic("oom"),
        };

        if (tree.errors.len > 0 and debug) {
            try stdout.writeAll(src);
        }

        const protocol_filename_default: []const u8 = "protocols.zig";
        const out_file = if (protocol_filename) |filename| filename else if (!file_in) protocol_filename_default else null;
        if (out_file) |of| {
            if (std.fs.path.dirname(of)) |dir| {
                cwd.makePath(dir) catch |err| {
                    std.log.err("failed to create output directory '{s}' ({s})", .{ dir, @errorName(err) });
                    std.process.exit(1);
                };
            }

            const out_path = if (out_pref_opt) |out_prefix|
                try std.mem.join(arena.allocator(), "/", &[_][]const u8{ out_prefix, of })
            else
                of;

            cwd.writeFile(.{
                .sub_path = out_path,
                .data = formatted,
            }) catch |err| {
                std.log.err("failed to write to output file '{s}' ({s})", .{ of, @errorName(err) });
                std.process.exit(1);
            };
        }
        if (out_is_cli) {
            stdout.writeAll(formatted) catch |err| {
                std.log.err("failed to write output to console with err: {s}", .{@errorName(err)});
            };
        }
    }
}

fn help_msg(prog_name: []const u8) !void {
    try stdout.print(
        \\\ Utility tool to generate Zig bindings from Wayland protocol XML specifications
        \\\
        \\\ Usage: {s} [options] <xml source> <zig output path>
        \\\ -h --help           Show this message and exit
        \\\ --cli               Dump output to console
        \\\ --out <filename>    Specify output filename
        \\\ --prefix <prefix>   Specify output path prefix
        \\\
    , .{prog_name});
}

fn reportParseErrors(tree: std.zig.Ast) !void {
    const stderr = std.io.getStdErr().writer();

    for (tree.errors) |err| {
        const loc = tree.tokenLocation(0, err.token);
        try stderr.print("(wayland-zig error):{d}:{d}: error: ", .{ loc.line + 1, loc.column + 1 });
        try tree.renderError(err, stderr);
        try stderr.print("\n{s}\n", .{tree.source[loc.line_start..loc.line_end]});
        for (0..loc.column) |_| {
            try stderr.writeAll(" ");
        }
        try stderr.writeAll("^\n");
    }
}

const IgnoreNewline = struct {
    str: []const u8,

    pub fn format(
        self: *const IgnoreNewline,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        var it = std.mem.splitScalar(u8, self.str, '\n');
        while (it.next()) |substr| {
            if (substr.len > 0) {
                // first non-space character
                const start_idx = blk: {
                    for (substr, 0..) |char, idx| {
                        if (char != ' ' and char != '\t')
                            break :blk idx;
                    }
                    break :blk 0;
                };
                try writer.print(" {s}", .{substr[start_idx..]});
            }
        }
    }
};
// Taken from Sphaerophoria -- https://github.com/sphaerophoria/sphwayland-client
//-------------------------------------------------------------------------------
const SnakeToPascal = struct {
    name: []const u8,

    pub fn format(
        self: *const SnakeToPascal,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        var it = std.mem.splitScalar(u8, self.name, '_');
        while (it.next()) |elem| {
            var it_dot = std.mem.splitScalar(u8, elem, '.');
            var idx: u32 = 0;
            while (it_dot.next()) |inner| : (idx += 1) {
                if (idx > 0) try writer.print(".", .{});
                try printWithUpperFirstChar(writer, inner);
            }
            // try printWithUpperFirstChar(writer, elem);
        }
    }
};
fn printWithUpperFirstChar(writer: anytype, s: []const u8) !void {
    switch (s.len) {
        0 => return,
        1 => try writer.writeByte(std.ascii.toUpper(s[0])),
        else => {
            const first_char = std.ascii.toUpper(s[0]);
            try writer.print("{c}{s}", .{ first_char, s[1..] });
        },
    }
}

fn snakeToPascal(s: []const u8) SnakeToPascal {
    return .{ .name = s };
}
//-------------------------------------------------------------------------------
