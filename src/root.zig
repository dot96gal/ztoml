const std = @import("std");
const types = @import("types.zig");
const parserMod = @import("parser.zig");
const deserializeMod = @import("deserialize.zig");

pub const TOMLValue = types.TOMLValue;
pub const TOMLTable = types.TOMLTable;
pub const Parsed = types.Parsed;
pub const ParseOptions = types.ParseOptions;
pub const Diagnostic = types.Diagnostic;
pub const ParseError = types.ParseError;
pub const parseFromSlice = parserMod.parseFromSlice;
pub const parseFromSliceAs = deserializeMod.parseFromSliceAs;
pub const DeserializeError = deserializeMod.DeserializeError;
pub const TomlError = ParseError || DeserializeError || error{OutOfMemory};

test {
    _ = types;
    _ = parserMod;
    _ = deserializeMod;
}
