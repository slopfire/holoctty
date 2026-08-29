const std = @import("std");
const builtin = @import("builtin");

const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.gtk_holoctty_folder_icons);

pub const current_version: u32 = 1;
pub const max_file_size = 1024 * 1024;
pub const max_rules = 512;
pub const max_icon_string_len = 4096;

pub const Color = enum {
    grey,
    blue,
    red,
    yellow,
    green,
    pink,
    purple,
    cyan,

    pub fn label(self: Color) [:0]const u8 {
        return switch (self) {
            .grey => "Grey",
            .blue => "Blue",
            .red => "Red",
            .yellow => "Yellow",
            .green => "Green",
            .pink => "Pink",
            .purple => "Purple",
            .cyan => "Cyan",
        };
    }

    pub fn cssClass(self: Color) [:0]const u8 {
        return switch (self) {
            .grey => "folder-icon-grey",
            .blue => "folder-icon-blue",
            .red => "folder-icon-red",
            .yellow => "folder-icon-yellow",
            .green => "folder-icon-green",
            .pink => "folder-icon-pink",
            .purple => "folder-icon-purple",
            .cyan => "folder-icon-cyan",
        };
    }
};

pub const Glyph = enum {
    folder,
    git,
    server,

    pub fn label(self: Glyph) [:0]const u8 {
        return switch (self) {
            .folder => "Folder",
            .git => "Git Repository",
            .server => "Server",
        };
    }

    pub fn iconName(self: Glyph) [:0]const u8 {
        return switch (self) {
            .folder => "folder-symbolic",
            .git => "holoctty-cli-folder-git-symbolic",
            .server => "holoctty-cli-remote-server-symbolic",
        };
    }
};

pub const Tinted = struct {
    glyph: Glyph,
    color: Color,
};

pub const Icon = union(enum) {
    /// Version 1 stored tinted folders as a bare color. Keep reading it.
    color: Color,
    tinted: Tinted,
    theme: []const u8,
    uri: []const u8,
};

pub const Rule = struct {
    path: []const u8,
    icon: Icon,
};

pub const RemoteRule = struct {
    host: []const u8,
    icon: Icon,
};

