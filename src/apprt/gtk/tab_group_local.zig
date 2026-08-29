const std = @import("std");

const planpkg = @import("tab_group_plan.zig");

const Allocator = std.mem.Allocator;

/// Metadata which is already available to the GTK tab chrome. Repository
/// roots only limit comparisons; they never group tabs by themselves.
pub const TabSnapshot = struct {
    id: u64,
    title: []const u8,
    pwd: ?[]const u8 = null,
    repo_root: ?[]const u8 = null,
    process: ?[]const u8 = null,
    remote_host: ?[]const u8 = null,
};

pub const Options = struct {
    max_groups: usize,
};

const minimum_score = 55;

const Cluster = struct {
    members: std.ArrayListUnmanaged(usize) = .empty,

    fn deinit(self: *Cluster, alloc: Allocator) void {
        self.members.deinit(alloc);
    }
};

/// Build groups without a model or external process. A tab may join a cluster
/// only when it is related to every existing member, which prevents a chain of
/// weak matches from turning a repository into one large group.
pub fn buildPlan(
    alloc: Allocator,
    tabs: []const TabSnapshot,
    options: Options,
) !planpkg.Plan {
    var clusters: std.ArrayList(Cluster) = .empty;
    defer {
        for (clusters.items) |*cluster| cluster.deinit(alloc);
        clusters.deinit(alloc);
    }

    for (tabs, 0..) |_, tab_index| {
        var best_index: ?usize = null;
        var best_score: u8 = 0;
        for (clusters.items, 0..) |cluster, cluster_index| {
            var score: u8 = 100;
            for (cluster.members.items) |member_index| {
                score = @min(score, pairScore(tabs[tab_index], tabs[member_index]));
            }
            if (score < minimum_score or score <= best_score) continue;
            best_index = cluster_index;
            best_score = score;
        }

        if (best_index) |index| {
            try clusters.items[index].members.append(alloc, tab_index);
        } else {
            var cluster: Cluster = .{};
            errdefer cluster.deinit(alloc);
            try cluster.members.append(alloc, tab_index);
            try clusters.append(alloc, cluster);
        }
    }

    const selected = try alloc.alloc(bool, clusters.items.len);
    defer alloc.free(selected);
    @memset(selected, false);

    var selected_count: usize = 0;
    while (selected_count < options.max_groups) : (selected_count += 1) {
        var best: ?usize = null;
        for (clusters.items, 0..) |cluster, index| {
            if (selected[index] or cluster.members.items.len < 2) continue;
            if (best) |current| {
                const current_cluster = clusters.items[current];
                const strength = clusterStrength(tabs, cluster.members.items);
                const current_strength = clusterStrength(tabs, current_cluster.members.items);
                if (strength < current_strength) continue;
                if (strength == current_strength and
                    cluster.members.items.len < current_cluster.members.items.len) continue;
                if (strength == current_strength and
                    cluster.members.items.len == current_cluster.members.items.len and
                    cluster.members.items[0] > current_cluster.members.items[0]) continue;
            }
            best = index;
        }
        const index = best orelse break;
        selected[index] = true;
    }

    var groups: std.ArrayList(planpkg.Group) = .empty;
    errdefer {
        for (groups.items) |*group| group.deinit(alloc);
        groups.deinit(alloc);
    }

    for (clusters.items, selected) |cluster, include| {
        if (!include) continue;
        var name = try groupName(alloc, tabs, cluster.members.items);
        errdefer alloc.free(name);
        name = try makeNameUnique(alloc, name, groups.items);

        const ids = try alloc.alloc(u64, cluster.members.items.len);
        errdefer alloc.free(ids);
        for (cluster.members.items, ids) |tab_index, *id| id.* = tabs[tab_index].id;

        try groups.append(alloc, .{ .name = name, .tabs = ids });
    }

    return .{ .groups = try groups.toOwnedSlice(alloc) };
}

