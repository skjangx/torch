const std = @import("std");
const proxy_streams = @import("proxy_streams.zig");
const pty_host = @import("pty_host.zig");
const serialize = @import("serialize.zig");
const session_registry = @import("session_registry.zig");
const terminal_session = @import("terminal_session.zig");

pub const AttachmentResult = struct {
    attachment_id: []const u8,
    cols: u16,
    rows: u16,
};

pub const OpenTerminalResult = struct {
    status: session_registry.SessionStatus,
    attachment_id: []const u8,
    offset: u64,
};

pub const ReadTerminalResult = struct {
    data: []u8,
    offset: u64,
    base_offset: u64,
    truncated: bool,
    eof: bool,
};

const RuntimeSession = struct {
    pty: pty_host.PtyHost,
    terminal: terminal_session.TerminalSession,

    fn init(alloc: std.mem.Allocator, command: []const u8, cols: u16, rows: u16) !RuntimeSession {
        return .{
            .pty = try pty_host.PtyHost.init(alloc, command, cols, rows),
            .terminal = try terminal_session.TerminalSession.init(alloc, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback = 100_000,
            }),
        };
    }

    fn deinit(self: *RuntimeSession) void {
        self.terminal.deinit();
        self.pty.deinit();
    }

    fn resize(self: *RuntimeSession, cols: u16, rows: u16) !void {
        try self.pty.resize(cols, rows);
        try self.terminal.resize(cols, rows);
    }

    fn read(self: *RuntimeSession, alloc: std.mem.Allocator, offset: u64, max_bytes: usize, timeout_ms: i32) !ReadTerminalResult {
        const start_ms = std.time.milliTimestamp();

        while (true) {
            try self.pty.pump(&self.terminal);

            const window = self.terminal.offsetWindow();
            var effective_offset = offset;
            const truncated = effective_offset < window.base_offset;
            if (effective_offset < window.base_offset) effective_offset = window.base_offset;

            if (effective_offset < window.next_offset) {
                const raw = try self.terminal.readRaw(alloc, offset, max_bytes);
                return .{
                    .data = raw.data,
                    .offset = raw.offset,
                    .base_offset = raw.base_offset,
                    .truncated = raw.truncated,
                    .eof = self.pty.isClosed() and raw.offset >= window.next_offset,
                };
            }

            if (self.pty.isClosed()) {
                return .{
                    .data = try alloc.dupe(u8, ""),
                    .offset = window.next_offset,
                    .base_offset = window.base_offset,
                    .truncated = truncated,
                    .eof = true,
                };
            }

            const wait_ms = if (timeout_ms <= 0) -1 else blk: {
                const elapsed = std.time.milliTimestamp() - start_ms;
                const remaining = @as(i64, timeout_ms) - elapsed;
                if (remaining <= 0) return error.ReadTimeout;
                break :blk @as(i32, @intCast(remaining));
            };
            const ready = try self.pty.waitReadable(wait_ms);
            if (!ready) return error.ReadTimeout;
        }
    }
};