pub const Library = struct {
    version: u32 = current_version,
    rules: []const Rule = &.{},
    remote_rules: []const RemoteRule = &.{},
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    value: Library,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

var cached: ?Loaded = null;
var cache_initialized = false;

/// Resolve the closest icon assignment for `pwd`. The returned strings are
/// borrowed from the process-wide cache and remain valid until the next edit.
pub fn resolve(pwd: []const u8) ?Icon {
    ensureCache();
    const loaded = if (cached) |*value| value else return null;
    return resolveIn(loaded.value, pwd);
}

pub fn resolveRemote(host: []const u8) ?Icon {
    ensureCache();
    const loaded = if (cached) |*value| value else return null;
    return resolveRemoteIn(loaded.value, host);
}

pub fn hasExact(pwd: []const u8) bool {
    ensureCache();
    const loaded = if (cached) |*value| value else return false;
    const normalized = normalizePath(pwd);
    for (loaded.value.rules) |rule| {
        if (std.mem.eql(u8, rule.path, normalized)) return true;
    }
    return false;
}

pub fn hasExactRemote(host: []const u8) bool {
    ensureCache();
    const loaded = if (cached) |*value| value else return false;
    const normalized = normalizeHost(host);
    for (loaded.value.remote_rules) |rule| {
        if (std.ascii.eqlIgnoreCase(rule.host, normalized)) return true;
    }
    return false;
}

pub fn assign(pwd: []const u8, icon: Icon) !void {
    const alloc = std.heap.c_allocator;
    const path = try defaultPath(alloc);
    defer alloc.free(path);
    try upsert(global.io(), alloc, path, .{
        .path = normalizePath(pwd),
        .icon = icon,
    });
    try reloadCache();
}

pub fn assignRemote(host: []const u8, icon: Icon) !void {
    const alloc = std.heap.c_allocator;
    const path = try defaultPath(alloc);
    defer alloc.free(path);
    try upsertRemote(global.io(), alloc, path, .{
        .host = normalizeHost(host),
        .icon = icon,
    });
    try reloadCache();
}

pub fn remove(pwd: []const u8) !bool {
    const alloc = std.heap.c_allocator;
    const path = try defaultPath(alloc);
    defer alloc.free(path);
    const removed = try delete(global.io(), alloc, path, normalizePath(pwd));
    if (removed) try reloadCache();
    return removed;
}

pub fn removeRemote(host: []const u8) !bool {
    const alloc = std.heap.c_allocator;
    const path = try defaultPath(alloc);
    defer alloc.free(path);
    const removed = try deleteRemote(
        global.io(),
        alloc,
        path,
        normalizeHost(host),
    );
    if (removed) try reloadCache();
    return removed;
}

fn ensureCache() void {
    if (cache_initialized) return;
    cache_initialized = true;
    reloadCache() catch |err| {
        log.warn("unable to load folder icons err={}", .{err});
    };
}

fn reloadCache() !void {
    const alloc = std.heap.c_allocator;
    const path = try defaultPath(alloc);
    defer alloc.free(path);
    var loaded = try load(global.io(), alloc, path);
    errdefer loaded.deinit();
    if (cached) |*old| old.deinit();
    cached = loaded;
    cache_initialized = true;
}

pub fn defaultPath(alloc: Allocator) ![]u8 {
    var environ = try global.environMap();
    defer environ.deinit();
    const state_dir = try internal_os.xdg.state(
        global.io(),
        alloc,
        &environ,
        .{ .subdir = "holoctty" },
    );
    defer alloc.free(state_dir);
    return std.fs.path.join(alloc, &.{ state_dir, "folder-icons.json" });
}

pub fn load(io: std.Io, alloc: Allocator, path: []const u8) !Loaded {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();

    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .value = .{} },
        else => return err,
    };
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    const bytes = try file_reader.interface.allocRemaining(
        arena.allocator(),
        .limited(max_file_size),
    );
    const value = try std.json.parseFromSliceLeaky(
        Library,
        arena.allocator(),
        bytes,
        .{ .ignore_unknown_fields = true },
    );
    try validate(arena.allocator(), value);
    return .{ .arena = arena, .value = value };
}

pub fn upsert(
    io: std.Io,
    alloc: Allocator,
    path: []const u8,
    rule: Rule,
) !void {
    var loaded = try load(io, alloc, path);
    defer loaded.deinit();

    var rules = try std.ArrayList(Rule).initCapacity(
        alloc,
        @min(loaded.value.rules.len + 1, max_rules + 1),
    );
    defer rules.deinit(alloc);
    var replaced = false;
    for (loaded.value.rules) |existing| {
        if (std.mem.eql(u8, existing.path, rule.path)) {
            try rules.append(alloc, rule);
            replaced = true;
        } else {
            try rules.append(alloc, existing);
        }
    }
    if (!replaced) try rules.append(alloc, rule);

    const library: Library = .{
        .rules = rules.items,
        .remote_rules = loaded.value.remote_rules,
    };
    try validate(alloc, library);
    try writeAtomic(io, alloc, path, library);
}

pub fn upsertRemote(
    io: std.Io,
    alloc: Allocator,
    path: []const u8,
    rule: RemoteRule,
) !void {
    var loaded = try load(io, alloc, path);
    defer loaded.deinit();

    var rules = try std.ArrayList(RemoteRule).initCapacity(
        alloc,
        @min(loaded.value.remote_rules.len + 1, max_rules + 1),
    );
    defer rules.deinit(alloc);
    var replaced = false;
    for (loaded.value.remote_rules) |existing| {
        if (std.ascii.eqlIgnoreCase(existing.host, rule.host)) {
            try rules.append(alloc, rule);
            replaced = true;
        } else {
            try rules.append(alloc, existing);
        }
    }
    if (!replaced) try rules.append(alloc, rule);

    const library: Library = .{
        .rules = loaded.value.rules,
        .remote_rules = rules.items,
    };
    try validate(alloc, library);
    try writeAtomic(io, alloc, path, library);
}