fn pairScore(a: TabSnapshot, b: TabSnapshot) u8 {
    var score: u8 = 0;

    if (a.remote_host != null or b.remote_host != null) {
        if (!optionalEql(a.remote_host, b.remote_host)) return 0;
        score += 35;
    }

    const same_repo = optionalEql(a.repo_root, b.repo_root) and a.repo_root != null;
    if (same_repo) score += 5;

    if (optionalEql(a.pwd, b.pwd) and a.pwd != null) {
        score += 30;
    } else if (same_repo) {
        const root = a.repo_root.?;
        const common = commonRelativeComponents(a.pwd, b.pwd, root);
        score += if (common >= 2) 25 else if (common == 1) 10 else 0;
    }

    if (optionalEql(a.process, b.process) and a.process != null) score += 25;
    score += titleScore(a, b);
    return @min(score, 100);
}

fn clusterStrength(tabs: []const TabSnapshot, members: []const usize) u8 {
    var result: u8 = 100;
    for (members, 0..) |a, i| {
        for (members[i + 1 ..]) |b| result = @min(result, pairScore(tabs[a], tabs[b]));
    }
    return result;
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn commonRelativeComponents(
    a_pwd: ?[]const u8,
    b_pwd: ?[]const u8,
    root: []const u8,
) usize {
    const a = relativePath(a_pwd orelse return 0, root) orelse return 0;
    const b = relativePath(b_pwd orelse return 0, root) orelse return 0;
    var a_parts = std.mem.tokenizeScalar(u8, a, '/');
    var b_parts = std.mem.tokenizeScalar(u8, b, '/');
    var count: usize = 0;
    while (true) {
        const a_part = a_parts.next() orelse break;
        const b_part = b_parts.next() orelse break;
        if (!std.mem.eql(u8, a_part, b_part)) break;
        count += 1;
    }
    return count;
}

fn relativePath(path: []const u8, root: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, root)) return null;
    if (path.len == root.len) return "";
    if (path[root.len] != '/') return null;
    return path[root.len + 1 ..];
}

fn titleScore(a: TabSnapshot, b: TabSnapshot) u8 {
    var a_count: usize = 0;
    var b_count: usize = 0;
    var intersection: usize = 0;

    var a_tokens: TokenIterator = .{ .text = a.title };
    while (a_tokens.next()) |token| {
        if (!relevantToken(a, token)) continue;
        a_count += 1;
        if (titleHasToken(b, token)) intersection += 1;
    }
    var b_tokens: TokenIterator = .{ .text = b.title };
    while (b_tokens.next()) |token| {
        if (relevantToken(b, token)) b_count += 1;
    }

    if (intersection == 0 or a_count == 0 or b_count == 0) return 0;
    const similarity: usize = @min(20, (40 * intersection) / (a_count + b_count));
    return @intCast(@as(usize, 20) + similarity);
}

fn groupName(
    alloc: Allocator,
    tabs: []const TabSnapshot,
    members: []const usize,
) ![]u8 {
    const first = tabs[members[0]];
    if (commonSpecificDirectory(tabs, members)) |directory|
        return alloc.dupe(u8, std.fs.path.basename(directory));

    if (commonTitleToken(tabs, members)) |token|
        return capitalize(alloc, token);

    if (commonField(tabs, members, "process")) |process|
        return alloc.dupe(u8, process);

    if (commonField(tabs, members, "remote_host")) |host|
        return alloc.dupe(u8, host);

    if (commonField(tabs, members, "repo_root")) |root|
        return alloc.dupe(u8, std.fs.path.basename(root));

    if (first.pwd) |pwd| return alloc.dupe(u8, std.fs.path.basename(pwd));
    return alloc.dupe(u8, "Tabs");
}

fn commonSpecificDirectory(
    tabs: []const TabSnapshot,
    members: []const usize,
) ?[]const u8 {
    var common = std.mem.trimEnd(u8, tabs[members[0]].pwd orelse return null, "/");
    for (members[1..]) |index| {
        const pwd = std.mem.trimEnd(u8, tabs[index].pwd orelse return null, "/");
        while (!pathContains(common, pwd)) {
            common = std.fs.path.dirname(common) orelse return null;
        }
    }
    if (common.len == 0 or std.mem.eql(u8, common, "/")) return null;

    if (commonField(tabs, members, "repo_root")) |root| {
        if (std.mem.eql(u8, common, std.mem.trimEnd(u8, root, "/"))) return null;
        if (!pathContains(root, common)) return null;
    }
    return common;
}

