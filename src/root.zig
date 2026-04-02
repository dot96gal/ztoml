const toml = @import("toml/mod.zig");

pub const TOMLValue = toml.TOMLValue;
pub const TOMLTable = toml.TOMLTable;
pub const Parsed = toml.Parsed;
pub const ParseOptions = toml.ParseOptions;
pub const Diagnostic = toml.Diagnostic;
pub const ParseError = toml.ParseError;
pub const DeserializeError = toml.DeserializeError;
pub const TomlError = toml.TomlError;
pub const parseFromSlice = toml.parseFromSlice;
pub const parseFromSliceAs = toml.parseFromSliceAs;

test {
    _ = toml;
}
