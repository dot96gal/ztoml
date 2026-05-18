pub const Error = ParseError || DeserializeError || error{OutOfMemory};

pub const ParseError = error{
    UnexpectedEof,
    UnexpectedChar,
    InvalidEscape,
    InvalidUnicode,
    DuplicateKey,
    InvalidNumber,
    InvalidDate,
    InvalidTime,
    MaxDepthExceeded,
};

pub const DeserializeError = error{
    MissingField,
    TypeMismatch,
    IntegerOverflow,
};