fn pathContains(parent: []const u8, child: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child.len == parent.len or
        (parent.len > 0 and parent[parent.len - 1] == '/') or
        child[parent.len] == '/';
}

fn commonField(
    tabs: []const TabSnapshot,
    members: []const usize,
    comptime field: []const u8,
) ?[]const u8 {
    const value = @field(tabs[members[0]], field) orelse return null;
    for (members[1..]) |index| {
        const other = @field(tabs[index], field) orelse return null;
        if (!std.mem.eql(u8, value, other)) return null;
    }
    return value;
}

fn commonTitleToken(tabs: []const TabSnapshot, members: []const usize) ?[]const u8 {
    const first = tabs[members[0]];
    var best: ?[]const u8 = null;
    var tokens: TokenIterator = .{ .text = first.title };
    while (tokens.next()) |token| {
        if (!relevantToken(first, token)) continue;
        var shared = true;
        for (members[1..]) |index| {
            if (!titleHasToken(tabs[index], token)) {
                shared = false;
                break;
            }
        }
        if (shared and (best == null or token.len > best.?.len)) best = token;
    }
    return best;
}

fn titleHasToken(tab: TabSnapshot, needle: []const u8) bool {
    var tokens: TokenIterator = .{ .text = tab.title };
    while (tokens.next()) |token| {
        if (relevantToken(tab, token) and std.ascii.eqlIgnoreCase(token, needle)) return true;
    }
    return false;
}

fn relevantToken(tab: TabSnapshot, token: []const u8) bool {
    if (token.len < 2 or isStopword(token)) return false;
    inline for (.{ tab.pwd, tab.repo_root, tab.remote_host }) |context| {
        if (context) |value| {
            if (std.ascii.eqlIgnoreCase(token, std.fs.path.basename(value))) return false;
        }
    }
    return true;
}

fn isStopword(token: []const u8) bool {
    const words = [_][]const u8{
        "bash", "fish",     "ghostty", "holoctty", "localhost", "shell",
        "tab",  "terminal", "the",     "user",     "zsh",
    };
    for (words) |word| {
        if (std.ascii.eqlIgnoreCase(token, word)) return true;
    }
    return false;
}

const TokenIterator = struct {
    text: []const u8,
    index: usize = 0,

    fn next(self: *TokenIterator) ?[]const u8 {
        while (self.index < self.text.len and !std.ascii.isAlphanumeric(self.text[self.index]))
            self.index += 1;
        if (self.index == self.text.len) return null;
        const start = self.index;
        while (self.index < self.text.len and std.ascii.isAlphanumeric(self.text[self.index]))
            self.index += 1;
        return self.text[start..self.index];
    }
};

fn capitalize(alloc: Allocator, value: []const u8) ![]u8 {
    const result = try alloc.dupe(u8, value);
    if (result.len > 0) result[0] = std.ascii.toUpper(result[0]);
    return result;
}

fn makeNameUnique(
    alloc: Allocator,
    name: []u8,
    groups: []const planpkg.Group,
) ![]u8 {
    if (!nameExists(name, groups)) return name;

    var suffix: usize = 2;
    while (true) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(alloc, "{s} {d}", .{ name, suffix });
        if (!nameExists(candidate, groups)) {
            alloc.free(name);
            return candidate;
        }
        alloc.free(candidate);
    }
}

fn nameExists(name: []const u8, groups: []const planpkg.Group) bool {
    for (groups) |group| {
        if (std.ascii.eqlIgnoreCase(name, group.name)) return true;
    }
    return false;
}

