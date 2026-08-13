const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const SessionTab = @import("session_tab.zig").SessionTab;

/// Horizontal bar of session tabs bound to an AdwTabView.
pub const SessionTabBar = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "HolocttySessionTabBar",
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
        attached_handler: c_ulong = 0,
        detached_handler: c_ulong = 0,
        reordered_handler: c_ulong = 0,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn clearTabs(self: *Self) void {
        const box = self.as(gtk.Box);
        while (self.as(gtk.Widget).getFirstChild()) |child| {
            box.remove(child);
        }
    }

    fn addTab(self: *Self, page: *adw.TabPage, position: c_int) void {
        const tab = SessionTab.new(page);
        const widget = tab.as(gtk.Widget);
        widget.setHexpand(1);
        widget.setHalign(.fill);
        const box = self.as(gtk.Box);
        if (position <= 0) {
            box.prepend(widget);
            return;
        }
        var sibling = self.as(gtk.Widget).getFirstChild();
        var i: c_int = 0;
        while (sibling) |cur| : (i += 1) {
            if (i == position - 1) {
                box.insertChildAfter(widget, cur);
                return;
            }
            sibling = cur.getNextSibling();
        }
        box.append(widget);
    }

    fn findTab(self: *Self, page: *adw.TabPage) ?*gtk.Widget {
        var child = self.as(gtk.Widget).getFirstChild();
        while (child) |cur| {
            if (gobject.ext.cast(SessionTab, cur)) |tab| {
                if (tab.getPage() == page) return cur;
            }
            child = cur.getNextSibling();
        }
        return null;
    }

    fn removeTab(self: *Self, page: *adw.TabPage) void {
        if (self.findTab(page)) |widget| {
            self.as(gtk.Box).remove(widget);
        }
    }

    fn rebuild(self: *Self) void {
        self.clearTabs();
        const view = self.private().view orelse return;
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            self.addTab(view.getNthPage(i), i);
        }
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
    }

    fn pageAttached(
        _: *adw.TabView,
        page: *adw.TabPage,
        position: c_int,
        self: *Self,
    ) callconv(.c) void {
        if (self.findTab(page) != null) return;
        self.addTab(page, position);
    }

    fn pageDetached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        self.removeTab(page);
    }

    fn pageReordered(
        _: *adw.TabView,
        page: *adw.TabPage,
        position: c_int,
        self: *Self,
    ) callconv(.c) void {
        const widget = self.findTab(page) orelse return;
        self.as(gtk.Box).remove(widget);
        self.addExisting(widget, position);
    }

    fn addExisting(self: *Self, widget: *gtk.Widget, position: c_int) void {
        const box = self.as(gtk.Box);
        if (position <= 0) {
            box.prepend(widget);
            return;
        }
        var sibling = self.as(gtk.Widget).getFirstChild();
        var i: c_int = 0;
        while (sibling) |cur| : (i += 1) {
            if (i == position - 1) {
                box.insertChildAfter(widget, cur);
                return;
            }
            sibling = cur.getNextSibling();
        }
        box.append(widget);
    }

    fn mapped(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.connected_view == null) {
            if (priv.view) |view| {
                self.connectView(view);
                priv.connected_view = view;
            }
        }
        self.rebuild();
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
        self.rebuild();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
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
            gobject.ext.ensureType(SessionTab);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "session-tab-bar",
                }),
            );

            gobject.ext.registerProperties(class, &.{
                properties.view.impl,
            });

            class.bindTemplateCallback("notify_view", &propView);
            class.bindTemplateCallback("mapped", &mapped);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
