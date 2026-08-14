const adw = @import("adw");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
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
        scrolled_window: *gtk.ScrolledWindow,
        tab_bar_drop_target: *gtk.DropTarget,
        drag_x: f64 = 0,
        drag_y: f64 = 0,
        drag_inside: bool = false,
        tick_id: c_uint = 0,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        var drop_types = [_]gobject.Type{gobject.ext.types.uint64};
        self.private().tab_bar_drop_target.setGtypes(&drop_types, drop_types.len);
    }

    fn reorderAtPointer(self: *Self) void {
        const priv = self.private();
        const dragged = VerticalTab.activeDragPage() orelse return;
        const picked = priv.scrolled_window.as(gtk.Widget).pick(
            priv.drag_x,
            priv.drag_y,
            .{},
        ) orelse return;
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
        const found = Window.findTabPage(id) orelse return @intFromBool(false);
        if (found.view == view) {
            _ = view.reorderPage(found.page, view.getNPages() - 1);
        } else {
            found.view.transferPage(found.page, view, view.getNPages());
        }
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

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.tick_id != 0) {
            priv.scrolled_window.as(gtk.Widget).removeTickCallback(priv.tick_id);
            priv.tick_id = 0;
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
            class.bindTemplateCallback("drag_motion", &dragMotion);
            class.bindTemplateCallback("drag_leave", &dragLeave);
            class.bindTemplateCallback("tab_bar_drop", &tabBarDrop);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
