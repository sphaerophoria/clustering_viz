const std = @import("std");
const Allocator = std.mem.Allocator;
const Rng = std.rand.DefaultPrng;
const Self = @This();

pub const DebugInfoPair = struct {
    key: []const u8,
    val: DebugInfoElem,
};

pub const DebugInfoElem = union(enum) {
    integer: i64,
    real: f32,
    string: []const u8,
    named_vals: []const DebugInfoPair,
    array: []const DebugInfoElem,
};

pub const DebugInfo = struct {
    arena: ?std.heap.ArenaAllocator,
    root: DebugInfoElem,

    fn empty() DebugInfo {
        return .{
            .arena = null,
            .root = .{ .named_vals = &[_]DebugInfoPair{} },
        };
    }

    pub fn deinit(self: *DebugInfo) void {
        if (self.arena) |*arena| {
            arena.deinit();
        }
    }
};

pub const ClustererIf = struct {
    vtable: struct {
        next: *const fn (*ClustererIf, []const Point, *Clusters) anyerror!void,
        reset: *const fn (*ClustererIf, []const Point, *Clusters) anyerror!void,
        getDebugData: ?*const fn (*ClustererIf) anyerror!DebugInfo = null,
        free: *const fn (*ClustererIf) void,
    },

    fn next(self: *ClustererIf, points: []const Point, clusters: *Clusters) !void {
        return self.vtable.next(self, points, clusters);
    }

    fn reset(self: *ClustererIf, points: []const Point, clusters: *Clusters) !void {
        return self.vtable.reset(self, points, clusters);
    }

    fn getDebugData(self: *ClustererIf) !DebugInfo {
        if (self.vtable.getDebugData) |f| {
            return f(self);
        } else {
            return DebugInfo.empty();
        }
    }

    fn deinit(self: *ClustererIf) void {
        self.vtable.free(self);
    }
};

pub const AgglomerativeClusterer = struct {
    alloc: Allocator,
    distances: std.ArrayList(PointPair),
    clusterer_if: ClustererIf,

    const PointPair = struct {
        a: usize,
        b: usize,
        distance: f32,

        fn fromPoints(points: []const Point, a: usize, b: usize) PointPair {
            const ax: f32 = @floatFromInt(points[a].x);
            const ay: f32 = @floatFromInt(points[a].y);
            const bx: f32 = @floatFromInt(points[b].x);
            const by: f32 = @floatFromInt(points[b].y);
            const x_dist: f32 = ax - bx;
            const y_dist: f32 = ay - by;
            const distance: f32 = x_dist * x_dist + y_dist * y_dist;
            return .{
                .a = a,
                .b = b,
                .distance = distance,
            };
        }

        fn greaterThan(_: void, lhs: PointPair, rhs: PointPair) bool {
            return lhs.distance > rhs.distance;
        }
    };

    pub fn init(alloc: Allocator) !*ClustererIf {
        var distances = std.ArrayList(PointPair).init(alloc);
        errdefer distances.deinit();

        var clusterer_if = try alloc.create(AgglomerativeClusterer);
        errdefer alloc.destroy(clusterer_if);

        clusterer_if.alloc = alloc;
        clusterer_if.distances = distances;
        clusterer_if.clusterer_if.vtable = .{
            .next = AgglomerativeClusterer.next,
            .reset = AgglomerativeClusterer.reset,
            .free = AgglomerativeClusterer.free,
        };

        return &clusterer_if.clusterer_if;
    }

    fn free(clusterer_if: *ClustererIf) void {
        const self: *AgglomerativeClusterer = @fieldParentPtr("clusterer_if", clusterer_if);
        self.distances.deinit();
        self.alloc.destroy(self);
    }

    fn reset(clusterer_if: *ClustererIf, points: []const Point, clusters: *Clusters) anyerror!void {
        const self: *AgglomerativeClusterer = @fieldParentPtr("clusterer_if", clusterer_if);

        self.distances.clearAndFree();
        try self.distances.ensureTotalCapacity(points.len * points.len);

        for (0..points.len) |i| {
            const cluster_id = try clusters.addCluster();
            try clusters.addToCluster(cluster_id, i);

            for (0..points.len) |j| {
                if (i == j) {
                    continue;
                }

                try self.distances.append(PointPair.fromPoints(points, i, j));
            }
        }

        std.sort.pdq(PointPair, self.distances.items, {}, PointPair.greaterThan);
    }

    /// Invalid to call if clusters has been modified outside of our clusterer.
    fn next(clusterer_if: *ClustererIf, _: []const Point, clusters: *Clusters) anyerror!void {
        const self: *AgglomerativeClusterer = @fieldParentPtr("clusterer_if", clusterer_if);

        while (true) {
            if (self.distances.items.len < 1) {
                return;
            }

            const point_pair = self.distances.pop();

            const a_cluster = clusters.clusterContainingPoint(point_pair.a).?;
            const b_cluster = clusters.clusterContainingPoint(point_pair.b).?;
            if (a_cluster == b_cluster) {
                continue;
            }

            try clusters.merge(a_cluster, b_cluster);
            break;
        }
    }
};