pub fn delete(
    io: std.Io,
    alloc: Allocator,
    path: []const u8,
    pwd: []const u8,
) !bool {
    var loaded = try load(io, alloc, path);
    defer loaded.deinit();
    var rules = try std.ArrayList(Rule).initCapacity(
        alloc,
        loaded.value.rules.len,
    );
    defer rules.deinit(alloc);
    var found = false;
    for (loaded.value.rules) |rule| {
        if (std.mem.eql(u8, rule.path, pwd)) {
            found = true;
        } else {
            try rules.append(alloc, rule);
        }
    }
    if (!found) return false;
    try writeAtomic(io, alloc, path, .{
        .rules = rules.items,
        .remote_rules = loaded.value.remote_rules,
    });
    return true;
}

pub fn deleteRemote(
    io: std.Io,
    alloc: Allocator,
    path: []const u8,
    host: []const u8,
) !bool {
    var loaded = try load(io, alloc, path);
    defer loaded.deinit();
    var rules = try std.ArrayList(RemoteRule).initCapacity(
        alloc,
        loaded.value.remote_rules.len,
    );
    defer rules.deinit(alloc);
    var found = false;
    for (loaded.value.remote_rules) |rule| {
        if (std.ascii.eqlIgnoreCase(rule.host, host)) {
            found = true;
        } else {
            try rules.append(alloc, rule);
        }
    }
    if (!found) return false;
    try writeAtomic(io, alloc, path, .{
        .rules = loaded.value.rules,
        .remote_rules = rules.items,
    });
    return true;
}

pub fn resolveIn(library: Library, pwd: []const u8) ?Icon {
    const child = normalizePath(pwd);
    var best: ?*const Rule = null;
    for (library.rules) |*rule| {
        if (!pathContains(rule.path, child)) continue;
        if (best == null or rule.path.len > best.?.path.len) best = rule;
    }
    return if (best) |rule| rule.icon else null;
}

pub fn resolveRemoteIn(library: Library, host: []const u8) ?Icon {
    const normalized = normalizeHost(host);
    for (library.remote_rules) |rule| {
        if (std.ascii.eqlIgnoreCase(rule.host, normalized)) return rule.icon;
    }
    return null;
}

fn normalizePath(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    return if (trimmed.len == 0 and path.len > 0 and path[0] == '/') "/" else trimmed;
}

fn normalizeHost(host: []const u8) []const u8 {
    return std.mem.trim(u8, host, " \t\r\n");
}

fn pathContains(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, "/")) return child.len > 0 and child[0] == '/';
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child.len == parent.len or
        (child.len > parent.len and child[parent.len] == '/');
}

fn validate(alloc: Allocator, library: Library) !void {
    if (library.version != current_version) return error.UnsupportedVersion;
    if (library.rules.len + library.remote_rules.len > max_rules)
        return error.TooManyRules;
    var paths = std.StringHashMap(void).init(alloc);
    defer paths.deinit();
    for (library.rules) |rule| {
        if (!std.fs.path.isAbsolute(rule.path)) return error.PathNotAbsolute;
        if (rule.path.len > std.fs.max_path_bytes) return error.PathTooLong;
        if (!std.mem.eql(u8, rule.path, normalizePath(rule.path)))
            return error.PathNotNormalized;
        if (!std.unicode.utf8ValidateSlice(rule.path)) return error.InvalidPath;
        if (std.mem.indexOfScalar(u8, rule.path, 0) != null) return error.InvalidPath;
        if (try paths.fetchPut(rule.path, {})) |_| return error.DuplicatePath;
        try validateIcon(rule.icon);
    }

    for (library.remote_rules, 0..) |rule, index| {
        if (!std.mem.eql(u8, rule.host, normalizeHost(rule.host)))
            return error.HostNotNormalized;
        try validateIconString(rule.host);
        for (library.remote_rules[0..index]) |existing| {
            if (std.ascii.eqlIgnoreCase(existing.host, rule.host))
                return error.DuplicateHost;
        }
        try validateIcon(rule.icon);
    }
}

