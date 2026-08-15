const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const TabGroup = @import("tab_group.zig").TabGroup;
const Color = @import("tab_group.zig").Color;
const TabGroupHeader = @import("tab_group_header.zig").TabGroupHeader;
const VerticalTab = @import("vertical_tab.zig").VerticalTab;
const Window = @import("window.zig").Window;

/// A scrollable vertical representation of an AdwTabView.
pub const VerticalTabBar = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "HolocttyVerticalTabBar",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const view = struct {
            pub const name = "view";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*adw.TabView,
                .{
                    .accessor = C.privateObjFieldAccessor("view"),
                },
            );
        };
    };

    const Private = struct {
        view: ?*adw.TabView = null,
        connected_view: ?*adw.TabView = null,
        scrolled_window: *gtk.ScrolledWindow,
        tab_bar_drop_target: *gtk.DropTarget,
        tab_list: *gtk.Box,
        drag_x: f64 = 0,
        drag_y: f64 = 0,
        drag_inside: bool = false,
        tick_id: c_uint = 0,
        attached_handler: c_ulong = 0,
        detached_handler: c_ulong = 0,
        reordered_handler: c_ulong = 0,
        selected_handler: c_ulong = 0,
        syncing: bool = false,
        sync_idle: c_uint = 0,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        var drop_types = [_]gobject.Type{gobject.ext.types.uint64};
        self.private().tab_bar_drop_target.setGtypes(&drop_types, drop_types.len);
    }

    pub fn sync(self: *Self) void {
        if (self.private().syncing) return;
        // Never unparent rows while a tab is being dragged. GTK4 finalize
        // the widget on remove, which emptied the sidebar after a drop.
        if (VerticalTab.activeDragPage() != null) return;
        if (TabGroupHeader.activeDragGroup() != null) return;
        self.queueSync();
    }

    /// Rebuild immediately so grouping from a menu is visible this frame.
    pub fn syncNow(self: *Self) void {
        const priv = self.private();
        if (priv.sync_idle != 0) {
            _ = glib.Source.remove(priv.sync_idle);
            priv.sync_idle = 0;
        }
        if (priv.syncing) return;
        if (VerticalTab.activeDragPage() != null) return;
        if (TabGroupHeader.activeDragGroup() != null) return;
        self.syncLayout();
    }

    fn queueSync(self: *Self) void {
        const priv = self.private();
        if (priv.sync_idle != 0) return;
        priv.sync_idle = glib.idleAdd(syncIdle, self);
    }

    fn syncIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse
            return @intFromBool(glib.SOURCE_REMOVE)));
        const priv = self.private();
        priv.sync_idle = 0;
        if (priv.syncing) return @intFromBool(glib.SOURCE_REMOVE);
        if (VerticalTab.activeDragPage() != null)
            return @intFromBool(glib.SOURCE_REMOVE);
        if (TabGroupHeader.activeDragGroup() != null)
            return @intFromBool(glib.SOURCE_REMOVE);
        self.syncLayout();
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    const group_box_key = "holoctty-group-box";

    fn syncLayout(self: *Self) void {
        const priv = self.private();
        priv.syncing = true;
        defer priv.syncing = false;

        const view = priv.view orelse {
            self.clearList();
            return;
        };

        var tabs: [64]TabSlot = undefined;
        var tab_len: usize = 0;
        var headers: [32]HeaderSlot = undefined;
        var header_len: usize = 0;
        var boxes: [32]BoxSlot = undefined;
        var box_len: usize = 0;
        var held: [96]*gtk.Widget = undefined;
        var held_len: usize = 0;

        var child = priv.tab_list.as(gtk.Widget).getFirstChild();
        while (child) |cur| {
            const next = cur.getNextSibling();
            self.harvest(
                cur,
                &tabs,
                &tab_len,
                &headers,
                &header_len,
                &boxes,
                &box_len,
                &held,
                &held_len,
            );
            priv.tab_list.remove(cur);
            child = next;
        }

        var last_group: ?*TabGroup = null;
        var current_box: ?*gtk.Box = null;
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            const page = view.getNthPage(i);
            const group = TabGroup.forPage(page);
            if (group) |g| {
                if (g != last_group) {
                    const box_widget = self.takeBox(boxes[0..box_len], g) orelse
                        self.makeBox(g);
                    self.styleBox(box_widget, g);
                    const box = gobject.ext.cast(gtk.Box, box_widget).?;
                    const header = self.takeHeader(headers[0..header_len], g) orelse
                        self.makeHeader(g, view);
                    box.append(header);
                    priv.tab_list.append(box_widget);
                    current_box = box;
                    last_group = g;
                }
            } else {
                last_group = null;
                current_box = null;
            }

            const widget = self.takeTab(tabs[0..tab_len], page) orelse
                self.makeTab(page);
            if (current_box) |box| {
                box.append(widget);
            } else {
                priv.tab_list.append(widget);
            }
            if (gobject.ext.cast(VerticalTab, widget)) |tab| {
                tab.syncGroupStyle();
                tab.syncSelected();
                tab.setCompact(if (group) |g| g.getCollapsed() else false);
            }
        }

        for (held[0..held_len]) |widget| widget.as(gobject.Object).unref();
    }

    fn harvest(
        self: *Self,
        widget: *gtk.Widget,
        tabs: *[64]TabSlot,
        tab_len: *usize,
        headers: *[32]HeaderSlot,
        header_len: *usize,
        boxes: *[32]BoxSlot,
        box_len: *usize,
        held: *[96]*gtk.Widget,
        held_len: *usize,
    ) void {
        _ = widget.as(gobject.Object).ref();
        if (held_len.* < held.len) {
            held[held_len.*] = widget;
            held_len.* += 1;
        }

        if (groupFromBox(widget)) |group| {
            if (box_len.* < boxes.len) {
                boxes[box_len.*] = .{ .group = group, .widget = widget, .used = false };
                box_len.* += 1;
            }
            const box = gobject.ext.cast(gtk.Box, widget) orelse return;
            while (widget.getFirstChild()) |inner| {
                self.harvest(
                    inner,
                    tabs,
                    tab_len,
                    headers,
                    header_len,
                    boxes,
                    box_len,
                    held,
                    held_len,
                );
                box.remove(inner);
            }
            return;
        }

        if (gobject.ext.cast(VerticalTab, widget)) |tab| {
            if (tab.getPage()) |page| {
                if (tab_len.* < tabs.len) {
                    tabs[tab_len.*] = .{ .page = page, .widget = widget, .used = false };
                    tab_len.* += 1;
                }
            }
            return;
        }

        if (gobject.ext.cast(TabGroupHeader, widget)) |header| {
            if (header.getGroup()) |group| {
                if (header_len.* < headers.len) {
                    headers[header_len.*] = .{ .group = group, .widget = widget, .used = false };
                    header_len.* += 1;
                }
            }
        }
    }

    fn groupFromBox(widget: *gtk.Widget) ?*TabGroup {
        const ptr = widget.as(gobject.Object).getData(group_box_key) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn destroyBoxGroup(data: ?*anyopaque) callconv(.c) void {
        const group: *TabGroup = @ptrCast(@alignCast(data orelse return));
        group.unref();
    }

    fn styleBox(self: *Self, widget: *gtk.Widget, group: *TabGroup) void {
        _ = self;
        for (std.enums.values(Color)) |color| {
            widget.removeCssClass(color.cssClass());
        }
        widget.addCssClass(group.getColor().cssClass());
        if (group.getCollapsed()) {
            widget.addCssClass("collapsed");
        } else {
            widget.removeCssClass("collapsed");
        }
    }

    fn makeBox(self: *Self, group: *TabGroup) *gtk.Widget {
        _ = self;
        const box = gtk.Box.new(.vertical, 2);
        const widget = box.as(gtk.Widget);
        widget.addCssClass("tab-group-box");
        widget.setHexpand(1);
        widget.setHalign(.fill);
        _ = group.ref();
        widget.as(gobject.Object).setDataFull(group_box_key, group, destroyBoxGroup);
        return widget;
    }

    const TabSlot = struct { page: *adw.TabPage, widget: *gtk.Widget, used: bool };
    const HeaderSlot = struct { group: *TabGroup, widget: *gtk.Widget, used: bool };
    const BoxSlot = struct { group: *TabGroup, widget: *gtk.Widget, used: bool };

    fn takeTab(self: *Self, slots: []TabSlot, page: *adw.TabPage) ?*gtk.Widget {
        _ = self;
        for (slots) |*slot| {
            if (!slot.used and slot.page == page) {
                slot.used = true;
                return slot.widget;
            }
        }
        return null;
    }

    fn takeBox(self: *Self, slots: []BoxSlot, group: *TabGroup) ?*gtk.Widget {
        _ = self;
        for (slots) |*slot| {
            if (!slot.used and slot.group == group) {
                slot.used = true;
                return slot.widget;
            }
        }
        return null;
    }

    fn takeHeader(self: *Self, slots: []HeaderSlot, group: *TabGroup) ?*gtk.Widget {
        _ = self;
        for (slots) |*slot| {
            if (!slot.used and slot.group == group) {
                slot.used = true;
                if (gobject.ext.cast(TabGroupHeader, slot.widget)) |header| {
                    header.syncFromGroup();
                }
                return slot.widget;
            }
        }
        return null;
    }

    fn makeTab(self: *Self, page: *adw.TabPage) *gtk.Widget {
        _ = self;
        const tab = VerticalTab.new(page);
        const widget = tab.as(gtk.Widget);
        widget.setHexpand(1);
        widget.setHalign(.fill);
        return widget;
    }

    fn makeHeader(self: *Self, group: *TabGroup, view: *adw.TabView) *gtk.Widget {
        const header = TabGroupHeader.new(group, view);
        _ = TabGroupHeader.signals.@"new-tab".connect(
            header,
            *Self,
            headerNewTab,
            self,
            .{},
        );
        const widget = header.as(gtk.Widget);
        widget.setHexpand(1);
        widget.setHalign(.fill);
        return widget;
    }

    fn headerNewTab(
        header: *TabGroupHeader,
        self: *Self,
    ) callconv(.c) void {
        const group = header.getGroup() orelse return;
        const win = ext.getAncestor(Window, self.as(gtk.Widget)) orelse return;
        win.newTabInGroup(group);
    }

    fn clearList(self: *Self) void {
        const list = self.private().tab_list;
        while (list.as(gtk.Widget).getFirstChild()) |child| {
            list.remove(child);
        }
    }

    fn reorderAtPointer(self: *Self) void {
        if (TabGroupHeader.activeDragGroup() != null) return;
        const priv = self.private();
        const dragged = VerticalTab.activeDragPage() orelse return;
        const picked = priv.scrolled_window.as(gtk.Widget).pick(
            priv.drag_x,
            priv.drag_y,
            .{},
        ) orelse return;
        // Membership is applied on drop. Motion only reorders TabView pages.
        const row = ext.getAncestor(VerticalTab, picked) orelse return;
        const target = row.getPage() orelse return;
        if (target == dragged) return;
        const view = priv.view orelse return;

        var found = false;
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            if (view.getNthPage(i) == dragged) {
                found = true;
                break;
            }
        }
        if (!found) return;
        _ = view.reorderPage(dragged, view.getPagePosition(target));
    }

    fn dragMotion(
        _: *gtk.DropControllerMotion,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.drag_x = x;
        priv.drag_y = y;
        priv.drag_inside = true;
        self.reorderAtPointer();
        if (priv.tick_id == 0) {
            priv.tick_id = priv.scrolled_window.as(gtk.Widget).addTickCallback(
                dragTick,
                self,
                null,
            );
        }
    }

    fn tabBarDrop(
        _: *gtk.DropTarget,
        value: *const gobject.Value,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const id = value.getUint64();
        const view = self.private().view orelse return @intFromBool(false);
        const win = ext.getAncestor(Window, self.as(gtk.Widget)) orelse
            return @intFromBool(false);
        if (Window.findSurfaceByDragId(id) != null) {
            win.adoptDragIdAsTab(id, view.getNPages());
            return @intFromBool(true);
        }
        if (Window.findTabGroup(id)) |group| {
            group.moveInView(view, view.getNPages());
            self.syncNow();
            return @intFromBool(true);
        }
        const found = Window.findTabPage(id) orelse return @intFromBool(false);
        if (found.view == view) {
            TabGroup.bindPage(found.page, null);
            _ = view.reorderPage(found.page, view.getNPages() - 1);
        } else {
            TabGroup.splitOnTransfer(found.page, found.view);
            found.view.transferPage(found.page, view, view.getNPages());
        }
        self.sync();
        return @intFromBool(true);
    }

    fn dragLeave(
        _: *gtk.DropControllerMotion,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.drag_inside = false;
        if (priv.tick_id != 0) {
            priv.scrolled_window.as(gtk.Widget).removeTickCallback(priv.tick_id);
            priv.tick_id = 0;
        }
    }

    fn dragTick(
        _: *gtk.Widget,
        _: *gdk.FrameClock,
        data: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        const priv = self.private();
        if (!priv.drag_inside or VerticalTab.activeDragPage() == null) {
            priv.tick_id = 0;
            return 0;
        }

        const height: f64 = @floatFromInt(priv.scrolled_window.as(gtk.Widget).getHeight());
        const edge = @min(72.0, height * 0.22);
        var delta: f64 = 0;
        if (priv.drag_y < edge) {
            delta = -12.0 * (1.0 - @max(0.0, priv.drag_y) / edge);
        } else if (priv.drag_y > height - edge) {
            delta = 12.0 * (1.0 - @max(0.0, height - priv.drag_y) / edge);
        }

        if (delta != 0) {
            const adjustment = priv.scrolled_window.getVadjustment();
            const maximum = @max(0.0, adjustment.getUpper() - adjustment.getPageSize());
            adjustment.setValue(@min(maximum, @max(0.0, adjustment.getValue() + delta)));
            self.reorderAtPointer();
        }
        return 1;
    }

    fn disconnectView(self: *Self, view: *adw.TabView) void {
        const priv = self.private();
        const obj = view.as(gobject.Object);
        if (priv.attached_handler != 0) {
            gobject.signalHandlerDisconnect(obj, priv.attached_handler);
            priv.attached_handler = 0;
        }
        if (priv.detached_handler != 0) {
            gobject.signalHandlerDisconnect(obj, priv.detached_handler);
            priv.detached_handler = 0;
        }
        if (priv.reordered_handler != 0) {
            gobject.signalHandlerDisconnect(obj, priv.reordered_handler);
            priv.reordered_handler = 0;
        }
        if (priv.selected_handler != 0) {
            gobject.signalHandlerDisconnect(obj, priv.selected_handler);
            priv.selected_handler = 0;
        }
    }

    fn connectView(self: *Self, view: *adw.TabView) void {
        const priv = self.private();
        priv.attached_handler = adw.TabView.signals.page_attached.connect(
            view,
            *Self,
            pageAttached,
            self,
            .{},
        );
        priv.detached_handler = adw.TabView.signals.page_detached.connect(
            view,
            *Self,
            pageDetached,
            self,
            .{},
        );
        priv.reordered_handler = adw.TabView.signals.page_reordered.connect(
            view,
            *Self,
            pageReordered,
            self,
            .{},
        );
        priv.selected_handler = gobject.Object.signals.notify.connect(
            view,
            *Self,
            selectedChanged,
            self,
            .{ .detail = "selected-page" },
        );
    }

    fn pageAttached(
        _: *adw.TabView,
        _: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        self.sync();
    }

    fn pageDetached(
        _: *adw.TabView,
        _: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        self.sync();
    }

    fn pageReordered(
        _: *adw.TabView,
        _: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        self.sync();
    }

    fn selectedChanged(
        view: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        if (view.getSelectedPage()) |page| {
            if (TabGroup.forPage(page)) |group| {
                if (group.getCollapsed()) {
                    group.setCollapsed(false);
                    self.sync();
                    return;
                }
            }
        }
        self.syncSelectionOnly();
    }

    fn syncSelectionOnly(self: *Self) void {
        var child = self.private().tab_list.as(gtk.Widget).getFirstChild();
        while (child) |cur| {
            if (gobject.ext.cast(VerticalTab, cur)) |tab| {
                tab.syncSelected();
            } else if (gobject.ext.cast(TabGroupHeader, cur)) |header| {
                header.syncFromGroup();
            }
            child = cur.getNextSibling();
        }
    }

    fn mapped(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.connected_view == null) {
            if (priv.view) |view| {
                self.connectView(view);
                priv.connected_view = view;
            }
        }
        if (VerticalTab.activeDragPage() == null) self.syncLayout();
    }

    fn propView(
        _: *Self,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.connected_view) |old| {
            self.disconnectView(old);
            priv.connected_view = null;
        }
        if (priv.view) |view| {
            self.connectView(view);
            priv.connected_view = view;
        }
        if (VerticalTab.activeDragPage() == null) self.syncLayout();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.sync_idle != 0) {
            _ = glib.Source.remove(priv.sync_idle);
            priv.sync_idle = 0;
        }
        if (priv.tick_id != 0) {
            priv.scrolled_window.as(gtk.Widget).removeTickCallback(priv.tick_id);
            priv.tick_id = 0;
        }
        if (priv.connected_view) |view| {
            self.disconnectView(view);
            priv.connected_view = null;
        }
        if (priv.view) |view| {
            view.unref();
            priv.view = null;
        }
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(VerticalTab);
            gobject.ext.ensureType(TabGroupHeader);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "vertical-tab-bar",
                }),
            );

            gobject.ext.registerProperties(class, &.{
                properties.view.impl,
            });

            class.bindTemplateChildPrivate("scrolled_window", .{});
            class.bindTemplateChildPrivate("tab_bar_drop_target", .{});
            class.bindTemplateChildPrivate("tab_list", .{});
            class.bindTemplateCallback("drag_motion", &dragMotion);
            class.bindTemplateCallback("drag_leave", &dragLeave);
            class.bindTemplateCallback("tab_bar_drop", &tabBarDrop);
            class.bindTemplateCallback("notify_view", &propView);
            class.bindTemplateCallback("mapped", &mapped);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
