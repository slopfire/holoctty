const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");

const Common = @import("../class.zig").Common;

const page_key = "holoctty-tab-group";

var next_id: i32 = 1;
var next_color_index: u8 = 1;

/// Chrome-style tab group attached to `Adw.TabPage`s via qdata.
pub const TabGroup = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gobject.Object;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "HolocttyTabGroup",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const @"group-name" = struct {
            pub const name = "name";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("name"),
                },
            );
        };

        pub const color = struct {
            pub const name = "color";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                Color,
                .{
                    .default = .blue,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "color",
                    ),
                },
            );
        };

        pub const collapsed = struct {
            pub const name = "collapsed";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = C.privateShallowFieldAccessor("collapsed"),
                },
            );
        };
    };

    const Private = struct {
        id: i32 = 0,
        name: ?[:0]const u8 = null,
        color: Color = .blue,
        collapsed: bool = false,

        pub var offset: c_int = 0;
    };

    pub const Range = struct {
        start: c_int,
        end: c_int,
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        priv.id = next_id;
        next_id +%= 1;
        if (next_id == 0) next_id = 1;
        priv.color = nextColor();
    }

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn getId(self: *Self) i32 {
        return self.private().id;
    }

    pub fn getName(self: *Self) ?[:0]const u8 {
        return self.private().name;
    }

    pub fn setName(self: *Self, name: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.name) |current| {
            if (name) |value| {
                if (std.mem.eql(u8, current, value)) return;
            }
            glib.free(@ptrCast(@constCast(current)));
            priv.name = null;
        } else if (name == null) return;
        if (name) |value| {
            if (value.len > 0) priv.name = glib.ext.dupeZ(u8, value);
        }
        self.as(gobject.Object).notifyByPspec(properties.@"group-name".impl.param_spec);
    }

    pub fn getColor(self: *Self) Color {
        return self.private().color;
    }

    pub fn setColor(self: *Self, color: Color) void {
        if (self.private().color == color) return;
        self.private().color = color;
        self.as(gobject.Object).notifyByPspec(properties.color.impl.param_spec);
    }

    pub fn getCollapsed(self: *Self) bool {
        return self.private().collapsed;
    }

    pub fn setCollapsed(self: *Self, collapsed: bool) void {
        if (self.private().collapsed == collapsed) return;
        self.private().collapsed = collapsed;
        self.as(gobject.Object).notifyByPspec(properties.collapsed.impl.param_spec);
    }

    pub fn toggleCollapsed(self: *Self) void {
        self.setCollapsed(!self.getCollapsed());
    }

    /// Display label for a header chip. Unnamed groups use the color name.
    pub fn displayLabel(self: *Self, buf: []u8) [:0]const u8 {
        const color_name = self.getColor().label();
        const name = if (self.getName()) |value|
            if (value.len > 0) value else color_name
        else
            color_name;
        return std.fmt.bufPrintZ(buf, "{s}", .{name}) catch name;
    }

    pub fn forPage(page: *adw.TabPage) ?*Self {
        const ptr = page.as(gobject.Object).getData(page_key) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn bindPage(page: *adw.TabPage, group: ?*Self) void {
        if (forPage(page) == group) return;
        const obj = page.as(gobject.Object);
        if (group) |value| {
            obj.setDataFull(page_key, value.ref(), destroyGroup);
        } else {
            obj.setData(page_key, null);
        }
    }

    fn destroyGroup(data: ?*anyopaque) callconv(.c) void {
        const group: *Self = @ptrCast(@alignCast(data orelse return));
        group.unref();
    }

    pub fn findInView(view: *adw.TabView, id: i32) ?*Self {
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            if (forPage(view.getNthPage(i))) |group| {
                if (group.getId() == id) return group;
            }
        }
        return null;
    }

    /// First contiguous run of this group in `view`.
    pub fn rangeInView(self: *Self, view: *adw.TabView) ?Range {
        var ids: [128]?i32 = undefined;
        const n = collectViewIds(view, &ids);
        return firstRun(ids[0..n], self.getId());
    }

    pub fn memberCount(self: *Self, view: *adw.TabView) c_int {
        var count: c_int = 0;
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            if (forPage(view.getNthPage(i)) == self) count += 1;
        }
        return count;
    }

    pub fn collectInView(
        view: *adw.TabView,
        buf: []*Self,
    ) []*Self {
        var len: usize = 0;
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            const group = forPage(view.getNthPage(i)) orelse continue;
            var seen = false;
            for (buf[0..len]) |existing| {
                if (existing == group) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            if (len == buf.len) break;
            buf[len] = group;
            len += 1;
        }
        return buf[0..len];
    }

    pub fn collectMembers(
        self: *Self,
        view: *adw.TabView,
        buf: []*adw.TabPage,
    ) []*adw.TabPage {
        var len: usize = 0;
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            const page = view.getNthPage(i);
            if (forPage(page) != self) continue;
            if (len == buf.len) break;
            buf[len] = page;
            len += 1;
        }
        return buf[0..len];
    }

    /// Move every member so the block starts at `dest`.
    pub fn moveInView(self: *Self, view: *adw.TabView, dest: c_int) void {
        var pages: [64]*adw.TabPage = undefined;
        const members = self.collectMembers(view, &pages);
        if (members.len == 0) return;

        const n = view.getNPages();
        var dest_adj: c_int = dest;
        if (dest_adj < 0) dest_adj = 0;
        if (dest_adj > n) dest_adj = n;

        var parked: [64]c_int = undefined;
        const count: usize = members.len;
        for (members, 0..) |page, i| {
            parked[i] = view.getPagePosition(page);
        }
        const insert = destAfterRemove(dest_adj, parked[0..count]);

        for (members) |page| {
            _ = view.reorderPage(page, view.getNPages() - 1);
        }
        for (members, 0..) |page, i| {
            _ = view.reorderPage(page, insert + @as(c_int, @intCast(i)));
        }
    }

    /// Exchange this group with the top-level tab or group containing `target`.
    pub fn swapWithPageInView(
        self: *Self,
        view: *adw.TabView,
        target: *adw.TabPage,
    ) bool {
        const Unit = union(enum) {
            group: *Self,
            page: *adw.TabPage,
        };

        var units: [128]Unit = undefined;
        var unit_len: usize = 0;
        var dragged_index: ?usize = null;
        var target_index: ?usize = null;
        var seen_groups: [64]*Self = undefined;
        var seen_len: usize = 0;

        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            const page = view.getNthPage(i);
            if (forPage(page)) |group| {
                var seen = false;
                for (seen_groups[0..seen_len]) |existing| {
                    if (existing == group) {
                        seen = true;
                        break;
                    }
                }
                if (seen) {
                    if (page == target) {
                        for (units[0..unit_len], 0..) |unit, index| {
                            if (unit == .group and unit.group == group) {
                                target_index = index;
                                break;
                            }
                        }
                    }
                    continue;
                }
                if (seen_len == seen_groups.len or unit_len == units.len)
                    return false;
                seen_groups[seen_len] = group;
                seen_len += 1;
                units[unit_len] = .{ .group = group };
                if (group == self) dragged_index = unit_len;
                if (page == target) target_index = unit_len;
                unit_len += 1;
            } else {
                if (unit_len == units.len) return false;
                units[unit_len] = .{ .page = page };
                if (page == target) target_index = unit_len;
                unit_len += 1;
            }
        }

        const from = dragged_index orelse return false;
        const to = target_index orelse return false;
        if (from == to) return true;
        const tmp = units[from];
        units[from] = units[to];
        units[to] = tmp;

        var desired: [128]*adw.TabPage = undefined;
        var desired_len: usize = 0;
        var members_buf: [64]*adw.TabPage = undefined;
        for (units[0..unit_len]) |unit| switch (unit) {
            .page => |page| {
                if (desired_len == desired.len) return false;
                desired[desired_len] = page;
                desired_len += 1;
            },
            .group => |group| {
                const members = group.collectMembers(view, &members_buf);
                if (desired_len + members.len > desired.len) return false;
                for (members) |page| {
                    desired[desired_len] = page;
                    desired_len += 1;
                }
            },
        };

        for (desired[0..desired_len], 0..) |page, index| {
            if (view.getNthPage(@intCast(index)) != page) {
                _ = view.reorderPage(page, @intCast(index));
            }
        }
        return true;
    }

    /// Bind `page` and move it to the end of this group's first run.
    pub fn addPage(self: *Self, page: *adw.TabPage, view: *adw.TabView) void {
        bindPage(page, self);
        const range = self.rangeInView(view) orelse return;
        const pos = view.getPagePosition(page);
        if (pos >= range.start and pos <= range.end) return;
        const dest = if (pos < range.start) range.start else range.end;
        _ = view.reorderPage(page, dest);
    }

    pub fn removePage(page: *adw.TabPage) void {
        bindPage(page, null);
    }

    /// Join `page` when inserting it would split an existing group.
    pub fn adoptFromNeighbors(view: *adw.TabView, page: *adw.TabPage) void {
        const pos = view.getPagePosition(page);
        const n = view.getNPages();
        const prev = if (pos > 0) forPage(view.getNthPage(pos - 1)) else null;
        const next = if (pos + 1 < n) forPage(view.getNthPage(pos + 1)) else null;
        if (wouldJoin(
            if (prev) |g| g.getId() else null,
            if (next) |g| g.getId() else null,
        )) |_| {
            if (prev) |group| bindPage(page, group);
        }
    }

    /// After a drop: join the target's group, or leave the group.
    pub fn applyDrop(dragged: *adw.TabPage, target: *adw.TabPage, view: *adw.TabView) void {
        if (forPage(target)) |group| {
            group.addPage(dragged, view);
        } else {
            bindPage(dragged, null);
        }
    }

    /// Keep each group's members contiguous around the first run.
    pub fn coalesceInView(view: *adw.TabView) void {
        var groups: [32]*Self = undefined;
        const list = collectInView(view, &groups);
        for (list) |group| {
            group.coalesce(view);
        }
    }

    fn coalesce(self: *Self, view: *adw.TabView) void {
        var guard: u8 = 0;
        while (guard < 64) : (guard += 1) {
            const range = self.rangeInView(view) orelse return;
            var i: c_int = 0;
            const stray = while (i < view.getNPages()) : (i += 1) {
                if (forPage(view.getNthPage(i)) != self) continue;
                if (i < range.start or i > range.end) break i;
            } else return;
            _ = view.reorderPage(view.getNthPage(stray), range.end + 1);
        }
    }

    pub fn ungroupInView(self: *Self, view: *adw.TabView) void {
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            const page = view.getNthPage(i);
            if (forPage(page) == self) bindPage(page, null);
        }
    }

    pub fn closeInView(self: *Self, view: *adw.TabView) void {
        var pages: [64]*adw.TabPage = undefined;
        var len: usize = 0;
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            const page = view.getNthPage(i);
            if (forPage(page) != self) continue;
            if (len == pages.len) break;
            pages[len] = page;
            len += 1;
        }
        for (pages[0..len]) |page| view.closePage(page);
    }

    /// If `page` is leaving `from` and other members stay behind, ungroup it.
    pub fn splitOnTransfer(
        page: *adw.TabPage,
        from: *adw.TabView,
    ) void {
        const group = forPage(page) orelse return;
        if (group.memberCount(from) > 0) bindPage(page, null);
    }

    fn collectViewIds(view: *adw.TabView, ids: []?i32) usize {
        const n: usize = @intCast(@min(view.getNPages(), @as(c_int, @intCast(ids.len))));
        var i: usize = 0;
        while (i < n) : (i += 1) {
            ids[i] = if (forPage(view.getNthPage(@intCast(i)))) |group|
                group.getId()
            else
                null;
        }
        return n;
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.name) |name| {
            glib.free(@ptrCast(@constCast(name)));
            priv.name = null;
        }
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.registerProperties(class, &.{
                properties.@"group-name".impl,
                properties.color.impl,
                properties.collapsed.impl,
            });
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};

