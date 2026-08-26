const std = @import("std");
const builtin = @import("builtin");

const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");

const Allocator = std.mem.Allocator;

pub const current_version: u32 = 1;
pub const max_file_size = 8 * 1024 * 1024;
pub const max_snapshots = 256;
pub const max_tabs = 256;
pub const max_nodes = 1024;

pub const Library = struct {
    version: u32 = current_version,
    snapshots: []const Snapshot = &.{},
};

pub const Snapshot = struct {
    name: []const u8,
    selected_tab: u32,
    groups: []const Group = &.{},
    tabs: []const Tab,
};

pub const Tab = struct {
    title: ?[]const u8 = null,
    group: ?u32 = null,
    tree: Tree,
};

pub const Tree = struct {
    nodes: []const Node,
    focused: u32,
    zoomed: ?u32 = null,
};

pub const Node = union(enum) {
    pane: Pane,
    split: Split,
};

pub const Split = struct {
    layout: Layout,
    ratio: f32,
    left: u32,
    right: u32,

    pub const Layout = enum {
        horizontal,
        vertical,
    };
};

pub const Pane = struct {
    working_directory: ?[]const u8 = null,
    title: ?[]const u8 = null,
    launch_command: ?LaunchCommand = null,
};

pub const LaunchCommand = union(enum) {
    shell: []const u8,
    direct: []const []const u8,
};

pub const Group = struct {
    name: ?[]const u8 = null,
    color: Color,
    collapsed: bool = false,

    pub const Color = enum {
        grey,
        blue,
        red,
        yellow,
        green,
        pink,
        purple,
        cyan,
    };
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    value: Library,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

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
    return try std.fs.path.join(alloc, &.{ state_dir, "session-snapshots.json" });
}

pub fn load(io: std.Io, alloc: Allocator, path: []const u8) !Loaded {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();

    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{
            .arena = arena,
            .value = .{},
        },
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
    snapshot: Snapshot,
) !void {
    var loaded = try load(io, alloc, path);
    defer loaded.deinit();

    var snapshots = try std.ArrayList(Snapshot).initCapacity(
        alloc,
        @min(loaded.value.snapshots.len + 1, max_snapshots + 1),
    );
    defer snapshots.deinit(alloc);

    var replaced = false;
    for (loaded.value.snapshots) |existing| {
        if (std.mem.eql(u8, existing.name, snapshot.name)) {
            try snapshots.append(alloc, snapshot);
            replaced = true;
        } else {
            try snapshots.append(alloc, existing);
        }
    }
    if (!replaced) try snapshots.append(alloc, snapshot);

    const library: Library = .{ .snapshots = snapshots.items };
    try validate(alloc, library);
    try writeAtomic(io, alloc, path, library);
}

pub fn rename(
    io: std.Io,
    alloc: Allocator,
    path: []const u8,
    old_name: []const u8,
    new_name: []const u8,
) !bool {
    var loaded = try load(io, alloc, path);
    defer loaded.deinit();

    var found = false;
    var snapshots = try std.ArrayList(Snapshot).initCapacity(
        alloc,
        loaded.value.snapshots.len,
    );
    defer snapshots.deinit(alloc);

    for (loaded.value.snapshots) |existing| {
        if (std.mem.eql(u8, existing.name, new_name)) continue;
        var copy = existing;
        if (std.mem.eql(u8, existing.name, old_name)) {
            copy.name = new_name;
            found = true;
        }
        try snapshots.append(alloc, copy);
    }
    if (!found) return false;

    const library: Library = .{ .snapshots = snapshots.items };
    try validate(alloc, library);
    try writeAtomic(io, alloc, path, library);
    return true;
}

pub fn delete(
    io: std.Io,
    alloc: Allocator,
    path: []const u8,
    name: []const u8,
) !bool {
    var loaded = try load(io, alloc, path);
    defer loaded.deinit();

    var found = false;
    var snapshots = try std.ArrayList(Snapshot).initCapacity(
        alloc,
        loaded.value.snapshots.len,
    );
    defer snapshots.deinit(alloc);
    for (loaded.value.snapshots) |existing| {
        if (std.mem.eql(u8, existing.name, name)) {
            found = true;
            continue;
        }
        try snapshots.append(alloc, existing);
    }
    if (!found) return false;

    const library: Library = .{ .snapshots = snapshots.items };
    try writeAtomic(io, alloc, path, library);
    return true;
}

pub fn find(library: Library, name: []const u8) ?*const Snapshot {
    for (library.snapshots) |*snapshot| {
        if (std.mem.eql(u8, snapshot.name, name)) return snapshot;
    }
    return null;
}

pub fn validate(alloc: Allocator, library: Library) !void {
    if (library.version != current_version) return error.UnsupportedVersion;
    if (library.snapshots.len > max_snapshots) return error.TooManySnapshots;

    var names = std.StringHashMap(void).init(alloc);
    defer names.deinit();

    for (library.snapshots) |snapshot| {
        const name = std.mem.trim(u8, snapshot.name, " \t\r\n");
        if (name.len == 0) return error.EmptyName;
        if (try names.fetchPut(name, {})) |_| return error.DuplicateName;
        if (snapshot.tabs.len == 0) return error.EmptySession;
        if (snapshot.tabs.len > max_tabs) return error.TooManyTabs;
        if (snapshot.selected_tab >= snapshot.tabs.len) return error.InvalidSelectedTab;

        for (snapshot.tabs) |tab| {
            if (tab.group) |group| {
                if (group >= snapshot.groups.len) return error.InvalidGroup;
            }
            try validateTree(alloc, tab.tree);
        }
    }
}

