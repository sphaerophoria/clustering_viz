const std = @import("std");
const App = @import("App.zig");
const resources = @import("resources");
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

fn mimetypeFromPath(p: []const u8) ![]const u8 {
    const Mapping = struct {
        ext: []const u8,
        mime: []const u8,
    };

    // zig fmt: off
    const mappings = [_]Mapping{
        .{ .ext = ".js",   .mime = "text/javascript" },
        .{ .ext = ".html", .mime = "text/html" },
    };

    for (mappings) |mapping| {
        if (std.mem.endsWith(u8, p, mapping.ext)) {
            return mapping.mime;
        }
    }

    std.log.err("Unknown mimetype for {s}", .{p});
    return error.Unknown;
}

fn handleHttpRequest(self: *Self, request: *std.http.Server.Request, app: *App) !void {
    if (std.mem.eql(u8, request.head.target, "/points")) {
        try sendPoints(request, app);
    } else if (std.mem.eql(u8, request.head.target, "/")) {
        try self.sendFile(request, "/index.html");
    } else {
        try self.sendFile(request, request.head.target);
    }
}

fn copyFile(response: *HttpServer.Response, reader: anytype) !void {
    var fifo = std.fifo.LinearFifo(u8, .{
        .Static = 4096,
    }).init();

    try fifo.pump(reader, response);
}

fn embeddedLookup(path: []const u8) ![]const u8 {
    for (resources.resources) |elem| {
        if (std.mem.eql(u8, elem.path, path)) {
            return elem.data;
        }
    }
    std.log.err("No file {s} embedded in application", .{path});
    return error.InvalidPath;
}

fn sendFile(self: *Self, request: *HttpServer.Request, path_abs: []const u8) !void {
    const path = path_abs[1..];
    const http_headers = &[_]std.http.Header{
        .{ .name = "content-type", .value = try mimetypeFromPath(path) },
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
