const std = @import("std");
const App = @import("App.zig");
const Allocator = std.mem.Allocator;
const NetAddr = std.net.Address;
const HttpServer = std.http.Server;
const Point = App.Point;
const Self = @This();

app: *App,
inner: HttpServer,
alloc: Allocator,
www_root: ?std.fs.Dir,

pub fn init(alloc: Allocator, app: *App, www_root_path: ?[]const u8, ip: []const u8, port: u16) !Self {
    var inner = HttpServer.init(alloc, .{
        .reuse_port = true,
    });
    errdefer inner.deinit();

    var addy = try NetAddr.parseIp(ip, port);
    try inner.listen(addy);

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
        var pfd = std.mem.zeroInit(std.os.pollfd, .{});
        pfd.fd = self.inner.socket.sockfd.?;
        pfd.events = std.os.POLL.IN;

        var pfds = [1]std.os.pollfd{pfd};
        const num_set = std.os.ppoll(&pfds, null, null) catch |e| {
            if (e == std.os.PPollError.SignalInterrupt) {
                return;
            }
            return e;
        };

        std.debug.assert(num_set == 1); // Should have got something
        var response = try self.inner.accept(.{
            .allocator = self.alloc,
        });
        defer response.deinit();
        try response.wait();

        self.handleHttpRequest(&response, self.app) catch {};
    }
}

fn handleHttpRequest(self: *Self, response: *std.http.Server.Response, app: *App) !void {
    response.transfer_encoding = .chunked;
    try response.headers.append("connection", "close");

    const purpose = try UriPurpose.parse(response.request.target);

    switch (purpose) {
        .index_html => try self.sendFile(response, "index.html", "text/html"),
        .index_js => try self.sendFile(response, "index.js", "text/javascript"),
        .point_data => try sendPoints(response, app),
        .ignored => try ignoreRequest(response),
    }
}

fn copyFile(response: *HttpServer.Response, reader: anytype) !void {
    var fifo = std.fifo.LinearFifo(u8, .{
        .Static = 4096,
    }).init();

    try fifo.pump(reader, response);
    try response.finish();
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

fn sendFile(self: *Self, response: *std.http.Server.Response, path: []const u8, content_type: []const u8) !void {
    try response.headers.append("content-type", content_type);
    try response.do();

    if (self.www_root) |www_root| {
        try copyFile(response, (try www_root.openFile(path, .{})).reader());
    } else {
        var embedded = try embeddedLookup(path);
        var fbs = std.io.fixedBufferStream(embedded);
        var html = fbs.reader();
        try copyFile(response, html);
    }
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

fn sendPoints(response: *std.http.Server.Response, app: *App) !void {
    try app.rerollPoints();
    try response.headers.append("content-type", "application/json");
    try response.do();
    try writePointsJson(response.writer(), app.points.items);
    try response.finish();
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

fn ignoreRequest(response: *std.http.Server.Response) !void {
    response.status = std.http.Status.not_found;
    try response.do();
    try response.finish();
}

