const std = @import("std");
const toml = @import("ztoml");

const RUNS: u64 = 1000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Determine input file path: first arg or default
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const path = if (args.len > 1) args[1] else "testdata/large.toml";

    const input = try std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
    defer allocator.free(input);

    // Warm up
    for (0..10) |_| {
        var result = try toml.parseFromSlice(allocator, input, .{});
        result.deinit();
    }

    var timer = try std.time.Timer.start();
    for (0..RUNS) |_| {
        var result = try toml.parseFromSlice(allocator, input, .{});
        result.deinit();
    }
    const elapsed_ns = timer.read();

    const avg_ns = elapsed_ns / RUNS;
    const avg_us = avg_ns / 1000;
    const input_kb = input.len / 1024;

    std.debug.print("input      : {s}\n", .{path});
    std.debug.print("input size : {} bytes (~{} KB)\n", .{ input.len, input_kb });
    std.debug.print("runs       : {}\n", .{RUNS});
    std.debug.print("total time : {}ms\n", .{elapsed_ns / 1_000_000});
    std.debug.print("avg/parse  : {}ns (~{}us)\n", .{ avg_ns, avg_us });
}