pub const DianaClusterer = struct {
    alloc: Allocator,
    clusterer_if: ClustererIf,

    pub fn init(alloc: Allocator) !*ClustererIf {
        var clusterer = try alloc.create(DianaClusterer);
        errdefer alloc.destroy(clusterer);

        clusterer.alloc = alloc;
        clusterer.clusterer_if.vtable = .{
            .next = DianaClusterer.next,
            .reset = DianaClusterer.reset,
            .free = DianaClusterer.free,
        };

        return &clusterer.clusterer_if;
    }

    fn maxDistanceBetweenPoints(point_ids: []const usize, points: []const Point) f32 {
        var max: f32 = 0;
        for (point_ids) |a| {
            for (point_ids) |b| {
                if (a == b) {
                    continue;
                }

                max = @max(max, Point.distance_2(&points[a], &points[b]));
            }
        }

        return max;
    }

    fn averageDistanceBetweenPoints(point_id: usize, point_ids: []const usize, points: []const Point) f32 {
        var sum_total: f32 = 0;
        var offset: usize = 0;
        for (point_ids) |other_point_id| {
            if (point_id == other_point_id) {
                offset += 1;
                continue;
            }

            sum_total += Point.distance_2(&points[point_id], &points[other_point_id]);
        }

        return sum_total / @as(f32, @floatFromInt((point_ids.len - offset)));
    }

    /// Find the cluster that has the largest distance between two points
    /// Returns the index of the largest cluster
    fn findBiggestCluster(points: []const Point, clusters: *const Clusters) usize {
        var cluster_it = clusters.clusterIt();

        var max_cluster_id: usize = 0;
        const first_cluster = cluster_it.next() orelse {
            std.debug.panic("Clusters not initialized for DianaClusterer", .{});
        };
        var max_cluster_distance = maxDistanceBetweenPoints(first_cluster.cluster, points);

        while (cluster_it.next()) |item| {
            const cluster_distance = maxDistanceBetweenPoints(item.cluster, points);
            if (cluster_distance > max_cluster_distance) {
                max_cluster_id = item.cluster_id;
                max_cluster_distance = cluster_distance;
            }
        }

        return max_cluster_id;
    }

    fn findMostDissimilarPointInCluster(cluster: []const usize, points: []const Point) usize {
        var ret: usize = std.math.maxInt(usize);
        var ret_avg_dist: f32 = 0.0;
        for (cluster) |point_id| {
            const avg_dist = averageDistanceBetweenPoints(point_id, cluster, points);

            if (avg_dist > ret_avg_dist) {
                ret_avg_dist = avg_dist;
                ret = point_id;
            }
        }

        return ret;
    }

    fn findPointToMove(from: []const usize, to: []const usize, points: []const Point) ?usize {
        var best_candidate: usize = 0;
        var best_candidate_score: f32 = -std.math.floatMax(f32);

        for (from) |point_id| {
            const score =
                averageDistanceBetweenPoints(point_id, from, points) -
                averageDistanceBetweenPoints(point_id, to, points);

            if (score > best_candidate_score) {
                best_candidate = point_id;
                best_candidate_score = score;
            }
        }

        if (best_candidate_score < 0) {
            return null;
        }

        return best_candidate;
    }

    fn next(_: *ClustererIf, points: []const Point, clusters: *Clusters) anyerror!void {
        const biggest_cluster_id = findBiggestCluster(points, clusters);
        const most_dissimilar_point = findMostDissimilarPointInCluster(clusters.getCluster(biggest_cluster_id), points);

        const new_cluster_id = try clusters.addCluster();

        clusters.removeFromCluster(biggest_cluster_id, most_dissimilar_point);
        try clusters.addToCluster(new_cluster_id, most_dissimilar_point);

        while (true) {
            const next_evicted_point = findPointToMove(
                clusters.getCluster(biggest_cluster_id),
                clusters.getCluster(new_cluster_id),
                points,
            ) orelse {
                break;
            };

            clusters.removeFromCluster(biggest_cluster_id, next_evicted_point);
            try clusters.addToCluster(new_cluster_id, next_evicted_point);
        }
    }

    fn reset(_: *ClustererIf, points: []const Point, clusters: *Clusters) anyerror!void {
        const cluster_id = try clusters.addCluster();
        for (0..points.len) |point_id| {
            _ = try clusters.addToCluster(cluster_id, point_id);
        }
    }

    fn free(clusterer_if: *ClustererIf) void {
        const self: *DianaClusterer = @fieldParentPtr("clusterer_if", clusterer_if);
        self.alloc.destroy(self);
    }
};

