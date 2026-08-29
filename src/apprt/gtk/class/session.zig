const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Color = @import("tab_group.zig").Color;

var next_color_index: usize = 1;

/// A session owns a tab view while the session isn't selected. The selected
/// session's pages are temporarily moved into the window's visible tab view.
/// Keeping this as a widget lets AdwTabView move the entire session between
/// windows using its normal tab drag-and-drop behavior.
pub const Session = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "HolocttySession",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
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
    };

    const Private = struct {
        tab_view: *adw.TabView,
        /// When this session is selected, its pages live in the window tab
        /// view instead of `tab_view`. Null means pages are in `tab_view`.
        hosted_tab_view: ?*adw.TabView = null,

        /// Name of the snapshot this session updates when saved. Null means
        /// the session has never been saved or restored.
        snapshot_name: ?[:0]const u8 = null,

        color: Color = .blue,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const colors = std.enums.values(Color);
        self.private().color = colors[next_color_index % colors.len];
        next_color_index = (next_color_index + 1) % colors.len;
    }

    pub fn getTabView(self: *Self) *adw.TabView {
        return self.private().tab_view;
    }

    /// Tab view that currently holds this session's pages.
    pub fn getPagesTabView(self: *Self) *adw.TabView {
        const priv = self.private();
        return priv.hosted_tab_view orelse priv.tab_view;
    }

    pub fn setHostedTabView(self: *Self, view: ?*adw.TabView) void {
        self.private().hosted_tab_view = view;
    }

    pub fn getColor(self: *Self) Color {
        return self.private().color;
    }

    pub fn setColor(self: *Self, color: Color) void {
        if (self.private().color == color) return;
        self.private().color = color;
        self.as(gobject.Object).notifyByPspec(properties.color.impl.param_spec);
    }

    pub fn getSnapshotName(self: *Self) ?[:0]const u8 {
        return self.private().snapshot_name;
    }

    pub fn setSnapshotName(self: *Self, name: ?[]const u8) void {
        const priv = self.private();
        if (priv.snapshot_name) |value| glib.free(@ptrCast(@constCast(value)));
        priv.snapshot_name = null;
        if (name) |value| priv.snapshot_name = glib.ext.dupeZ(u8, value);
    }

    fn dispose(self: *Self) callconv(.c) void {
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.snapshot_name) |value| {
            glib.free(@ptrCast(@constCast(value)));
            priv.snapshot_name = null;
        }
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
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "session",
                }),
            );

            gobject.ext.registerProperties(class, &.{properties.color.impl});
            class.bindTemplateChildPrivate("tab_view", .{});
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
