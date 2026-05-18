const std = @import("std");
const ztoml = @import("ztoml");

const runs: u64 = 1000;

const Server = struct {
    host: []const u8 = "",
    port: i64 = 0,
    debug: bool = false,
    max_connections: i64 = 0,
    timeout_ms: i64 = 0,
    read_timeout_ms: i64 = 0,
    write_timeout_ms: i64 = 0,
    idle_timeout_ms: i64 = 0,
};

const Replica = struct {
    host: []const u8 = "",
    port: i64 = 0,
    pool_size: i64 = 0,
};

const Database = struct {
    host: []const u8 = "",
    port: i64 = 0,
    name: []const u8 = "",
    user: []const u8 = "",
    password: []const u8 = "",
    pool_size: i64 = 0,
    max_idle: i64 = 0,
    connect_timeout: i64 = 0,
    max_lifetime_ms: i64 = 0,
    replica: Replica = .{},
};

const Logging = struct {
    level: []const u8 = "",
    format: []const u8 = "",
    output: []const u8 = "",
    file: []const u8 = "",
    max_size_mb: i64 = 0,
    max_backups: i64 = 0,
    max_age_days: i64 = 0,
    compress: bool = false,
};

const Cache = struct {
    enabled: bool = false,
    host: []const u8 = "",
    port: i64 = 0,
    db: i64 = 0,
    password: []const u8 = "",
    pool_size: i64 = 0,
    ttl_seconds: i64 = 0,
    max_memory_mb: i64 = 0,
};

const AuthProviders = struct {
    google_client_id: []const u8 = "",
    github_client_id: []const u8 = "",
};

const Auth = struct {
    secret: []const u8 = "",
    expiry_hours: i64 = 0,
    refresh_expiry_hours: i64 = 0,
    algorithm: []const u8 = "",
    issuer: []const u8 = "",
    providers: AuthProviders = .{},
};

const Features = struct {
    enable_analytics: bool = false,
    enable_notifications: bool = false,
    enable_beta: bool = false,
    enable_dark_mode: bool = false,
    maintenance_mode: bool = false,
    rate_limiting: bool = false,
    max_requests_per_minute: i64 = 0,
};

const Metrics = struct {
    enabled: bool = false,
    host: []const u8 = "",
    port: i64 = 0,
    path: []const u8 = "",
    interval_seconds: i64 = 0,
};

const User = struct {
    id: i64 = 0,
    name: []const u8 = "",
    email: []const u8 = "",
    role: []const u8 = "",
    active: bool = false,
    score: f64 = 0,
};

const Product = struct {
    id: i64 = 0,
    name: []const u8 = "",
    price: f64 = 0,
    stock: i64 = 0,
    category: []const u8 = "",
    tags: [][]const u8 = &.{},
};

const Network = struct {
    bind_address: []const u8 = "",
    port: i64 = 0,
    tls_enabled: bool = false,
    cert_file: []const u8 = "",
    key_file: []const u8 = "",
    allowed_origins: [][]const u8 = &.{},
    trusted_proxies: [][]const u8 = &.{},
};

const I18n = struct {
    default_locale: []const u8 = "",
    supported_locales: [][]const u8 = &.{},
    fallback_locale: []const u8 = "",
    timezone: []const u8 = "",
};

const Storage = struct {
    @"type": []const u8 = "",
    bucket: []const u8 = "",
    region: []const u8 = "",
    prefix: []const u8 = "",
    max_upload_size_mb: i64 = 0,
    allowed_types: [][]const u8 = &.{},
};

const Email = struct {
    smtp_host: []const u8 = "",
    smtp_port: i64 = 0,
    smtp_user: []const u8 = "",
    smtp_password: []const u8 = "",
    from_name: []const u8 = "",
    from_address: []const u8 = "",
    use_tls: bool = false,
};

const Notifications = struct {
    slack_webhook: []const u8 = "",
    pagerduty_key: []const u8 = "",
    email_on_error: bool = false,
    error_threshold: i64 = 0,
    cooldown_minutes: i64 = 0,
};

const RateLimits = struct {
    global_rps: i64 = 0,
    per_user_rps: i64 = 0,
    per_ip_rps: i64 = 0,
    burst_size: i64 = 0,
    window_seconds: i64 = 0,
};

const HealthCheck = struct {
    enabled: bool = false,
    path: []const u8 = "",
    interval_seconds: i64 = 0,
    timeout_seconds: i64 = 0,
    unhealthy_threshold: i64 = 0,
    healthy_threshold: i64 = 0,
};

const Config = struct {
    title: []const u8 = "",
    version: []const u8 = "",
    description: []const u8 = "",
    server: Server = .{},
    database: Database = .{},
    logging: Logging = .{},
    cache: Cache = .{},
    auth: Auth = .{},
    features: Features = .{},
    metrics: Metrics = .{},
    users: []User = &.{},
    products: []Product = &.{},
    network: Network = .{},
    i18n: I18n = .{},
    storage: Storage = .{},
    email: Email = .{},
    notifications: Notifications = .{},
    rate_limits: RateLimits = .{},
    health_check: HealthCheck = .{},
};

pub fn main(env: std.process.Init) !void {
    const allocator = env.gpa;
    const io = env.io;
    const raw_args = try env.minimal.args.toSlice(env.arena.allocator());

    const path = if (raw_args.len > 1) raw_args[1] else "testdata/large.toml";

    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(
        io,
        path,
        allocator,
        std.Io.Limit.limited(10 * 1024 * 1024),
    );
    defer allocator.free(input);

    for (0..10) |_| {
        var result = try ztoml.parse(Config, allocator, input, .{});
        defer result.deinit();
    }

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..runs) |_| {
        var result = try ztoml.parse(Config, allocator, input, .{});
        defer result.deinit();
    }
    const elapsed_ns: u64 = @intCast(
        start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toNanoseconds(),
    );

    const avg_ns = elapsed_ns / runs;
    const avg_us = avg_ns / 1000;
    const input_kb = input.len / 1024;

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buf);
    const stdout = &out_writer.interface;
    try stdout.print("input      : {s}\n", .{path});
    try stdout.print("input size : {} bytes (~{} KB)\n", .{ input.len, input_kb });
    try stdout.print("runs       : {}\n", .{runs});
    try stdout.print("total time : {}ms\n", .{elapsed_ns / 1_000_000});
    try stdout.print("avg/parse  : {}ns (~{}us)\n", .{ avg_ns, avg_us });
    try stdout.flush();
}
