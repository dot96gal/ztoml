const std = @import("std");
const toml = @import("ztoml");

pub fn main(env: std.process.Init) !void {
    const allocator = env.gpa;

    const input =
        \\name = "ztoml"
        \\version = 1
        \\debug = false
    ;

    var result = try toml.parseFromSlice(allocator, input, .{});
    defer result.deinit();

    const name = result.value.get("name") orelse unreachable;
    std.debug.print("name = {s}\n", .{name.string});
}