fn validateIcon(icon: Icon) !void {
    switch (icon) {
        .color, .tinted => {},
        .theme => |name| try validateIconString(name),
        .uri => |uri| {
            try validateIconString(uri);
            const parsed = std.Uri.parse(uri) catch return error.InvalidIconUri;
            if (parsed.scheme.len == 0) return error.InvalidIconUri;
        },
    }
}

fn validateIconString(value: []const u8) !void {
    if (value.len > max_icon_string_len) return error.IconStringTooLong;
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return error.EmptyIconString;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidIconString;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidIconString;
}

fn writeAtomic(io: std.Io, alloc: Allocator, path: []const u8, library: Library) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    const temporary = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(temporary);
    errdefer std.Io.Dir.deleteFileAbsolute(io, temporary) catch {};
    const file = try std.Io.Dir.createFileAbsolute(io, temporary, .{
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
    });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    var stringify: std.json.Stringify = .{
        .writer = &file_writer.interface,
        .options = .{ .whitespace = .indent_2 },
    };
    try stringify.write(library);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
    try std.Io.Dir.renameAbsolute(temporary, path, io);
}

test "folder icon rules use the closest ancestor" {
    const library: Library = .{ .rules = &.{
        .{ .path = "/work", .icon = .{ .color = .blue } },
        .{ .path = "/work/project/docs", .icon = .{ .theme = "folder-documents" } },
    } };
    try validate(std.testing.allocator, library);
    try std.testing.expectEqual(Color.blue, resolveIn(library, "/work/project/src").?.color);
    try std.testing.expectEqualStrings(
        "folder-documents",
        resolveIn(library, "/work/project/docs/api").?.theme,
    );
    try std.testing.expect(resolveIn(library, "/workspace") == null);
}

test "folder icon library reads version 1 without remote rules" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const library = try std.json.parseFromSliceLeaky(
        Library,
        arena.allocator(),
        "{\"version\":1,\"rules\":[]}",
        .{ .ignore_unknown_fields = true },
    );
    try validate(std.testing.allocator, library);
    try std.testing.expectEqual(@as(usize, 0), library.remote_rules.len);
}

test "folder icon rules persist all icon sources" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &.{
        dir_buf[0..dir_len],
        "folder-icons.json",
    });
    defer testing.allocator.free(path);

    try upsert(testing.io, testing.allocator, path, .{
        .path = "/work",
        .icon = .{ .tinted = .{ .glyph = .git, .color = .purple } },
    });
    try upsert(testing.io, testing.allocator, path, .{
        .path = "/work/docs",
        .icon = .{ .theme = "folder-documents" },
    });
    try upsert(testing.io, testing.allocator, path, .{
        .path = "/images",
        .icon = .{ .uri = "file:///tmp/folder.svg" },
    });
    try upsertRemote(testing.io, testing.allocator, path, .{
        .host = "buildbox",
        .icon = .{ .tinted = .{ .glyph = .server, .color = .cyan } },
    });
    var loaded = try load(testing.io, testing.allocator, path);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 3), loaded.value.rules.len);
    try testing.expectEqual(@as(usize, 1), loaded.value.remote_rules.len);
    try testing.expectEqualStrings(
        "folder-documents",
        resolveIn(loaded.value, "/work/docs/api").?.theme,
    );
    try testing.expect(try delete(testing.io, testing.allocator, path, "/work/docs"));
    var after_delete = try load(testing.io, testing.allocator, path);
    defer after_delete.deinit();
    try testing.expectEqual(
        Glyph.git,
        resolveIn(after_delete.value, "/work/docs/api").?.tinted.glyph,
    );
    try testing.expectEqual(
        Color.cyan,
        resolveRemoteIn(after_delete.value, "BUILDBOX").?.tinted.color,
    );
    try testing.expect(try deleteRemote(
        testing.io,
        testing.allocator,
        path,
        "BuildBox",
    ));
}
