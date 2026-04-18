const std = @import("std");
const toml = @import("ztoml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