pub const KMeansClusterer = struct {
    alloc: Allocator,
    means: std.ArrayList(Point),
    clusterer_if: ClustererIf,
    rng: Rng,
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,

    pub fn init(alloc: Allocator, num_clusters: usize) !*ClustererIf {
        var clusterer = try alloc.create(KMeansClusterer);
        errdefer alloc.destroy(clusterer);

        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        const rng = Rng.init(seed);

        var means = std.ArrayList(Point).init(alloc);
        try means.resize(num_clusters);

        clusterer.alloc = alloc;
        clusterer.means = means;
        clusterer.rng = rng;
        clusterer.clusterer_if.vtable = .{
            .next = KMeansClusterer.next,
            .reset = KMeansClusterer.reset,
            .getDebugData = KMeansClusterer.getDebugData,
            .free = KMeansClusterer.free,
        };

        return &clusterer.clusterer_if;
    }

    fn assignClusters(alloc: Allocator, means: []const Point, points: []const Point, clusters: *Clusters) !void {

        // Other clustering algorithms update the clusters every step. K means
        // re-calculates every cluster based off the current means
        clusters.clear();
        for (0..means.len) |_| {
            _ = try clusters.addCluster();
        }

        // Scratch space to figure out which cluster is best for each point
        // Dynamically allocated because we need one per mean (runtime value)
        // Allocated once to avoid allocating in the loop
        var distance_to_means = try alloc.alloc(f32, means.len);
        defer alloc.free(distance_to_means);

        for (points, 0..) |*point, point_id| {
            for (means, 0..) |mean, idx| {
                distance_to_means[idx] = mean.distance_2(point);
            }

            const best_cluster = std.mem.indexOfMin(f32, distance_to_means);
            try clusters.addToCluster(best_cluster, point_id);
        }
    }

    fn updateMeans(self: *KMeansClusterer, points: []const Point, clusters: *const Clusters) !void {
        var cluster_it = clusters.clusterIt();
        while (cluster_it.next()) |cluster_item| {
            // If the cluster has no elements, other clusters beat it for every
            // single point. Randomize the mean to try to split up another
            // cluster
            if (cluster_item.cluster.len == 0) {
                self.means.items[cluster_item.cluster_id].x = self.rng.random().intRangeAtMost(i32, self.min_x, self.max_x);
                self.means.items[cluster_item.cluster_id].y = self.rng.random().intRangeAtMost(i32, self.min_y, self.max_y);
                continue;
            }

            var avg_x: f32 = 0;
            var avg_y: f32 = 0;
            for (cluster_item.cluster) |point_id| {
                avg_x += @floatFromInt(points[point_id].x);
                avg_y += @floatFromInt(points[point_id].y);
            }

            avg_x /= @floatFromInt(cluster_item.cluster.len);
            avg_y /= @floatFromInt(cluster_item.cluster.len);

            self.means.items[cluster_item.cluster_id] = .{
                .x = @intFromFloat(@round(avg_x)),
                .y = @intFromFloat(@round(avg_y)),
            };
        }
    }

    fn next(clusterer_if: *ClustererIf, points: []const Point, clusters: *Clusters) anyerror!void {
        const self: *KMeansClusterer = @fieldParentPtr("clusterer_if", clusterer_if);

        try assignClusters(self.alloc, self.means.items, points, clusters);
        try self.updateMeans(points, clusters);
    }

    fn reset(clusterer_if: *ClustererIf, points: []const Point, clusters: *Clusters) anyerror!void {
        const self: *KMeansClusterer = @fieldParentPtr("clusterer_if", clusterer_if);

        self.min_x = std.math.maxInt(i32);
        self.min_y = std.math.maxInt(i32);
        self.max_x = std.math.minInt(i32);
        self.max_y = std.math.minInt(i32);

        for (points) |point| {
            self.min_x = @min(self.min_x, point.x);
            self.min_y = @min(self.min_y, point.y);
            self.max_x = @max(self.max_x, point.x);
            self.max_y = @max(self.max_y, point.y);
        }

        for (self.means.items) |*mean| {
            mean.x = self.rng.random().intRangeAtMost(i32, self.min_x, self.max_x);
            mean.y = self.rng.random().intRangeAtMost(i32, self.min_y, self.max_y);
        }

        try clusterer_if.next(points, clusters);
    }

    fn getDebugData(clusterer_if: *ClustererIf) anyerror!DebugInfo {
        const self: *KMeansClusterer = @fieldParentPtr("clusterer_if", clusterer_if);

        var arena = std.heap.ArenaAllocator.init(self.alloc);
        errdefer arena.deinit();

        const alloc = arena.allocator();

        const debug_means = try alloc.alloc(DebugInfoElem, self.means.items.len);

        for (self.means.items, debug_means) |input, *output| {
            var elems = try alloc.alloc(DebugInfoPair, 2);
            elems[0].key = "x";
            elems[0].val = .{
                .integer = input.x,
            };

            elems[1].key = "y";
            elems[1].val = .{
                .integer = input.y,
            };

            output.* = .{
                .named_vals = elems,
            };
        }

        var root = try alloc.alloc(DebugInfoPair, 2);
        root[0].key = "type";
        root[0].val = .{
            .string = "k_means",
        };

        root[1].key = "means";
        root[1].val = .{
            .array = debug_means,
        };

        return .{ .arena = arena, .root = .{
            .named_vals = root,
        } };
    }

    fn free(clusterer_if: *ClustererIf) void {
        const self: *KMeansClusterer = @fieldParentPtr("clusterer_if", clusterer_if);
        self.means.deinit();
        self.alloc.destroy(self);
    }
};