/// Chrome's eight tab-group colors.
pub const Color = enum(c_int) {
    grey,
    blue,
    red,
    yellow,
    green,
    pink,
    purple,
    cyan,

    pub const getGObjectType = gobject.ext.defineEnum(
        Color,
        .{ .name = "HolocttyTabGroupColor" },
    );

    pub fn cssClass(self: Color) [:0]const u8 {
        return switch (self) {
            .grey => "tab-group-grey",
            .blue => "tab-group-blue",
            .red => "tab-group-red",
            .yellow => "tab-group-yellow",
            .green => "tab-group-green",
            .pink => "tab-group-pink",
            .purple => "tab-group-purple",
            .cyan => "tab-group-cyan",
        };
    }

    pub fn hex(self: Color) [:0]const u8 {
        return switch (self) {
            .grey => "#5F6368",
            .blue => "#1A73E8",
            .red => "#D93025",
            .yellow => "#F9AB00",
            .green => "#1E8E3E",
            .pink => "#D01884",
            .purple => "#9334E6",
            .cyan => "#007B83",
        };
    }

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

    pub fn fromIndex(index: i32) ?Color {
        const values = std.enums.values(Color);
        if (index < 0 or index >= values.len) return null;
        return values[@intCast(index)];
    }
};

pub fn nextColor() Color {
    const values = std.enums.values(Color);
    const color = values[next_color_index % values.len];
    next_color_index +%= 1;
    return color;
}

