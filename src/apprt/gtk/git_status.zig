const std = @import("std");
const builtin = @import("builtin");

const global = @import("../../global.zig");

/// Parsed porcelain v2 counters. Zero means "nothing to show".
pub const Counts = struct {
    dirty: u64 = 0,
    staged: u64 = 0,
    ahead: u64 = 0,
    behind: u64 = 0,
};

/// Keep `git status` from allocating without bound in pathological repos.
const stdout_limit = 1024 * 1024;
const stderr_limit = 1024 * 1024;

/// One successful spawn may be reused by every tab in the same repo root
/// for this long.
const cache_ttl_ms = 5_000;

const Entry = struct {
    root: [:0]const u8,
    status: [:0]const u8,
    updated_at: std.Io.Timestamp,
};

const Cache = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
};

/// Process-wide status cache. Entries are intentionally kept for the
/// lifetime of the process so a repo root never loses its TTL slot.
var cache: Cache = .{};

/// Parse `git status --porcelain=v2 --branch` output.
///
/// `1`/`2` records use XY at indexes 2 and 3; X stages a change and Y
/// dirties the worktree. Unmerged (`u`) and untracked (`?`) records only
/// dirty the worktree. `# branch.ab +A -B` provides ahead/behind.
pub fn parse(stdout: []const u8) Counts {
    var counts = Counts{};
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (std.mem.startsWith(u8, line, "# branch.ab ")) {
            counts.ahead = parseBranchOffset(line, '+');
            counts.behind = parseBranchOffset(line, '-');
        } else if (line.len >= 4 and line[1] == ' ' and
            (line[0] == '1' or line[0] == '2'))
        {
            const x = line[2];
            const y = line[3];
            if (x != '.') counts.staged += 1;
            if (y != '.') counts.dirty += 1;
        } else if (std.mem.startsWith(u8, line, "u ")) {
            counts.dirty += 1;
        } else if (std.mem.startsWith(u8, line, "? ")) {
            counts.dirty += 1;
        }
    }
    return counts;
}

fn parseBranchOffset(line: []const u8, sign: u8) u64 {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    while (fields.next()) |field| {
        if (field.len < 2 or field[0] != sign) continue;
        return std.fmt.parseInt(u64, field[1..], 10) catch 0;
    }
    return 0;
}

/// Format counters as the vertical-tab token string. Zero counts are
/// omitted, so an empty repo returns `""`. The caller owns the returned
/// allocation.
pub fn format(
    allocator: std.mem.Allocator,
    counts: Counts,
) ![:0]const u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    var first = true;

    if (counts.dirty > 0) {
        if (!first) try list.append(allocator, ' ');
        try list.print(allocator, "*{d}", .{counts.dirty});
        first = false;
    }
    if (counts.staged > 0) {
        if (!first) try list.append(allocator, ' ');
        try list.print(allocator, "+{d}", .{counts.staged});
        first = false;
    }
    if (counts.ahead > 0) {
        if (!first) try list.append(allocator, ' ');
        try list.print(allocator, "↑{d}", .{counts.ahead});
        first = false;
    }
    if (counts.behind > 0) {
        if (!first) try list.append(allocator, ' ');
        try list.print(allocator, "↓{d}", .{counts.behind});
        first = false;
    }

    return try list.toOwnedSliceSentinel(allocator, 0);
}

/// Walk `pwd` and its ancestors looking for a `.git` entry, matching
/// `VerticalTab.pathInGitRepo`. The returned slice points into `pwd`.
pub fn repoRoot(pwd: []const u8) ?[]const u8 {
    var dir = std.mem.trimEnd(u8, pwd, "/");
    while (dir.len > 0) {
        var git_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const git_path = std.fmt.bufPrint(
            &git_path_buf,
            "{s}/.git",
            .{dir},
        ) catch return null;
        if (std.Io.Dir.accessAbsolute(global.io(), git_path, .{})) {
            return dir;
        } else |_| {}

        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
    return null;
}

/// Return the cached/refreshed formatted status for `pwd`, or null when
/// there is no status to show. The returned string is owned by the
/// process-wide cache and is valid until the next refresh for this root.
pub fn statusForPwd(pwd: []const u8) ?[:0]const u8 {
    // Tests cover parse/format only; never spawn a child from test code.
    if (comptime builtin.is_test) return null;

    const root = repoRoot(pwd) orelse return null;
    const allocator = global.alloc();
    const now: std.Io.Timestamp = .now(global.io(), .awake);

    for (cache.entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.root, root)) continue;

        if (entry.updated_at.durationTo(now).toMilliseconds() < cache_ttl_ms)
            return entry.status;

        const status = runGit(allocator, pwd) orelse
            allocator.dupeZ(u8, "") catch return null;
        allocator.free(entry.status);
        entry.status = status;
        entry.updated_at = .now(global.io(), .awake);
        return status;
    }

    const status = runGit(allocator, pwd) orelse
        allocator.dupeZ(u8, "") catch return null;
    const root_z = allocator.dupeZ(u8, root) catch {
        allocator.free(status);
        return null;
    };
    cache.entries.append(allocator, .{
        .root = root_z,
        .status = status,
        .updated_at = .now(global.io(), .awake),
    }) catch {
        allocator.free(status);
        allocator.free(root_z);
        return null;
    };
    return status;
}

fn runGit(allocator: std.mem.Allocator, pwd: []const u8) ?[:0]const u8 {
    const argv = [_][]const u8{
        "git",
        "--no-optional-locks",
        "-c",
        "gc.auto=0",
        "-C",
        pwd,
        "status",
        "--porcelain=v2",
        "--branch",
    };
    const result = std.process.run(
        allocator,
        global.io(),
        .{
            .argv = &argv,
            .stdout_limit = .limited(stdout_limit),
            .stderr_limit = .limited(stderr_limit),
        },
    ) catch |err| {
        std.log.warn("git status spawn failed: {}", .{err});
        return format(allocator, .{}) catch null;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.warn("git status exited with non-zero status: {d}", .{code});
            return format(allocator, .{}) catch null;
        },
        else => {
            std.log.warn("git status terminated abnormally: {}", .{result.term});
            return format(allocator, .{}) catch null;
        },
    }

    return format(allocator, parse(result.stdout)) catch |err| {
        std.log.warn("failed to format git status: {}", .{err});
        return format(allocator, .{}) catch null;
    };
}

test "git status parses porcelain v2 and formats tokens" {
    const sample =
        \\# branch.head main
        \\# branch.upstream origin/main
        \\# branch.ab +18 -7
        \\1 .M N...
        \\1 M. N...
        \\? scratch.txt
        \\
    ;
    const counts = parse(sample);
    try std.testing.expectEqual(@as(u64, 2), counts.dirty);
    try std.testing.expectEqual(@as(u64, 1), counts.staged);
    try std.testing.expectEqual(@as(u64, 18), counts.ahead);
    try std.testing.expectEqual(@as(u64, 7), counts.behind);

    const formatted = try format(std.testing.allocator, counts);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("*2 +1 ↑18 ↓7", formatted);

    const empty = try format(std.testing.allocator, .{});
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}