fn clusterMatches(cluster: []const usize, expected: []const usize) bool {
    if (cluster.len != expected.len) {
        return false;
    }

    for (expected) |item| {
        var found = false;
        for (cluster) |cluster_item| {
            if (cluster_item == item) {
                found = true;
                break;
            }
        }

        if (!found) {
            return false;
        }
    }

    return true;
}

test "cluster matches" {
    try std.testing.expect(clusterMatches(&[_]usize{ 1, 4, 5 }, &[_]usize{ 5, 1, 4 }));
    try std.testing.expect(!clusterMatches(&[_]usize{ 1, 4 }, &[_]usize{ 5, 1, 4 }));
    try std.testing.expect(!clusterMatches(&[_]usize{ 1, 4, 5 }, &[_]usize{ 1, 4 }));
}

fn clustersMatch(clusters: *Clusters, comptime expected: []const []const usize) bool {
    var found = [_]bool{false} ** expected.len;

    var cluster_it = clusters.clusterIt();
    while (cluster_it.next()) |item| {
        for (expected, 0..) |expected_cluster, expected_idx| {
            if (clusterMatches(item.cluster, expected_cluster)) {
                found[expected_idx] = true;
            }
        }
    }

    for (found) |b| {
        if (!b) {
            return false;
        }
    }

    return true;
}

