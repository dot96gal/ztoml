const std = @import("std");
const types = @import("types.zig");
const parser_mod = @import("parser.zig");
const deserialize_mod = @import("deserialize.zig");

pub const TOMLValue = types.TOMLValue;
pub const TOMLTable = types.TOMLTable;
pub const Parsed = types.Parsed;
pub const ParseOptions = types.ParseOptions;
pub const Diagnostic = types.Diagnostic;
pub const ParseError = types.ParseError;
pub const parseFromSlice = parser_mod.parseFromSlice;
pub const parseFromSliceAs = deserialize_mod.parseFromSliceAs;
pub const DeserializeError = deserialize_mod.DeserializeError;
pub const TomlError = ParseError || DeserializeError;

test {
    _ = types;
    _ = parser_mod;
    _ = deserialize_mod;
}
