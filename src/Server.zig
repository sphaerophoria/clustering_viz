const std = @import("std");
const App = @import("App.zig");
const Allocator = std.mem.Allocator;
const NetAddr = std.net.Address;
const HttpServer = std.http.Server;
const TcpServer = std.net.Server;
const Point = App.Point;
const Self = @This();

app: *App,
inner: TcpServer,
alloc: Allocator,
www_root: ?std.fs.Dir,

pub fn init(alloc: Allocator, app: *App, www_root_path: ?[]const u8, ip: []const u8, port: u16) !Self {
    const addy = try NetAddr.parseIp(ip, port);
    var inner = try addy.listen(.{});
    errdefer inner.deinit();

    var www_root: ?std.fs.Dir = null;
    if (www_root_path) |path| {
        www_root = try std.fs.cwd().openDir(path, .{});
    }

    return .{
        .app = app,
        .alloc = alloc,
        .inner = inner,
        .www_root = www_root,
    };
}

pub fn deinit(self: *Self) void {
    self.inner.deinit();
}

pub fn run(self: *Self) !void {
    while (true) {
        var pfd = std.mem.zeroInit(std.posix.pollfd, .{});
        pfd.fd = self.inner.stream.handle;
        pfd.events = std.posix.POLL.IN;

        var pfds = [1]std.posix.pollfd{pfd};
        const num_set = std.posix.ppoll(&pfds, null, null) catch |e| {
            if (e == std.posix.PPollError.SignalInterrupt) {
                return;
            }
            return e;
        };
        std.debug.assert(num_set == 1); // Should have got something

        const connection = try self.inner.accept();

        var read_buffer: [4096]u8 = undefined;
        var server = HttpServer.init(connection, &read_buffer);
        var request = try server.receiveHead();

        self.handleHttpRequest(&request, self.app) catch {};
    }
}

fn handleHttpRequest(self: *Self, request: *std.http.Server.Request, app: *App) !void {
    const purpose = try UriPurpose.parse(request.head.target);
    switch (purpose) {
        .index_html => try self.sendFile(request, "index.html", "text/html"),
        .index_js => try self.sendFile(request, "index.js", "text/javascript"),
        .point_data => try sendPoints(request, app),
        .ignored => try ignoreRequest(request),
    }
}

fn copyFile(response: *HttpServer.Response, reader: anytype) !void {
    var fifo = std.fifo.LinearFifo(u8, .{
        .Static = 4096,
    }).init();

    try fifo.pump(reader, response);
}

fn embeddedLookup(path: []const u8) ![]const u8 {
    const Elem = struct {
        path: []const u8,
        data: []const u8,
    };

    const elems = [_]Elem{
        .{ .path = "index.html", .data = @embedFile("res/index.html") },
        .{ .path = "index.js", .data = @embedFile("res/index.js") },
    };

    for (elems) |elem| {
        if (std.mem.eql(u8, elem.path, path)) {
            return elem.data;
        }
    }
    return error.InvalidPath;
}

fn sendFile(self: *Self, request: *HttpServer.Request, path: []const u8, content_type: []const u8) !void {
    const http_headers = &[_]std.http.Header{
        .{ .name = "content-type", .value = content_type },
    };

    var send_buffer: [4096]u8 = undefined;

    var response = request.respondStreaming(.{ .send_buffer = &send_buffer, .respond_options = .{
        .keep_alive = false,
        .extra_headers = http_headers,
    } });

    if (self.www_root) |www_root| {
        try copyFile(&response, (try www_root.openFile(path, .{})).reader());
    } else {
        const embedded = try embeddedLookup(path);
        var fbs = std.io.fixedBufferStream(embedded);
        const html = fbs.reader();
        try copyFile(&response, html);
    }

    try response.end();
}

fn writePointsJson(writer: anytype, points: []const Point) !void {
    var json_writer = std.json.writeStream(writer, .{});
    try json_writer.beginArray();
    for (points) |point| {
        try json_writer.beginObject();
        try json_writer.objectField("x");
        try json_writer.write(point.x);
        try json_writer.objectField("y");
        try json_writer.write(point.y);
        try json_writer.endObject();
    }

    try json_writer.endArray();
}

fn sendPoints(request: *std.http.Server.Request, app: *App) !void {
    const http_headers = &[_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    var send_buffer: [4096]u8 = undefined;

    var response = request.respondStreaming(.{ .send_buffer = &send_buffer, .respond_options = .{
        .keep_alive = false,
        .extra_headers = http_headers,
    } });

    try app.rerollPoints();
    try writePointsJson(response.writer(), app.points.items);
    try response.end();
}

const UriPurpose = enum {
    index_html,
    index_js,
    point_data,
    ignored,

    fn parse(target: []const u8) !UriPurpose {
        const Mapping = struct {
            uri: []const u8,
            purpose: UriPurpose,
        };

        // zig fmt: off
        const mappings = [_]Mapping{
            .{ .uri = "/",            .purpose = .index_html },
            .{ .uri = "/index.html",  .purpose = .index_html },
            .{ .uri = "/index.js",    .purpose = .index_js },
            .{ .uri = "/points",      .purpose = .point_data },
            .{ .uri = "/favicon.ico", .purpose = .ignored },
        };

        for (mappings) |mapping| {
            if (std.mem.eql(u8, target, mapping.uri)) {
                return mapping.purpose;
            }
        }

        std.log.err("Unknown target: {s}", .{target});
        return error.Unimplemented;
    }
};

fn ignoreRequest(response: *std.http.Server.Request) !void {
    try response.respond("", .{
        .keep_alive = false,
        .status = .not_found,
    });
}