fn validateTree(alloc: Allocator, tree: Tree) !void {
    if (tree.nodes.len == 0) return error.EmptyTree;
    if (tree.nodes.len > max_nodes) return error.TooManyNodes;
    if (tree.focused >= tree.nodes.len) return error.InvalidFocusedNode;
    if (tree.zoomed) |zoomed| {
        if (zoomed >= tree.nodes.len) return error.InvalidZoomedNode;
        switch (tree.nodes[zoomed]) {
            .pane => {},
            .split => return error.ZoomedNodeIsSplit,
        }
    }

    const visited = try alloc.alloc(bool, tree.nodes.len);
    defer alloc.free(visited);
    @memset(visited, false);
    try visitNode(tree, 0, visited);
    for (visited) |value| if (!value) return error.UnreachableNode;
    switch (tree.nodes[tree.focused]) {
        .pane => {},
        .split => return error.FocusedNodeIsSplit,
    }
}

fn visitNode(tree: Tree, index: u32, visited: []bool) !void {
    if (index >= tree.nodes.len) return error.InvalidNodeReference;
    if (visited[index]) return error.NodeCycle;
    visited[index] = true;
    switch (tree.nodes[index]) {
        .pane => {},
        .split => |split| {
            if (!std.math.isFinite(split.ratio) or split.ratio <= 0 or split.ratio >= 1)
                return error.InvalidSplitRatio;
            if (split.left == split.right) return error.DuplicateChild;
            try visitNode(tree, split.left, visited);
            try visitNode(tree, split.right, visited);
        },
    }
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

fn exampleSnapshot(name: []const u8) Snapshot {
    return .{
        .name = name,
        .selected_tab = 0,
        .tabs = &.{.{
            .title = "work",
            .tree = .{
                .focused = 1,
                .nodes = &.{
                    .{ .split = .{
                        .layout = .horizontal,
                        .ratio = 0.4,
                        .left = 1,
                        .right = 2,
                    } },
                    .{ .pane = .{
                        .working_directory = "/tmp/left",
                        .launch_command = .{ .shell = "make test" },
                    } },
                    .{ .pane = .{
                        .working_directory = "/tmp/right",
                        .launch_command = .{ .direct = &.{ "htop", "--tree" } },
                    } },
                },
            },
        }},
    };
}

test "session snapshot JSON round trip" {
    const testing = std.testing;
    const library: Library = .{ .snapshots = &.{exampleSnapshot("work")} };
    try validate(testing.allocator, library);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    try stringify.write(library);

    const parsed = try std.json.parseFromSlice(
        Library,
        testing.allocator,
        output.written(),
        .{},
    );
    defer parsed.deinit();
    try validate(testing.allocator, parsed.value);
    try testing.expectEqualStrings("work", parsed.value.snapshots[0].name);
    try testing.expectEqual(@as(f32, 0.4), parsed.value.snapshots[0].tabs[0].tree.nodes[0].split.ratio);
    try testing.expectEqualStrings(
        "htop",
        parsed.value.snapshots[0].tabs[0].tree.nodes[2].pane.launch_command.?.direct[0],
    );
}

test "session snapshot storage silently overwrites by name" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const path = try std.fs.path.join(testing.allocator, &.{
        dir_buf[0..dir_len],
        "snapshots.json",
    });
    defer testing.allocator.free(path);

    try upsert(testing.io, testing.allocator, path, exampleSnapshot("work"));
    var nodes = [_]Node{
        .{ .split = .{
            .layout = .horizontal,
            .ratio = 0.6,
            .left = 1,
            .right = 2,
        } },
        .{ .pane = .{ .working_directory = "/tmp/left" } },
        .{ .pane = .{ .working_directory = "/tmp/right" } },
    };
    const tabs = [_]Tab{.{ .tree = .{ .focused = 1, .nodes = &nodes } }};
    const replacement: Snapshot = .{
        .name = "work",
        .selected_tab = 0,
        .tabs = &tabs,
    };
    try upsert(testing.io, testing.allocator, path, replacement);

    var loaded = try load(testing.io, testing.allocator, path);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.value.snapshots.len);
    try testing.expectEqual(@as(f32, 0.6), loaded.value.snapshots[0].tabs[0].tree.nodes[0].split.ratio);
}

test "session snapshot rejects invalid trees" {
    const testing = std.testing;
    const nodes = [_]Node{
        .{ .split = .{
            .layout = .horizontal,
            .ratio = 0.5,
            .left = 99,
            .right = 2,
        } },
        .{ .pane = .{} },
        .{ .pane = .{} },
    };
    const tabs = [_]Tab{.{ .tree = .{ .focused = 1, .nodes = &nodes } }};
    const snapshot: Snapshot = .{
        .name = "broken",
        .selected_tab = 0,
        .tabs = &tabs,
    };
    try testing.expectError(
        error.InvalidNodeReference,
        validate(testing.allocator, .{ .snapshots = &.{snapshot} }),
    );
}