test "Agglomerative Clusterer" {
    const points = [_]Point{
        .{ .x = 4, .y = 7 },
        .{ .x = 2, .y = 1 },
        .{ .x = 1, .y = 2 },
        .{ .x = 9, .y = 12 },
        .{ .x = 5, .y = 5 },
    };

    var clusters = try Clusters.init(std.testing.allocator);
    defer clusters.deinit();

    var clusterer = try AgglomerativeClusterer.init(std.testing.allocator);
    defer clusterer.deinit();

    try clusterer.reset(&points, &clusters);

    // On init we should have one cluster for each point
    try std.testing.expectEqual(clusters.clusters.items.len, points.len);

    // White box test assuming that the clusters will be in order
    var clusterIt = clusters.clusterIt();
    var i: usize = 0;
    while (clusterIt.next()) |item| {
        try std.testing.expectEqualSlices(usize, &[_]usize{i}, item.cluster);
        i += 1;
    }

    try clusterer.next(&points, &clusters);
    try std.testing.expect(clustersMatch(&clusters, &[_][]const usize{
        &[_]usize{0},
        &[_]usize{ 1, 2 },
        &[_]usize{},
        &[_]usize{3},
        &[_]usize{4},
    }));

    try clusterer.next(&points, &clusters);
    try std.testing.expect(clustersMatch(&clusters, &[_][]const usize{
        &[_]usize{ 0, 4 },
        &[_]usize{ 1, 2 },
        &[_]usize{},
        &[_]usize{3},
        &[_]usize{},
    }));

    try clusterer.next(&points, &clusters);
    try std.testing.expect(clustersMatch(&clusters, &[_][]const usize{
        &[_]usize{},
        &[_]usize{ 1, 2, 0, 4 },
        &[_]usize{},
        &[_]usize{3},
        &[_]usize{},
    }));
}

pub const Point = struct {
    x: i32,
    y: i32,

    fn distance_2(a: *const Point, b: *const Point) f32 {
        const ax: f32 = @floatFromInt(a.x);
        const ay: f32 = @floatFromInt(a.y);
        const bx: f32 = @floatFromInt(b.x);
        const by: f32 = @floatFromInt(b.y);
        const x_dist: f32 = ax - bx;
        const y_dist: f32 = ay - by;
        return x_dist * x_dist + y_dist * y_dist;
    }
};

pub const ClusterIt = struct {
    clusters: []const std.ArrayListUnmanaged(usize),
    i: usize,

    const Output = struct {
        cluster_id: usize,
        cluster: []const usize,
    };

    pub fn next(self: *ClusterIt) ?Output {
        if (self.i >= self.clusters.len) {
            return null;
        }

        defer self.i += 1;
        return .{
            .cluster_id = self.i,
            .cluster = self.clusters[self.i].items,
        };
    }
};

