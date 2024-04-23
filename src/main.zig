const std = @import("std");
const App = @import("App.zig");
const Server = @import("Server.zig");

const Allocator = std.mem.Allocator;

var sigint_caught = std.atomic.Value(bool).init(false);

fn shouldQuit() bool {
    return sigint_caught.load(std.builtin.AtomicOrder.unordered);
}

fn signal_handler(_: c_int) align(1) callconv(.C) void {
    sigint_caught.store(true, std.builtin.AtomicOrder.unordered);
}

fn registerSignalHandler() !void {
    var sa = std.posix.Sigaction{
        .handler = .{
            .handler = &signal_handler,
        },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };

    try std.posix.sigaction(std.posix.SIG.INT, &sa, null);
}

const ArgMapping = struct {
    arg: []const u8,
    purpose: ArgPurpose,
    help: []const u8,
};

const arg_mappings = [_]ArgMapping{
    .{ .arg = "--help", .purpose = .help, .help = "Show this help" },
    .{ .arg = "--www-root", .purpose = .www_root, .help = "Optional, use this directory for html/js/css files" },
    .{ .arg = "--server-address", .purpose = .server_address, .help = "Optional, address to serve from, defaults to 127.0.0.1" },
    .{ .arg = "--server-port", .purpose = .server_port, .help = "Optional, port to serve from, defaults to 9999" },
};

const ArgPurpose = enum {
    www_root,
    server_address,
    server_port,
    help,
    none,

    fn parse(arg: []const u8) ArgPurpose {
        for (arg_mappings) |mapping| {
            if (std.mem.eql(u8, arg, mapping.arg)) {
                return mapping.purpose;
            }
        }

        return .none;
    }
};

fn print_stderr(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print(fmt, args) catch {};
}

const Args = struct {
    arena: std.heap.ArenaAllocator,
    www_root: ?[]const u8,
    server_address: []const u8,
    server_port: u16,

    fn deinit(self: *Args) void {
        self.arena.deinit();
    }

    fn parse(child_alloc: Allocator) !Args {
        var arena = std.heap.ArenaAllocator.init(child_alloc);
        errdefer arena.deinit();

        const alloc = arena.allocator();

        var it = try std.process.argsWithAllocator(alloc);
        const process_name = it.next() orelse "clustering_viz";
        var www_root: ?[]const u8 = null;
        var server_address: []const u8 = "127.0.0.1";
        var server_port: u16 = 9999;

        while (it.next()) |arg| {
            switch (ArgPurpose.parse(arg)) {
                .www_root => {
                    www_root = it.next() orelse {
                        print_stderr("No argument provided for --www-root", .{});
                        help(process_name);
                    };
                },
                .server_address => {
                    server_address = it.next() orelse {
                        print_stderr("No argument provided for --server-address", .{});
                        help(process_name);
                    };
                },
                .server_port => {
                    const port_s = it.next() orelse {
                        print_stderr("No argument provided for --server-port", .{});
                        help(process_name);
                    };
                    server_port = std.fmt.parseInt(u16, port_s, 10) catch {
                        print_stderr("Invalid port value", .{});
                        help(process_name);
                    };
                },
                .help => {
                    help(process_name);
                },
                .none => {
                    print_stderr("Unknown argument: {s}\n", .{arg});
                    help(process_name);
                },
            }
        }

        return .{
            .arena = arena,
            .www_root = www_root,
            .server_address = server_address,
            .server_port = server_port,
        };
    }

    fn help(process_name: []const u8) noreturn {
        print_stderr(
            \\Usage: {s} [ARGS]
            \\
            \\Args:
            \\
        , .{process_name});

        for (arg_mappings) |arg| {
            print_stderr("{s}: {s}\n", .{ arg.arg, arg.help });
        }
        std.process.exit(1);
    }
};

pub fn main() !void {
    try registerSignalHandler();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.process.exit(1);
        }
    }

    const alloc = gpa.allocator();

    var args = try Args.parse(alloc);
    defer args.deinit();

    var app = try App.init(alloc);
    defer app.deinit();

    var server = try Server.init(
        alloc,
        &app,
        args.www_root,
        args.server_address,
        args.server_port,
    );
    defer server.deinit();

    while (!shouldQuit()) {
        try server.run();
    }

    std.log.info("Caught SIGINT: exiting", .{});
}
