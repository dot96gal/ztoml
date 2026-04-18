const std = @import("std");
const toml = @import("ztoml");

const RUNS: u64 = 1000;

pub fn main(env: std.process.Init) !void {
    const allocator = env.gpa;
    const io = env.io;
    const raw_args = try env.minimal.args.toSlice(env.arena.allocator());

    const path = if (raw_args.len > 1) raw_args[1] else "testdata/large.toml";

    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    defer allocator.free(input);

    // Warm up
    for (0..10) |_| {
        var result = try toml.parseFromSlice(allocator, input, .{});
        result.deinit();
    }

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..RUNS) |_| {
        var result = try toml.parseFromSlice(allocator, input, .{});
        result.deinit();
    }
    const elapsed_ns: u64 = @intCast(start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toNanoseconds());

    const avg_ns = elapsed_ns / RUNS;
    const avg_us = avg_ns / 1000;
    const input_kb = input.len / 1024;

    std.debug.print("input      : {s}\n", .{path});
    std.debug.print("input size : {} bytes (~{} KB)\n", .{ input.len, input_kb });
    std.debug.print("runs       : {}\n", .{RUNS});
    std.debug.print("total time : {}ms\n", .{elapsed_ns / 1_000_000});
    std.debug.print("avg/parse  : {}ns (~{}us)\n", .{ avg_ns, avg_us });
}
