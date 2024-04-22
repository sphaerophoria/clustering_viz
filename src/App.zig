const std = @import("std");
const Allocator = std.mem.Allocator;
const Rng = std.rand.DefaultPrng;
const Self = @This();

pub const Point = struct {
    x: i32,
    y: i32,
};

points: std.ArrayList(Point),
rng: Rng,

pub fn init(alloc: Allocator) !Self {
    var points = std.ArrayList(Point).init(alloc);
    try points.resize(100);

    var seed: u64 = undefined;
    try std.os.getrandom(std.mem.asBytes(&seed));
    var rng = Rng.init(seed);

    try generatePoints(&rng, points.items);

    return .{
        .rng = rng,
        .points = points,
    };
}

pub fn deinit(self: *Self) void {
    self.points.deinit();
}

pub fn rerollPoints(self: *Self) !void {
    try generatePoints(&self.rng, self.points.items);
}

fn generatePoints(rng: *Rng, items: []Point) !void {
    const rng_if = rng.random();

    for (items) |*item| {
        const x = rng_if.intRangeAtMost(i32, 0, 100);
        const y = rng_if.intRangeAtMost(i32, 0, 100);
        item.* = .{
            .x = x,
            .y = y,
        };
    }
}
