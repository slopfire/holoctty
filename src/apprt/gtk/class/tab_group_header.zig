const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const i18n = @import("../../../os/main.zig").i18n;
const Common = @import("../class.zig").Common;
const TabGroup = @import("tab_group.zig").TabGroup;
const Color = @import("tab_group.zig").Color;
const Window = @import("window.zig").Window;

/// Colored chip heading a contiguous tab group in the vertical sidebar.
pub const TabGroupHeader = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    var active_drag_group: ?*TabGroup = null;

    pub fn activeDragGroup() ?*TabGroup {
        return active_drag_group;
    }
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "HolocttyTabGroupHeader",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const group = struct {
            pub const name = "group";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*TabGroup,
                .{
                    .accessor = C.privateObjFieldAccessor("group"),
                },
            );
        };

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

        pub const label = struct {
            pub const name = "label";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("label"),
                },
            );
        };

        pub const @"chevron-icon" = struct {
            pub const name = "chevron-icon";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = "pan-down-symbolic",
                    .accessor = C.privateStringFieldAccessor("chevron_icon"),
                },
            );
        };
    };

    pub const signals = struct {
        pub const @"new-tab" = struct {
            pub const name = "new-tab";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };

        pub const @"layout-changed" = struct {
            pub const name = "layout-changed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    const Private = struct {
        group: ?*TabGroup = null,
        view: ?*adw.TabView = null,
        label: ?[:0]const u8 = null,
        chevron_icon: ?[:0]const u8 = null,
        group_drop_target: *gtk.DropTarget,
        new_tab_button: *gtk.Button,
        drag_x: f64 = 0,
        drag_y: f64 = 0,
        drag_cancelled: bool = false,
        drag_drop_performed: bool = false,
        drag_torn_out: bool = false,
        dragged: bool = false,
        name_handler: c_ulong = 0,
        color_handler: c_ulong = 0,
        collapsed_handler: c_ulong = 0,
        connected_group: ?*TabGroup = null,

        pub var offset: c_int = 0;
    };

    pub fn new(group: *TabGroup, view: *adw.TabView) *Self {
        return gobject.ext.newInstance(Self, .{
            .group = group,
            .view = view,
        });
    }

    pub fn getGroup(self: *Self) ?*TabGroup {
        return self.private().group;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.setString("chevron_icon", "pan-down-symbolic");
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        var drop_types = [_]gobject.Type{gobject.ext.types.uint64};
        self.private().group_drop_target.setGtypes(&drop_types, drop_types.len);
        self.syncFromGroup();
    }

    fn setString(self: *Self, comptime field: []const u8, value: [:0]const u8) void {
        const priv = self.private();
        if (@field(priv, field)) |current| {
            if (std.mem.eql(u8, current, value)) return;
            glib.free(@ptrCast(@constCast(current)));
        }
        @field(priv, field) = glib.ext.dupeZ(u8, value);
        if (comptime std.mem.eql(u8, field, "label")) {
            self.as(gobject.Object).notifyByPspec(properties.label.impl.param_spec);
        } else {
            self.as(gobject.Object).notifyByPspec(properties.@"chevron-icon".impl.param_spec);
        }
    }

    fn propGroup(
        _: *Self,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.connectGroup();
        self.syncFromGroup();
    }

    fn connectGroup(self: *Self) void {
        const priv = self.private();
        if (priv.connected_group) |old| {
            const obj = old.as(gobject.Object);
            if (priv.name_handler != 0)
                gobject.signalHandlerDisconnect(obj, priv.name_handler);
            if (priv.color_handler != 0)
                gobject.signalHandlerDisconnect(obj, priv.color_handler);
            if (priv.collapsed_handler != 0)
                gobject.signalHandlerDisconnect(obj, priv.collapsed_handler);
            priv.name_handler = 0;
            priv.color_handler = 0;
            priv.collapsed_handler = 0;
            priv.connected_group = null;
        }
        const group = priv.group orelse return;
        const obj = group.as(gobject.Object);
        priv.name_handler = gobject.Object.signals.notify.connect(
            obj,
            *Self,
            groupNotify,
            self,
            .{ .detail = "name" },
        );
        priv.color_handler = gobject.Object.signals.notify.connect(
            obj,
            *Self,
            groupNotify,
            self,
            .{ .detail = "color" },
        );
        priv.collapsed_handler = gobject.Object.signals.notify.connect(
            obj,
            *Self,
            groupLayoutNotify,
            self,
            .{ .detail = "collapsed" },
        );
        priv.connected_group = group;
    }

    fn groupNotify(
        _: *gobject.Object,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncFromGroup();
    }

    fn groupLayoutNotify(
        _: *gobject.Object,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncFromGroup();
        signals.@"layout-changed".impl.emit(self, null, .{}, null);
    }

    pub fn syncFromGroup(self: *Self) void {
        const priv = self.private();
        const group = priv.group orelse return;
        const count: c_int = if (priv.view) |view| group.memberCount(view) else 0;
        var buf: [128]u8 = undefined;
        self.setString("label", group.displayLabel(count, &buf));
        const collapsed = group.getCollapsed();
        self.setString(
            "chevron_icon",
            if (collapsed)
                "pan-end-symbolic"
            else
                "pan-down-symbolic",
        );
        const widget = self.as(gtk.Widget);
        if (collapsed) {
            widget.addCssClass("collapsed");
        } else {
            widget.removeCssClass("collapsed");
        }
        priv.new_tab_button.as(gtk.Widget).setVisible(@intFromBool(!collapsed));
    }

    fn toggle(
        _: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        const group = self.private().group orelse return;
        group.toggleCollapsed();
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |window| {
            window.syncTabGroups();
        }
    }

    fn newTab(
        _: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        signals.@"new-tab".impl.emit(self, null, .{}, null);
    }

    fn contextMenu(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        _ = gesture.as(gtk.Gesture).setState(.claimed);
        self.popupMenu();
    }

    fn popupMenu(self: *Self) void {
        const box = gtk.Box.new(.vertical, 2);
        self.appendMenuButton(box, i18n._("Name this group…"), menuRename);
        self.appendMenuButton(box, i18n._("New Tab in Group"), menuNewTab);

        const colors = gtk.Box.new(.horizontal, 4);
        colors.as(gtk.Widget).setHalign(.start);
        colors.as(gtk.Widget).setMarginStart(6);
        colors.as(gtk.Widget).setMarginEnd(6);
        colors.as(gtk.Widget).setMarginTop(4);
        colors.as(gtk.Widget).setMarginBottom(4);
        for (std.enums.values(Color)) |color| {
            self.appendColorButton(colors, color);
        }
        box.append(colors.as(gtk.Widget));

        self.appendMenuButton(box, i18n._("Ungroup"), menuUngroup);
        self.appendMenuButton(box, i18n._("Close group"), menuClose);

        const popover = gtk.Popover.new();
        popover.setHasArrow(0);
        popover.setChild(box.as(gtk.Widget));
        popover.as(gtk.Widget).setParent(self.as(gtk.Widget));
        _ = gtk.Popover.signals.closed.connect(
            popover,
            *gtk.Popover,
            popoverClosed,
            popover,
            .{},
        );
        popover.popup();
    }

    fn appendMenuButton(
        self: *Self,
        box: *gtk.Box,
        label: [*:0]const u8,
        callback: *const fn (*gtk.Button, *Self) callconv(.c) void,
    ) void {
        const button = gtk.Button.newWithLabel(label);
        button.as(gtk.Widget).setHalign(.fill);
        button.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(button, *Self, callback, self, .{});
        box.append(button.as(gtk.Widget));
    }

    fn appendColorButton(self: *Self, box: *gtk.Box, color: Color) void {
        const button = gtk.Button.new();
        button.as(gtk.Widget).addCssClass("flat");
        button.as(gtk.Widget).addCssClass("tab-group-color-choice");
        button.as(gtk.Widget).addCssClass(color.cssClass());
        button.as(gtk.Widget).setTooltipText(color.label());
        button.as(gobject.Object).setData("holoctty-color", @ptrFromInt(@as(usize, @intCast(@intFromEnum(color))) + 1));
        _ = gtk.Button.signals.clicked.connect(button, *Self, menuSetColor, self, .{});
        box.append(button.as(gtk.Widget));
    }

    fn closeMenu(button: *gtk.Button) void {
        if (ext.getAncestor(gtk.Popover, button.as(gtk.Widget))) |popover| {
            popover.popdown();
        }
    }

    fn menuRename(
        button: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        closeMenu(button);
        const group = self.private().group orelse return;
        const dialog = adw.AlertDialog.new(
            i18n._("Name this group"),
            i18n._("Leave blank to use the color name."),
        );
        dialog.addResponse("cancel", i18n._("Cancel"));
        dialog.addResponse("ok", i18n._("OK"));
        dialog.setResponseAppearance("ok", .suggested);
        dialog.setDefaultResponse("ok");
        const entry = gtk.Entry.new();
        entry.setActivatesDefault(1);
        if (group.getName()) |name| {
            entry.getBuffer().setText(name, -1);
        }
        dialog.setExtraChild(entry.as(gtk.Widget));
        dialog.as(gobject.Object).setData("holoctty-rename-entry", entry);
        _ = group.ref();
        dialog.as(gobject.Object).setDataFull(
            "holoctty-rename-group",
            group,
            renameGroupDestroy,
        );
        dialog.choose(
            self.as(gtk.Widget),
            null,
            renameGroupReady,
            self,
        );
    }

    fn renameGroupDestroy(data: ?*anyopaque) callconv(.c) void {
        const group: *TabGroup = @ptrCast(@alignCast(data orelse return));
        group.unref();
    }

    fn renameGroupReady(
        object: ?*gobject.Object,
        result: *gio.AsyncResult,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const dialog: *adw.AlertDialog = @ptrCast(@alignCast(object orelse return));
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        const response = dialog.chooseFinish(result);
        if (std.mem.orderZ(u8, "ok", response) != .eq) return;
        const group_ptr = dialog.as(gobject.Object).getData("holoctty-rename-group") orelse
            return;
        const group: *TabGroup = @ptrCast(@alignCast(group_ptr));
        const entry_ptr = dialog.as(gobject.Object).getData("holoctty-rename-entry") orelse
            return;
        const entry: *gtk.Entry = @ptrCast(@alignCast(entry_ptr));
        const text = std.mem.span(entry.getBuffer().getText());
        group.setName(if (text.len > 0) text else null);
        self.syncFromGroup();
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
            win.syncTabGroups();
        }
    }

    fn menuNewTab(
        button: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        closeMenu(button);
        signals.@"new-tab".impl.emit(self, null, .{}, null);
    }

    fn menuSetColor(
        button: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        closeMenu(button);
        const ptr = button.as(gobject.Object).getData("holoctty-color") orelse return;
        const index: i32 = @intCast(@intFromPtr(ptr) - 1);
        const color = Color.fromIndex(index) orelse return;
        const group = self.private().group orelse return;
        group.setColor(color);
        self.syncFromGroup();
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
            win.syncTabGroups();
        }
    }

    fn menuUngroup(
        button: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        closeMenu(button);
        const group = self.private().group orelse return;
        const view = self.private().view orelse return;
        group.ungroupInView(view);
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
            win.syncTabGroups();
        }
    }

    fn menuClose(
        button: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        closeMenu(button);
        const group = self.private().group orelse return;
        const view = self.private().view orelse return;
        group.closeInView(view);
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
            win.syncTabGroups();
        }
    }

    fn popoverClosed(
        _: *gtk.Popover,
        popover: *gtk.Popover,
    ) callconv(.c) void {
        popover.as(gtk.Widget).unparent();
        popover.as(gobject.Object).unref();
    }

    fn groupDragPrepare(
        _: *gtk.DragSource,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) ?*gdk.ContentProvider {
        const group = self.private().group orelse return null;
        self.private().drag_x = x;
        self.private().drag_y = y;
        var value = gobject.ext.Value.newFrom(@as(u64, @intFromPtr(group)));
        return gdk.ContentProvider.newForValue(&value);
    }

    fn groupDragBegin(
        source: *gtk.DragSource,
        drag: *gdk.Drag,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        active_drag_group = priv.group;
        priv.drag_cancelled = false;
        priv.drag_drop_performed = false;
        priv.drag_torn_out = false;
        priv.dragged = true;
        _ = gdk.Drag.signals.drop_performed.connect(
            drag,
            *Self,
            groupDragDropPerformed,
            self,
            .{},
        );

        const widget = self.as(gtk.Widget);
        const width = widget.getWidth();
        const height = widget.getHeight();
        if (width > 0 and height > 0) {
            const widget_paintable = gtk.WidgetPaintable.new(widget);
            defer widget_paintable.unref();
            const snapshot = gtk.Snapshot.new();
            widget_paintable.as(gdk.Paintable).snapshot(
                snapshot.as(gdk.Snapshot),
                @floatFromInt(width),
                @floatFromInt(height),
            );
            if (snapshot.freeToPaintable(null)) |preview| {
                defer preview.unref();
                source.setIcon(
                    preview,
                    @intFromFloat(priv.drag_x),
                    @intFromFloat(priv.drag_y),
                );
            }
        }
        widget.addCssClass("dragging");
    }

    fn groupDragDropPerformed(
        _: *gdk.Drag,
        self: *Self,
    ) callconv(.c) void {
        self.private().drag_drop_performed = true;
    }

    fn groupDragEnd(
        _: *gtk.DragSource,
        _: *gdk.Drag,
        delete_data: c_int,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (delete_data == 0 and !priv.drag_cancelled and !priv.drag_torn_out) {
            priv.drag_torn_out = true;
            if (priv.group) |group| {
                _ = Window.moveTabGroupToNewWindow(@intFromPtr(group));
            }
        }
        active_drag_group = null;
        priv.drag_cancelled = false;
        priv.drag_drop_performed = false;
        priv.drag_torn_out = false;
        self.as(gtk.Widget).removeCssClass("dragging");
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
            win.syncTabGroups();
        }
    }

    fn groupDragCancel(
        _: *gtk.DragSource,
        _: *gdk.Drag,
        reason: gdk.DragCancelReason,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        priv.drag_cancelled = true;
        const dropped_outside = reason == .no_target or
            (reason == .@"error" and priv.drag_drop_performed);
        if (dropped_outside and !priv.drag_torn_out) {
            priv.drag_torn_out = true;
            if (priv.group) |group| {
                if (Window.moveTabGroupToNewWindow(@intFromPtr(group)))
                    return @intFromBool(true);
            }
        }
        return @intFromBool(false);
    }

    fn groupDrop(
        _: *gtk.DropTarget,
        value: *const gobject.Value,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const group = self.private().group orelse return @intFromBool(false);
        const view = self.private().view orelse return @intFromBool(false);
        const id = value.getUint64();
        if (Window.findTabGroup(id)) |dragged| {
            if (dragged == group) return @intFromBool(true);
            const start = if (group.rangeInView(view)) |range| range.start else 0;
            dragged.moveInView(view, start);
            if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
                win.syncTabGroups();
            }
            self.as(gtk.Widget).removeCssClass("drop-target");
            return @intFromBool(true);
        }
        const found = Window.findTabPage(id) orelse return @intFromBool(false);
        if (found.view != view) {
            TabGroup.splitOnTransfer(found.page, found.view);
            found.view.transferPage(found.page, view, 0);
        }
        group.addPage(found.page, view);
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
            win.syncTabGroups();
        }
        self.as(gtk.Widget).removeCssClass("drop-target");
        return @intFromBool(true);
    }

    fn groupDropMotion(
        tgt: *gtk.DropTarget,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) gdk.DragAction {
        const value = tgt.getValue() orelse return .{};
        const id = value.getUint64();
        if (Window.findTabPage(id) != null or Window.findTabGroup(id) != null) {
            self.as(gtk.Widget).addCssClass("drop-target");
            return .{ .move = true };
        }
        return .{};
    }

    fn groupDropLeave(
        _: *gtk.DropTarget,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Widget).removeCssClass("drop-target");
    }

    fn dispose(self: *Self) callconv(.c) void {
        self.connectGroupClear();
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );
        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn connectGroupClear(self: *Self) void {
        const priv = self.private();
        if (priv.connected_group) |old| {
            const obj = old.as(gobject.Object);
            if (priv.name_handler != 0)
                gobject.signalHandlerDisconnect(obj, priv.name_handler);
            if (priv.color_handler != 0)
                gobject.signalHandlerDisconnect(obj, priv.color_handler);
            if (priv.collapsed_handler != 0)
                gobject.signalHandlerDisconnect(obj, priv.collapsed_handler);
        }
        priv.name_handler = 0;
        priv.color_handler = 0;
        priv.collapsed_handler = 0;
        priv.connected_group = null;
        if (priv.group) |group| {
            group.unref();
            priv.group = null;
        }
        if (priv.view) |view| {
            view.unref();
            priv.view = null;
        }
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.label) |value| glib.free(@ptrCast(@constCast(value)));
        if (priv.chevron_icon) |value| glib.free(@ptrCast(@constCast(value)));
        gobject.Object.virtual_methods.finalize.call(
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
            gobject.ext.ensureType(TabGroup);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "tab-group-header",
                }),
            );

            gobject.ext.registerProperties(class, &.{
                properties.group.impl,
                properties.view.impl,
                properties.label.impl,
                properties.@"chevron-icon".impl,
            });

            class.bindTemplateChildPrivate("group_drop_target", .{});
            class.bindTemplateChildPrivate("new_tab_button", .{});
            class.bindTemplateCallback("notify_group", &propGroup);
            class.bindTemplateCallback("toggle", &toggle);
            class.bindTemplateCallback("new_tab", &newTab);
            class.bindTemplateCallback("context_menu", &contextMenu);
            class.bindTemplateCallback("group_drag_prepare", &groupDragPrepare);
            class.bindTemplateCallback("group_drag_begin", &groupDragBegin);
            class.bindTemplateCallback("group_drag_end", &groupDragEnd);
            class.bindTemplateCallback("group_drag_cancel", &groupDragCancel);
            class.bindTemplateCallback("group_drop", &groupDrop);
            class.bindTemplateCallback("group_drop_motion", &groupDropMotion);
            class.bindTemplateCallback("group_drop_leave", &groupDropLeave);

            signals.@"new-tab".impl.register(.{});
            signals.@"layout-changed".impl.register(.{});

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