pub const Service = struct {
    alloc: std.mem.Allocator,
    proxies: proxy_streams.Manager,
    registry: session_registry.Registry,
    runtimes: std.StringHashMap(*RuntimeSession),

    pub fn init(alloc: std.mem.Allocator) Service {
        return .{
            .alloc = alloc,
            .proxies = proxy_streams.Manager.init(alloc),
            .registry = session_registry.Registry.init(alloc),
            .runtimes = std.StringHashMap(*RuntimeSession).init(alloc),
        };
    }

    pub fn deinit(self: *Service) void {
        var iter = self.runtimes.iterator();
        while (iter.next()) |runtime| {
            self.alloc.free(runtime.key_ptr.*);
            runtime.value_ptr.*.deinit();
            self.alloc.destroy(runtime.value_ptr.*);
        }
        self.runtimes.deinit();
        self.proxies.deinit();
        self.registry.deinit();
    }

    pub fn openProxy(self: *Service, host: []const u8, port: u16) ![]const u8 {
        return self.proxies.open(host, port);
    }

    pub fn closeProxy(self: *Service, stream_id: []const u8) !void {
        try self.proxies.close(stream_id);
    }

    pub fn writeProxy(self: *Service, stream_id: []const u8, payload: []const u8) !usize {
        return self.proxies.write(stream_id, payload);
    }

    pub fn readProxy(self: *Service, stream_id: []const u8, max_bytes: usize, timeout_ms: i32) !proxy_streams.ReadResult {
        return self.proxies.read(self.alloc, stream_id, max_bytes, timeout_ms);
    }

    pub fn openSession(self: *Service, maybe_session_id: ?[]const u8) !session_registry.SessionStatus {
        const session_id = try self.registry.ensure(maybe_session_id);
        defer self.alloc.free(session_id);
        return self.registry.status(session_id);
    }

    pub fn closeSession(self: *Service, session_id: []const u8) !void {
        try self.registry.close(session_id);
        self.removeRuntime(session_id);
    }

    pub fn attachSession(self: *Service, session_id: []const u8, attachment_id: []const u8, cols: u16, rows: u16) !session_registry.SessionStatus {
        try self.registry.attach(session_id, attachment_id, cols, rows);
        var status = try self.registry.status(session_id);
        errdefer status.deinit(self.alloc);
        try self.resizeRuntimeIfPresent(&status);
        return status;
    }

    pub fn resizeSession(self: *Service, session_id: []const u8, attachment_id: []const u8, cols: u16, rows: u16) !session_registry.SessionStatus {
        try self.registry.resize(session_id, attachment_id, cols, rows);
        var status = try self.registry.status(session_id);
        errdefer status.deinit(self.alloc);
        try self.resizeRuntimeIfPresent(&status);
        return status;
    }

    pub fn detachSession(self: *Service, session_id: []const u8, attachment_id: []const u8) !session_registry.SessionStatus {
        try self.registry.detach(session_id, attachment_id);
        var status = try self.registry.status(session_id);
        errdefer status.deinit(self.alloc);
        try self.resizeRuntimeIfPresent(&status);
        return status;
    }

    pub fn sessionStatus(self: *Service, session_id: []const u8) !session_registry.SessionStatus {
        return self.registry.status(session_id);
    }

    pub fn openTerminal(self: *Service, maybe_session_id: ?[]const u8, command: []const u8, cols: u16, rows: u16) !OpenTerminalResult {
        const opened = try self.registry.open(maybe_session_id, cols, rows);
        errdefer {
            self.registry.close(opened.session_id) catch {};
            self.alloc.free(opened.session_id);
            self.alloc.free(opened.attachment_id);
        }

        var status = try self.registry.status(opened.session_id);
        errdefer status.deinit(self.alloc);

        const runtime = try self.alloc.create(RuntimeSession);
        errdefer self.alloc.destroy(runtime);
        runtime.* = try RuntimeSession.init(self.alloc, command, status.effective_cols, status.effective_rows);
        errdefer runtime.deinit();

        try self.runtimes.put(opened.session_id, runtime);
        return .{
            .status = status,
            .attachment_id = opened.attachment_id,
            .offset = 0,
        };
    }

    pub fn readTerminal(self: *Service, session_id: []const u8, offset: u64, max_bytes: usize, timeout_ms: i32) !ReadTerminalResult {
        const runtime = self.runtimes.getPtr(session_id) orelse return error.TerminalSessionNotFound;
        return runtime.*.*.read(self.alloc, offset, max_bytes, timeout_ms);
    }

    pub fn writeTerminal(self: *Service, session_id: []const u8, data: []const u8) !usize {
        const runtime = self.runtimes.getPtr(session_id) orelse return error.TerminalSessionNotFound;
        try runtime.*.*.pty.write(data);
        return data.len;
    }

    pub fn history(self: *Service, session_id: []const u8, format: serialize.HistoryFormat) ![]u8 {
        const runtime = self.runtimes.getPtr(session_id) orelse return error.TerminalSessionNotFound;
        try runtime.*.*.pty.pump(&runtime.*.*.terminal);
        return runtime.*.*.terminal.history(self.alloc, format);
    }

    fn resizeRuntimeIfPresent(self: *Service, status: *const session_registry.SessionStatus) !void {
        const runtime = self.runtimes.getPtr(status.session_id) orelse return;
        try runtime.*.*.resize(status.effective_cols, status.effective_rows);
    }

    fn removeRuntime(self: *Service, session_id: []const u8) void {
        const removed = self.runtimes.fetchRemove(session_id) orelse return;
        self.alloc.free(removed.key);
        removed.value.deinit();
        self.alloc.destroy(removed.value);
    }
};

test "open terminal returns named session when requested" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal("dev", "printf READY", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    try std.testing.expectEqualStrings("dev", opened.status.session_id);
    try std.testing.expectEqualStrings("att-1", opened.attachment_id);
}

test "terminal read returns subprocess output" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal(null, "printf READY", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    const read = try service.readTerminal(opened.status.session_id, 0, 32, 1000);
    defer std.testing.allocator.free(read.data);

    try std.testing.expect(std.mem.indexOf(u8, read.data, "READY") != null);
}