/// Inserting between two members of the same group should join that group.
pub fn wouldJoin(prev: ?i32, next: ?i32) ?i32 {
    const left = prev orelse return null;
    const right = next orelse return null;
    return if (left == right) left else null;
}

/// Destination index after the moving members are taken out of the list.
pub fn destAfterRemove(dest: c_int, positions: []const c_int) c_int {
    var insert = dest;
    for (positions) |pos| {
        if (pos < dest) insert -= 1;
    }
    return if (insert < 0) 0 else insert;
}

/// First contiguous run of `group` in `ids`.
pub fn firstRun(ids: []const ?i32, group: i32) ?TabGroup.Range {
    var start: ?c_int = null;
    var end: c_int = 0;
    for (ids, 0..) |id, i| {
        if (id == group) {
            if (start == null) start = @intCast(i);
            end = @intCast(i);
        } else if (start != null) break;
    }
    return if (start) |s| .{ .start = s, .end = end } else null;
}

test "tab group join and first run" {
    try std.testing.expectEqual(@as(?i32, 3), wouldJoin(3, 3));
    try std.testing.expectEqual(@as(?i32, null), wouldJoin(3, 4));
    try std.testing.expectEqual(@as(?i32, null), wouldJoin(3, null));
    try std.testing.expectEqual(@as(?i32, null), wouldJoin(null, 3));

    const ids = [_]?i32{ null, 1, 1, 2, 2, 1, null };
    const run = firstRun(&ids, 1).?;
    try std.testing.expectEqual(@as(c_int, 1), run.start);
    try std.testing.expectEqual(@as(c_int, 2), run.end);
    try std.testing.expect(firstRun(&ids, 9) == null);

    const only = [_]?i32{ 7, 7, 7 };
    const all = firstRun(&only, 7).?;
    try std.testing.expectEqual(@as(c_int, 0), all.start);
    try std.testing.expectEqual(@as(c_int, 2), all.end);

    try std.testing.expectEqual(@as(c_int, 0), destAfterRemove(0, &[_]c_int{ 1, 2 }));
    try std.testing.expectEqual(@as(c_int, 2), destAfterRemove(4, &[_]c_int{ 1, 2 }));
    try std.testing.expectEqual(@as(c_int, 1), destAfterRemove(3, &[_]c_int{ 1, 2 }));
}

test "tab group color css and cycle" {
    try std.testing.expectEqualStrings("tab-group-blue", Color.blue.cssClass());
    try std.testing.expectEqualStrings("#D93025", Color.red.hex());
    try std.testing.expectEqualStrings("Purple", Color.purple.label());
    try std.testing.expectEqual(Color.grey, Color.fromIndex(0).?);
    try std.testing.expectEqual(Color.cyan, Color.fromIndex(7).?);
    try std.testing.expect(Color.fromIndex(8) == null);
    try std.testing.expect(Color.fromIndex(-1) == null);

    const first = nextColor();
    const second = nextColor();
    try std.testing.expect(first != second);
}