test "local grouping splits tasks inside one repository" {
    const alloc = std.testing.allocator;
    const tabs = [_]TabSnapshot{
        .{ .id = 1, .title = "zig build", .pwd = "/work/holoctty", .repo_root = "/work/holoctty" },
        .{ .id = 2, .title = "zig test", .pwd = "/work/holoctty", .repo_root = "/work/holoctty" },
        .{ .id = 3, .title = "routes", .pwd = "/work/holoctty/src/apprt/gtk", .repo_root = "/work/holoctty", .process = "Neovim" },
        .{ .id = 4, .title = "widgets", .pwd = "/work/holoctty/src/apprt/gtk/class", .repo_root = "/work/holoctty", .process = "Neovim" },
        .{ .id = 5, .title = "plain shell", .pwd = "/work/holoctty", .repo_root = "/work/holoctty" },
    };

    var plan = try buildPlan(alloc, &tabs, .{ .max_groups = 4 });
    defer plan.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), plan.groups.len);
    try std.testing.expectEqualStrings("Zig", plan.groups[0].name);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, plan.groups[0].tabs);
    try std.testing.expectEqualStrings("gtk", plan.groups[1].name);
    try std.testing.expectEqualSlices(u64, &.{ 3, 4 }, plan.groups[1].tabs);
}

test "local grouping does not merge a repository without task evidence" {
    const alloc = std.testing.allocator;
    const tabs = [_]TabSnapshot{
        .{ .id = 1, .title = "shell", .pwd = "/work/repo", .repo_root = "/work/repo" },
        .{ .id = 2, .title = "terminal", .pwd = "/work/repo", .repo_root = "/work/repo" },
        .{ .id = 3, .title = "bash", .pwd = "/work/repo", .repo_root = "/work/repo" },
    };

    var plan = try buildPlan(alloc, &tabs, .{ .max_groups = 4 });
    defer plan.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), plan.groups.len);
}

test "local grouping requires every member to match" {
    const alloc = std.testing.allocator;
    const tabs = [_]TabSnapshot{
        .{ .id = 1, .title = "api build", .pwd = "/work/repo", .repo_root = "/work/repo" },
        .{ .id = 2, .title = "api test", .pwd = "/work/repo", .repo_root = "/work/repo" },
        .{ .id = 3, .title = "web test", .pwd = "/work/repo", .repo_root = "/work/repo" },
    };

    var plan = try buildPlan(alloc, &tabs, .{ .max_groups = 4 });
    defer plan.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), plan.groups.len);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, plan.groups[0].tabs);
}

test "local grouping keeps remote hosts separate" {
    const alloc = std.testing.allocator;
    const tabs = [_]TabSnapshot{
        .{ .id = 1, .title = "logs api", .remote_host = "api-1" },
        .{ .id = 2, .title = "logs worker", .remote_host = "api-1" },
        .{ .id = 3, .title = "deploy api", .remote_host = "api-2" },
        .{ .id = 4, .title = "deploy worker", .remote_host = "api-2" },
    };

    var plan = try buildPlan(alloc, &tabs, .{ .max_groups = 4 });
    defer plan.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), plan.groups.len);
    try std.testing.expectEqualStrings("Logs", plan.groups[0].name);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, plan.groups[0].tabs);
    try std.testing.expectEqualStrings("Deploy", plan.groups[1].name);
    try std.testing.expectEqualSlices(u64, &.{ 3, 4 }, plan.groups[1].tabs);
}

test "local grouping never mixes local and remote tabs" {
    const alloc = std.testing.allocator;
    const tabs = [_]TabSnapshot{
        .{ .id = 1, .title = "api logs", .process = "tail" },
        .{ .id = 2, .title = "api logs", .process = "tail", .remote_host = "api-1" },
    };

    var plan = try buildPlan(alloc, &tabs, .{ .max_groups = 4 });
    defer plan.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), plan.groups.len);
}

test "local grouping respects the group limit" {
    const alloc = std.testing.allocator;
    const tabs = [_]TabSnapshot{
        .{ .id = 1, .title = "zig build", .pwd = "/work/api", .repo_root = "/work/api" },
        .{ .id = 2, .title = "zig test", .pwd = "/work/api", .repo_root = "/work/api" },
        .{ .id = 3, .title = "npm serve", .pwd = "/work/web", .repo_root = "/work/web" },
        .{ .id = 4, .title = "npm test", .pwd = "/work/web", .repo_root = "/work/web" },
    };

    var plan = try buildPlan(alloc, &tabs, .{ .max_groups = 1 });
    defer plan.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), plan.groups.len);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, plan.groups[0].tabs);
}