pub const Clusters = struct {
    //! Abstraction around groupings of point IDs. This is a glorified 2d list of
    //! the form [ [0, 3, 5], [7, 9, 11] ]

    /// Use a private arena allocator so that we don't have to worry about
    /// walking the inner lists on free
    arena: std.heap.ArenaAllocator,

    // NOTE: Managed array lists would result in a self referential struct, as
    // the ArrayList would hold a pointer to the arena above
    clusters: std.ArrayListUnmanaged(std.ArrayListUnmanaged(usize)),

    pub fn init(child_alloc: Allocator) !Clusters {
        const arena = std.heap.ArenaAllocator.init(child_alloc);
        const clusters = std.ArrayListUnmanaged(std.ArrayListUnmanaged(usize)){};

        return .{
            .arena = arena,
            .clusters = clusters,
        };
    }

    pub fn clusterIt(self: *const Clusters) ClusterIt {
        return .{
            .clusters = self.clusters.items,
            .i = 0,
        };
    }

    pub fn getCluster(self: *const Clusters, cluster_id: usize) []const usize {
        return self.clusters.items[cluster_id].items;
    }

    pub fn addCluster(self: *Clusters) !usize {
        try self.clusters.append(self.arena.allocator(), std.ArrayListUnmanaged(usize){});
        return self.clusters.items.len - 1;
    }

    pub fn addToCluster(self: *Clusters, cluster_id: usize, point_id: usize) !void {
        const cluster = &self.clusters.items[cluster_id];
        try cluster.append(self.arena.allocator(), point_id);
    }

    pub fn removeFromCluster(self: *Clusters, cluster_id: usize, point_id: usize) void {
        const cluster: *std.ArrayListUnmanaged(usize) = &self.clusters.items[cluster_id];
        const point_id_idx = std.mem.indexOfScalar(usize, cluster.items, point_id) orelse {
            std.debug.panic("point id was not in cluster", .{});
        };

        _ = cluster.swapRemove(point_id_idx);
    }

    pub fn clusterContainingPoint(self: *Clusters, point_id: usize) ?usize {
        for (self.clusters.items, 0..) |cluster, cluster_id| {
            for (cluster.items) |cluster_point| {
                if (cluster_point == point_id) {
                    return cluster_id;
                }
            }
        }

        return null;
    }

    pub fn merge(self: *Clusters, a_id: usize, b_id: usize) !void {
        if (a_id == b_id) {
            return;
        }

        var a = &self.clusters.items[a_id];
        var b = &self.clusters.items[b_id];

        if (a.items.len < b.items.len) {
            std.mem.swap(@TypeOf(a), &a, &b);
        }

        const alloc = self.arena.allocator();
        for (b.items) |b_point| {
            try a.append(alloc, b_point);
        }

        // NOTE: We do not actually remove the cluster. This is intentional. As
        // we merge clusters, we want to make sure that each cluster keeps the
        // same cluster id. This may be a little wasteful, but we release the
        // memory of the inner ArrayList so I'm not too worried about it
        b.clearAndFree(alloc);
    }

    pub fn clear(self: *Clusters) void {
        self.clusters = std.ArrayListUnmanaged(std.ArrayListUnmanaged(usize)){};
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn deinit(self: *Clusters) void {
        self.arena.deinit();
    }
};

pub const ClustererId = enum {
    agglomerative,
    diana,
    k_means,
};

alloc: Allocator,
points: std.ArrayList(Point),
clusters: Clusters,
rng: Rng,
clusterer: *ClustererIf,

pub fn init(alloc: Allocator) !Self {
    var points = std.ArrayList(Point).init(alloc);
    errdefer points.deinit();

    try points.resize(100);

    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    var rng = Rng.init(seed);

    try generatePoints(&rng, points.items, 5, 5);

    var clusters = try Clusters.init(alloc);
    const clusterer = try AgglomerativeClusterer.init(alloc);
    try clusterer.reset(points.items, &clusters);

    return .{
        .alloc = alloc,
        .rng = rng,
        .points = points,
        .clusters = clusters,
        .clusterer = clusterer,
    };
}

pub fn deinit(self: *Self) void {
    self.clusterer.deinit();
    self.clusters.deinit();
    self.points.deinit();
}

pub fn rerollPoints(self: *Self, num_elems: usize, num_clusters: usize, cluster_radius: f32) !void {
    try self.points.resize(num_elems);
    try generatePoints(&self.rng, self.points.items, num_clusters, cluster_radius);

    // FIXME: Idempotent operations
    self.clusters.deinit();
    self.clusters = try Clusters.init(self.alloc);

    try self.clusterer.reset(self.points.items, &self.clusters);
}

pub fn next(self: *Self) !void {
    try self.clusterer.next(self.points.items, &self.clusters);
}

pub fn setClusterer(self: *Self, new_clusterer: *ClustererIf) !void {
    var new_clusters = try Clusters.init(self.alloc);
    errdefer new_clusters.deinit();

    try new_clusterer.reset(self.points.items, &new_clusters);

    self.clusterer.deinit();
    self.clusters.deinit();
    self.clusters = new_clusters;
    self.clusterer = new_clusterer;
}

pub fn getDebugData(self: *Self) !DebugInfo {
    return self.clusterer.getDebugData();
}

fn generatePoints(rng: *Rng, items: []Point, num_clusters: usize, cluster_radius: f32) !void {
    const rng_if = rng.random();

    if (cluster_radius > 50) {
        std.log.err("cluster radius must be less than 50", .{});
        return error.InvalidData;
    }

    const remainder = items.len % num_clusters;
    const num_elems_per_bucket = items.len / num_clusters;
    var item_id: usize = 0;

    for (0..num_clusters) |bucket_id| {
        const cluster_radius_i32: i32 = @intFromFloat(cluster_radius);
        const bucket_center_x: f32 = @floatFromInt(rng_if.intRangeAtMost(i32, cluster_radius_i32, 100 - cluster_radius_i32));
        const bucket_center_y: f32 = @floatFromInt(rng_if.intRangeAtMost(i32, cluster_radius_i32, 100 - cluster_radius_i32));
        var bucket_elems = num_elems_per_bucket;
        if (bucket_id < remainder) {
            bucket_elems += 1;
        }

        for (0..bucket_elems) |_| {
            const item = &items[item_id];
            item_id += 1;
            const r = rng_if.floatNorm(f32) * cluster_radius;
            const theta = rng_if.float(f32) * 2 * std.math.pi;
            const x = r * std.math.cos(theta);
            const y = r * std.math.sin(theta);
            item.* = .{
                .x = @intFromFloat(@round(x) + bucket_center_x),
                .y = @intFromFloat(@round(y) + bucket_center_y),
            };
        }
    }
}
