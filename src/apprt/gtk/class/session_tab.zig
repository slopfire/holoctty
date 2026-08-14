const std = @import("std");
const builtin = @import("builtin");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const configpkg = @import("../../../config.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const cli_process = @import("../cli_process.zig");
const Common = @import("../class.zig").Common;
const Session = @import("session.zig").Session;
const Tab = @import("tab.zig").Tab;
const Window = @import("window.zig").Window;

/// A compact session switcher tab that shows a truncated row of the
/// processes running in that session.
pub const SessionTab = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    var active_drag_page: ?*adw.TabPage = null;

    const icon_px: c_int = 13;
    const icon_gap: c_int = 2;
    const max_icons: usize = 32;

    pub fn activeDragPage() ?*adw.TabPage {
        return active_drag_page;
    }

    pub fn getPage(self: *Self) ?*adw.TabPage {
        return self.private().page;
    }

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "HolocttySessionTab",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const page = struct {
            pub const name = "page";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*adw.TabPage,
                .{
                    .accessor = C.privateObjFieldAccessor("page"),
                },
            );
        };
    };

    const Private = struct {
        page: ?*adw.TabPage = null,
        process_row: *gtk.Box,
        tab_drop_target: *gtk.DropTarget,
        drag_x: f64 = 0,
        drag_y: f64 = 0,
        process_idle: ?c_uint = null,
        process_timer: ?c_uint = null,
        selected_page: ?*adw.TabPage = null,
        selected_handler: c_ulong = 0,
        title_view: ?*adw.TabView = null,
        title_view_handler: c_ulong = 0,
        title_page: ?*adw.TabPage = null,
        title_page_handler: c_ulong = 0,
        last_width: c_int = -1,
        last_height: c_int = -1,
        last_fingerprint: [512]u8 = undefined,
        last_fingerprint_len: usize = 0,

        pub var offset: c_int = 0;
    };

    pub fn new(page: *adw.TabPage) *Self {
        return gobject.ext.newInstance(Self, .{ .page = page });
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        var drop_types = [_]gobject.Type{gobject.ext.types.uint64};
        self.private().tab_drop_target.setGtypes(&drop_types, drop_types.len);
        self.syncSelected();
        self.syncTitleConnections();
        self.scheduleProcessIdle();
        self.private().process_timer = glib.timeoutAdd(
            1_000,
            processTimer,
            self,
        );
    }

    fn processIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse
            return @intFromBool(glib.SOURCE_REMOVE)));
        self.private().process_idle = null;
        self.syncTitleConnections();
        self.updateProcessRow();
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    fn scheduleProcessIdle(self: *Self) void {
        const priv = self.private();
        if (priv.process_idle != null) return;
        priv.process_idle = glib.idleAdd(processIdle, self);
    }

    fn processTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse
            return @intFromBool(glib.SOURCE_REMOVE)));
        self.syncSelected();
        self.syncTitleConnections();
        self.updateProcessRow();
        return @intFromBool(glib.SOURCE_CONTINUE);
    }

    fn propPage(
        _: *Self,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.selected_page) |old| {
            if (priv.selected_handler != 0) {
                gobject.signalHandlerDisconnect(
                    old.as(gobject.Object),
                    priv.selected_handler,
                );
            }
            priv.selected_handler = 0;
            priv.selected_page = null;
        }
        if (priv.page) |page| {
            priv.selected_handler = gobject.Object.signals.notify.connect(
                page,
                *Self,
                pageSelected,
                self,
                .{ .detail = "selected" },
            );
            priv.selected_page = page;
        }
        self.syncSelected();
        self.syncTitleConnections();
        self.scheduleProcessIdle();
    }

    fn pageSelected(
        _: *adw.TabPage,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncSelected();
        self.syncTitleConnections();
        self.scheduleProcessIdle();
    }

    fn titleViewSelected(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncTitleConnections();
    }

    fn titlePageChanged(
        _: *adw.TabPage,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncSessionTitle();
    }

    fn disconnectTitlePage(self: *Self) void {
        const priv = self.private();
        if (priv.title_page) |page| {
            if (priv.title_page_handler != 0) {
                gobject.signalHandlerDisconnect(
                    page.as(gobject.Object),
                    priv.title_page_handler,
                );
            }
        }
        priv.title_page = null;
        priv.title_page_handler = 0;
    }

    fn disconnectTitleView(self: *Self) void {
        const priv = self.private();
        self.disconnectTitlePage();
        if (priv.title_view) |view| {
            if (priv.title_view_handler != 0) {
                gobject.signalHandlerDisconnect(
                    view.as(gobject.Object),
                    priv.title_view_handler,
                );
            }
        }
        priv.title_view = null;
        priv.title_view_handler = 0;
    }

    fn syncTitleConnections(self: *Self) void {
        const priv = self.private();
        const outer_page = priv.page orelse {
            self.disconnectTitleView();
            return;
        };
        const session = gobject.ext.cast(Session, outer_page.getChild()) orelse {
            self.disconnectTitleView();
            return;
        };
        const view = session.getPagesTabView();
        if (priv.title_view != view) {
            self.disconnectTitleView();
            priv.title_view = view;
            priv.title_view_handler = gobject.Object.signals.notify.connect(
                view,
                *Self,
                titleViewSelected,
                self,
                .{ .detail = "selected-page" },
            );
        }

        const selected = view.getSelectedPage();
        if (priv.title_page != selected) {
            self.disconnectTitlePage();
            if (selected) |page| {
                priv.title_page = page;
                priv.title_page_handler = gobject.Object.signals.notify.connect(
                    page,
                    *Self,
                    titlePageChanged,
                    self,
                    .{ .detail = "title" },
                );
            }
        }
        self.syncSessionTitle();
    }

    fn syncSessionTitle(self: *Self) void {
        const priv = self.private();
        const outer_page = priv.page orelse return;
        const tab_title: [*:0]const u8 = if (priv.title_page) |page| title: {
            const value = page.getTitle();
            if (value[0] != 0) break :title value;
            break :title i18n._("Terminal");
        } else i18n._("New Session");

        var number_buf: [32]u8 = undefined;
        const title: [*:0]const u8 = if (self.sessionLabel() == .number)
            if (sessionViewOf(outer_page)) |view|
                std.fmt.bufPrintZ(
                    &number_buf,
                    "{d}",
                    .{view.getPagePosition(outer_page) + 1},
                ) catch tab_title
            else
                tab_title
        else
            tab_title;

        outer_page.setTooltip(tab_title);
        if (std.mem.eql(
            u8,
            std.mem.span(outer_page.getTitle()),
            std.mem.span(title),
        )) return;
        outer_page.setTitle(title);
        priv.last_fingerprint_len = 0;
        self.updateProcessRow();
    }

    fn sessionLabel(self: *Self) configpkg.Config.GtkSessionLabel {
        const window = ext.getAncestor(Window, self.as(gtk.Widget)) orelse
            return .number;
        const config = window.getConfig() orelse return .number;
        return config.get().@"gtk-session-label";
    }

    fn iconConfig(self: *Self) struct { tui: bool = true, shell: bool = true } {
        const window = ext.getAncestor(Window, self.as(gtk.Widget)) orelse
            return .{};
        const config = window.getConfig() orelse return .{};
        const core = config.get();
        return .{
            .tui = core.@"gtk-session-tui-icons",
            .shell = core.@"gtk-session-shell-icons",
        };
    }

    fn syncSelected(self: *Self) void {
        const widget = self.as(gtk.Widget);
        const selected = if (self.private().page) |page|
            page.getSelected() != 0
        else
            false;
        if (selected)
            widget.addCssClass("selected")
        else
            widget.removeCssClass("selected");
    }

    const Collected = struct {
        icons: [max_icons][:0]const u8 = undefined,
        names: [max_icons][:0]const u8 = undefined,
        count: usize = 0,

        fn append(
            self: *Collected,
            state: cli_process.ProcessState,
            show_tui: bool,
            show_shell: bool,
        ) void {
            const icon = if (state.remote and
                (cli_process.isShellIcon(state.icon) or
                    std.mem.eql(u8, state.icon, cli_process.default_icon)))
                cli_process.remote_icon
            else
                state.icon;

            if (cli_process.isTuiIcon(icon) and !show_tui) return;
            if (state.interactive_shell and !show_shell) return;

            for (self.icons[0..self.count]) |existing| {
                if (std.mem.eql(u8, existing, icon)) return;
            }
            if (self.count >= self.icons.len) return;
            self.icons[self.count] = icon;
            self.names[self.count] = cli_process.processName(icon);
            self.count += 1;
        }
    };

    fn collectProcesses(self: *Self) Collected {
        var collected: Collected = .{};
        if (comptime builtin.os.tag != .linux) return collected;

        const page = self.private().page orelse return collected;
        const session = gobject.ext.cast(Session, page.getChild()) orelse
            return collected;
        const icon_config = self.iconConfig();
        const view = session.getPagesTabView();
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            const tab_page = view.getNthPage(i);
            const tab = gobject.ext.cast(Tab, tab_page.getChild()) orelse
                continue;
            const tree = tab.getSurfaceTree() orelse continue;
            var it = tree.iterator();
            while (it.next()) |entry| {
                const core = entry.view.core() orelse continue;
                const pid = core.getProcessInfo(.foreground_pid) orelse
                    continue;
                collected.append(
                    cli_process.processTreeState(pid, 0),
                    icon_config.tui,
                    icon_config.shell,
                );
            }
        }
        return collected;
    }

    fn capacityForWidth(width: c_int) usize {
        const cell = icon_px + icon_gap;
        return @max(1, @as(usize, @intCast(@divFloor(@max(width, 0) + icon_gap, cell))));
    }

    fn fingerprint(
        collected: Collected,
        width: c_int,
        height: c_int,
        buf: []u8,
    ) []const u8 {
        var writer: std.Io.Writer = .fixed(buf);
        writer.print("{d}x{d}:{d}", .{ width, height, collected.count }) catch
            return buf[0..0];
        for (collected.icons[0..collected.count]) |icon| {
            writer.writeByte(',') catch break;
            writer.writeAll(icon) catch break;
        }
        return writer.buffered();
    }

    fn clearRow(row: *gtk.Box) void {
        while (row.as(gtk.Widget).getFirstChild()) |child| {
            row.remove(child);
        }
    }

    fn updateProcessRow(self: *Self) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);
        const width = widget.getWidth();
        const height = widget.getHeight();
        const collected = self.collectProcesses();

        var fp_buf: [512]u8 = undefined;
        const fp = fingerprint(collected, width, height, &fp_buf);
        if (fp.len > 0 and
            fp.len == priv.last_fingerprint_len and
            std.mem.eql(u8, fp, priv.last_fingerprint[0..priv.last_fingerprint_len]))
        {
            return;
        }
        const copy_len = @min(fp.len, priv.last_fingerprint.len);
        @memcpy(priv.last_fingerprint[0..copy_len], fp[0..copy_len]);
        priv.last_fingerprint_len = copy_len;
        priv.last_width = width;
        priv.last_height = height;

        clearRow(priv.process_row);

        const title = if (priv.page) |page| page.getTitle() else "";

        if (collected.count == 0) {
            priv.process_row.as(gtk.Widget).setVisible(0);
            self.as(gtk.Widget).setTooltipText(title);
            return;
        }

        priv.process_row.as(gtk.Widget).setVisible(1);
        const row_w = if (width > 0) width else widget.getAllocatedWidth();
        const capacity = capacityForWidth(if (row_w > 18) row_w - 18 else row_w);
        const overflow = collected.count > capacity;
        const visible = if (overflow and capacity > 1)
            capacity - 1
        else
            @min(collected.count, @max(capacity, 1));

        var tooltip_buf: [512]u8 = undefined;
        var tooltip_writer: std.Io.Writer = .fixed(&tooltip_buf);
        if (std.mem.span(title).len > 0) tooltip_writer.writeAll(std.mem.span(title)) catch {};

        var shown: usize = 0;
        while (shown < visible) : (shown += 1) {
            const image = gtk.Image.newFromIconName(collected.icons[shown]);
            image.setPixelSize(icon_px);
            const image_w = image.as(gtk.Widget);
            image_w.addCssClass("session-tab-task-icon");
            image_w.setValign(.center);
            image_w.setTooltipText(collected.names[shown]);
            priv.process_row.append(image_w);
            if (tooltip_writer.buffered().len > 0)
                tooltip_writer.writeAll("\n") catch {};
            tooltip_writer.writeAll(collected.names[shown]) catch {};
        }

        if (overflow) {
            const hidden = collected.count - visible;
            var overflow_buf: [16]u8 = undefined;
            const overflow_text = std.fmt.bufPrintZ(
                &overflow_buf,
                "+{d}",
                .{hidden},
            ) catch "+";
            const label = gtk.Label.new(overflow_text);
            label.as(gtk.Widget).addCssClass("session-tab-overflow");
            label.as(gtk.Widget).setValign(.center);
            priv.process_row.append(label.as(gtk.Widget));
            if (tooltip_writer.buffered().len > 0)
                tooltip_writer.writeAll("\n") catch {};
            tooltip_writer.print("+{d} more", .{hidden}) catch {};
        }

        const tooltip = tooltip_writer.buffered();
        if (tooltip.len > 0) {
            var zbuf: [513]u8 = undefined;
            const n = @min(tooltip.len, zbuf.len - 1);
            @memcpy(zbuf[0..n], tooltip[0..n]);
            zbuf[n] = 0;
            self.as(gtk.Widget).setTooltipText(zbuf[0..n :0]);
        }
    }

    fn sessionViewOf(page: *adw.TabPage) ?*adw.TabView {
        return ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        );
    }

    fn close(self: *Self) void {
        const page = self.private().page orelse return;
        const view = sessionViewOf(page) orelse return;
        view.closePage(page);
    }

    fn clicked(
        _: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const page = self.private().page orelse return;
        const view = sessionViewOf(page) orelse return;
        view.setSelectedPage(page);
    }

    fn middleClick(
        _: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        self.close();
    }

    fn closeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.close();
    }

    fn tabDragPrepare(
        _: *gtk.DragSource,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) ?*gdk.ContentProvider {
        const page = self.private().page orelse return null;
        self.private().drag_x = x;
        self.private().drag_y = y;
        var value = gobject.ext.Value.newFrom(@as(u64, @intFromPtr(page)));
        return gdk.ContentProvider.newForValue(&value);
    }

    fn tabDragBegin(
        source: *gtk.DragSource,
        _: *gdk.Drag,
        self: *Self,
    ) callconv(.c) void {
        active_drag_page = self.private().page;
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
                    @intFromFloat(self.private().drag_x),
                    @intFromFloat(self.private().drag_y),
                );
            }
        }
        widget.addCssClass("dragging");
    }

    fn tabDragEnd(
        _: *gtk.DragSource,
        _: *gdk.Drag,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        active_drag_page = null;
        self.as(gtk.Widget).removeCssClass("dragging");
    }

    fn findPageInView(view: *adw.TabView, id: u64) ?*adw.TabPage {
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            const page = view.getNthPage(i);
            if (@intFromPtr(page) == id) return page;
        }
        return null;
    }

    fn findPageAnywhere(id: u64) ?struct { view: *adw.TabView, page: *adw.TabPage } {
        const list = gtk.Window.listToplevels();
        defer list.free();
        var node: ?*glib.List = list;
        while (node) |cur| : (node = cur.f_next) {
            const window_widget: *gtk.Window = @ptrCast(@alignCast(cur.f_data orelse continue));
            const win = gobject.ext.cast(Window, window_widget) orelse continue;
            const view = win.getSessionView();
            if (findPageInView(view, id)) |page| {
                return .{ .view = view, .page = page };
            }
        }
        return null;
    }

    fn tabDrop(
        _: *gtk.DropTarget,
        value: *const gobject.Value,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const target = self.private().page orelse return;
        const dest = sessionViewOf(target) orelse return;
        const dragged_id = value.getUint64();
        if (findPageInView(dest, dragged_id)) |dragged| {
            if (dragged == target) return;
            _ = dest.reorderPage(dragged, dest.getPagePosition(target));
            return;
        }

        const found = findPageAnywhere(dragged_id) orelse return;
        found.view.transferPage(found.page, dest, dest.getPagePosition(target));
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.process_idle) |idle| {
            _ = glib.Source.remove(idle);
            priv.process_idle = null;
        }
        if (priv.process_timer) |timer| {
            _ = glib.Source.remove(timer);
            priv.process_timer = null;
        }
        if (priv.selected_page) |old| {
            if (priv.selected_handler != 0) {
                gobject.signalHandlerDisconnect(
                    old.as(gobject.Object),
                    priv.selected_handler,
                );
            }
            priv.selected_handler = 0;
            priv.selected_page = null;
        }
        self.disconnectTitleView();
        if (priv.page) |page| {
            page.unref();
            priv.page = null;
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
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "session-tab",
                }),
            );

            class.bindTemplateCallback("notify_page", &propPage);
            class.bindTemplateCallback("clicked", &clicked);
            class.bindTemplateCallback("middle_click", &middleClick);
            class.bindTemplateCallback("close", &closeClicked);
            class.bindTemplateCallback("tab_drag_prepare", &tabDragPrepare);
            class.bindTemplateCallback("tab_drag_begin", &tabDragBegin);
            class.bindTemplateCallback("tab_drag_end", &tabDragEnd);
            class.bindTemplateCallback("tab_drop", &tabDrop);

            class.bindTemplateChildPrivate("process_row", .{});
            class.bindTemplateChildPrivate("tab_drop_target", .{});

            gobject.ext.registerProperties(class, &.{
                properties.page.impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
