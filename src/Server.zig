const std = @import("std");
const App = @import("App.zig");
const resources = @import("resources");
const Allocator = std.mem.Allocator;
const NetAddr = std.net.Address;
const HttpServer = std.http.Server;
const TcpServer = std.net.Server;
const Point = App.Point;
const Clusters = App.Clusters;
const Self = @This();

app: *App,
inner: TcpServer,
alloc: Allocator,
www_root: ?std.fs.Dir,

pub fn init(alloc: Allocator, app: *App, www_root_path: ?[]const u8, ip: []const u8, port: u16) !Self {
    const addy = try NetAddr.parseIp(ip, port);
    var inner = try addy.listen(.{
        .reuse_port = true,
    });
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

        self.handleHttpRequest(&request) catch {
            std.log.err("error handling request", .{});
        };
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

const QueryParamIt = struct {
    query_params: []const u8,

    const Output = struct {
        key: []const u8,
        val: []const u8,
    };

    fn init(target: []const u8) QueryParamIt {
        const query_param_idx = std.mem.indexOfScalar(u8, target, '?') orelse target.len - 1;
        return .{
            .query_params = target[query_param_idx + 1..],
        };
    }

    fn next(self: *QueryParamIt) ?Output {
        const key_end = std.mem.indexOfScalar(u8, self.query_params, '=') orelse {
            return null;
        };
        const val_end = std.mem.indexOfScalar(u8, self.query_params, '&') orelse self.query_params.len;
        const key = self.query_params[0..key_end];
        const val = self.query_params[key_end + 1..val_end];

        self.query_params = self.query_params[@min(val_end + 1, self.query_params.len)..];

        return .{
            .key = key,
            .val = val,
        };
    }

};

fn handleReset(request: *std.http.Server.Request, app: *App) !void {
    var it = QueryParamIt.init(request.head.target);

    const KeyPurpose = enum {
        num_elems,
        num_clusters,
        cluster_radius,
        unknown,

        const KeyPurpose = @This();

        fn parse(key: []const u8) KeyPurpose {
            const Mapping = struct {
                key: []const u8,
                purpose: KeyPurpose,
            };

            const mappings = [_]Mapping{
                .{ .key = "num_elems", .purpose = .num_elems },
                .{ .key = "num_clusters", .purpose = .num_clusters },
                .{ .key = "cluster_radius", .purpose = .cluster_radius },
            };

            for (mappings) |mapping| {
                if (std.mem.eql(u8, mapping.key, key)) {
                    return mapping.purpose;
                }
            }

            return .unknown;
        }
    };

    var num_elems: usize  = 100;
    var num_clusters: usize  = 7;
    var cluster_radius: f32  = 5;

    while (it.next()) |query_param| {
        switch (KeyPurpose.parse(query_param.key)) {
            .num_elems => {
                num_elems = try std.fmt.parseInt(usize, query_param.val, 10);
            },
            .num_clusters => {
                num_clusters = try std.fmt.parseInt(usize, query_param.val, 10);
            },
            .cluster_radius => {
                cluster_radius = try std.fmt.parseFloat(f32, query_param.val);
            },
            .unknown => {},
        }
    }

    try app.rerollPoints(num_elems, num_clusters, cluster_radius);
    try request.respond("", .{
        .keep_alive = false,
    });
}

fn handleGetClusterers(request: *std.http.Server.Request) !void {
    const http_headers = &[_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    var send_buffer: [4096]u8 = undefined;

    var response = request.respondStreaming(.{ .send_buffer = &send_buffer, .respond_options = .{
        .keep_alive = false,
        .extra_headers = http_headers,
    } });

    var json_writer = std.json.writeStream(response.writer(), .{});

    try json_writer.beginArray();
    inline for (std.meta.fields(App.ClustererId)) |field| {
        try json_writer.beginObject();

        try json_writer.objectField("id");
        try json_writer.write(field.value);

        try json_writer.objectField("name");
        try json_writer.write(field.name);

        try json_writer.endObject();
    }
    try json_writer.endArray();

    try response.end();
}

fn handleHttpRequest(self: *Self, request: *std.http.Server.Request) !void {
    const purpose = UriPurpose.parse(request.head.target) orelse {
        if (std.mem.eql(u8, request.head.target, "/")) {
            try self.sendFile(request, "/index.html");
        } else {
            try self.sendFile(request, request.head.target);
        }
        return;
    };

    switch (purpose) {
        .point_data => {
            try sendData(request, self.app);
        },
        .next => {
            try self.app.next();
            try request.respond("", .{
                .keep_alive = false,
            });
        },
        .reset => {
            try handleReset(request, self.app);
        },
        .get_clusterers => {
            try handleGetClusterers(request);
        },
        .set_clusterer => {
            var it = QueryParamIt.init(request.head.target);
            var id: ?App.ClustererId = null;
            while (it.next()) |query_param| {
                if (std.mem.eql(u8, "id", query_param.key)) {
                    id = @enumFromInt(try std.fmt.parseInt(u8, query_param.val, 10));
                }

            }

            const id_final = id orelse {
                std.log.err("set clusterer called with no id parameter", .{});
                return error.NoId;
            };

            try self.app.setClusterer(id_final);
            try request.respond("", .{
                .keep_alive = false,
            });
        }
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

fn writePointsJson(json_writer: anytype, points: []const Point) !void {
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

fn writeClustersJson(json_writer: anytype, clusters: *const Clusters) !void {
    try json_writer.beginArray();
    var it = clusters.clusterIt();
    while (it.next()) |item| {
        try json_writer.beginArray();
        for (item.cluster) |point| {
            try json_writer.write(point);
        }
        try json_writer.endArray();
    }

    try json_writer.endArray();
}

fn serializeDebugInfo(writer: anytype, info: App.DebugInfoElem) !void {
    switch (info) {
        .integer => |v| try writer.write(v),
        .real => |v| try writer.write(v),
        .string => |v| try writer.write(v),
        .named_vals => |items| {
            try writer.beginObject();
            for (items) |v| {
                try writer.objectField(v.key);
                try serializeDebugInfo(writer, v.val);
            }
            try writer.endObject();
        },
        .array => |arr| {
            try writer.beginArray();
            for (arr) |v| {
                try serializeDebugInfo(writer, v);
            }
            try writer.endArray();
        },

    }

}

fn writeDataJson(writer: anytype, points: []const Point, clusters: *const Clusters, debug_info: *const App.DebugInfo,) !void {
    var json_writer = std.json.writeStream(writer, .{});
    try json_writer.beginObject();

    try json_writer.objectField("points");
    try writePointsJson(&json_writer, points);

    try json_writer.objectField("clusters");
    try writeClustersJson(&json_writer, clusters);

    try json_writer.objectField("debug");
    try serializeDebugInfo(&json_writer, debug_info.root);

    try json_writer.endObject();
}

test "write json data" {
    const points = [_]Point{
        .{.x = 1, .y = 1},
        .{.x = 2, .y = 3},
        .{.x = 4, .y = 5},
    };

    var clusters = try Clusters.init(std.testing.allocator);
    defer clusters.deinit();

    const cluster_1 = try clusters.addCluster();
    const cluster_2 = try clusters.addCluster();

    try clusters.addToCluster(cluster_1, 1);
    try clusters.addToCluster(cluster_2, 0);
    try clusters.addToCluster(cluster_2, 2);

    var serialized = std.ArrayList(u8).init(std.testing.allocator);
    defer serialized.deinit();

    const debug_info = App.DebugInfo {
        .arena = null,
        .root = .{
            .string = "test",
        }
    };
    try writeDataJson(serialized.writer(), &points, &clusters, &debug_info);

    try std.testing.expectEqualStrings(
        \\{"points":[{"x":1,"y":1},{"x":2,"y":3},{"x":4,"y":5}],"clusters":[[1],[0,2]],"debug":"test"}
        , serialized.items);
}

fn sendData(request: *std.http.Server.Request, app: *App) !void {
    const http_headers = &[_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    var send_buffer: [4096]u8 = undefined;

    var response = request.respondStreaming(.{ .send_buffer = &send_buffer, .respond_options = .{
        .keep_alive = false,
        .extra_headers = http_headers,
    } });

    var debug_info = try app.getDebugData();
    defer debug_info.deinit();
    try writeDataJson(response.writer(), app.points.items, &app.clusters, &debug_info);
    try response.end();
}

const UriPurpose = enum {
    point_data,
    next,
    reset,
    get_clusterers,
    set_clusterer,

    fn parse(target: []const u8) ?UriPurpose {
        const Mapping = struct {
            uri: []const u8,
            match_type: enum {
                begin,
                exact,
            } = .exact,
            purpose: UriPurpose,
        };

        // zig fmt: off
        const mappings = [_]Mapping{
            .{ .uri = "/data",  .purpose = .point_data},
            .{ .uri = "/next",  .purpose = .next },
            .{ .uri = "/reset", .purpose = .reset, .match_type = .begin },
            .{ .uri = "/clusterers", .purpose = .get_clusterers },
            .{ .uri = "/set_clusterer", .purpose = .set_clusterer, .match_type = .begin, },
        };

        for (mappings) |mapping| {
            switch (mapping.match_type) {
                .begin => {
                    if (std.mem.startsWith(u8, target, mapping.uri)) {
                        return mapping.purpose;
                    }
                },
                .exact => {
                    if (std.mem.eql(u8, target, mapping.uri)) {
                        return mapping.purpose;
                    }
                }
            }
        }

        return null;
    }
};

