const std = @import("std");
const ztoml = @import("ztoml");

const Config = struct {
    name: []const u8,
    version: i64,
    debug: bool = false,
};

pub fn main(env: std.process.Init) !void {
    const allocator = env.gpa;

    const input =
        \\name = "ztoml"
        \\version = 1
        \\debug = false
    ;

    var result = try ztoml.parse(Config, allocator, input, .{});
    defer result.deinit();

    const config = result.value;

    var out_buf: [256]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(env.io, &out_buf);
    const stdout = &out_writer.interface;
    try stdout.print("name = {s}\n", .{config.name});
    try stdout.flush();
}
