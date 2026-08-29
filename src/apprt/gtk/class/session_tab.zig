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
const Color = @import("tab_group.zig").Color;
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
        content_box: *gtk.Box,
        process_row: *gtk.Box,
        session_title: *gtk.Label,
        empty_indicator: *gtk.Box,
        close_button: *gtk.Button,
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
        color_session: ?*Session = null,
        color_handler: c_ulong = 0,
        side: bool = false,
        last_width: c_int = -1,
        last_height: c_int = -1,
        last_fingerprint: [512]u8 = undefined,
        last_fingerprint_len: usize = 0,
        drag_cancelled: bool = false,
        drag_drop_performed: bool = false,
        drag_torn_out: bool = false,

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
        self.syncColorConnection();
        self.scheduleProcessIdle();
        self.private().process_timer = glib.timeoutAdd(
            1_000,
            processTimer,
            self,
        );
    }

    pub fn setSide(self: *Self, side: bool) void {
        const priv = self.private();
        if (priv.side != side) {
            priv.side = side;
            const widget = self.as(gtk.Widget);
            if (side)
                widget.addCssClass("side")
            else
                widget.removeCssClass("side");
            priv.content_box.as(gtk.Orientable).setOrientation(
                if (side) .vertical else .horizontal,
            );
        }
        priv.close_button.as(gtk.Widget).setVisible(@intFromBool(!side));
        priv.last_fingerprint_len = 0;
        self.syncLabel();
        self.updateProcessRow();
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
        self.syncColorConnection();
        self.scheduleProcessIdle();
    }

    fn disconnectColorSession(self: *Self) void {
        const priv = self.private();
        if (priv.color_session) |session| {
            if (priv.color_handler != 0) {
                gobject.signalHandlerDisconnect(
                    session.as(gobject.Object),
                    priv.color_handler,
                );
            }
        }
        priv.color_session = null;
        priv.color_handler = 0;
    }

    fn syncColorConnection(self: *Self) void {
        const session = if (self.private().page) |page|
            gobject.ext.cast(Session, page.getChild())
        else
            null;
        if (self.private().color_session != session) {
            self.disconnectColorSession();
            if (session) |value| {
                self.private().color_session = value;
                self.private().color_handler = gobject.Object.signals.notify.connect(
                    value,
                    *Self,
                    sessionColorChanged,
                    self,
                    .{ .detail = "color" },
                );
            }
        }
        self.syncColor();
    }

    fn sessionColorChanged(
        _: *Session,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncColor();
    }

    fn syncColor(self: *Self) void {
        const widget = self.as(gtk.Widget);
        for (std.enums.values(Color)) |color| {
            widget.removeCssClass(color.cssClass());
        }
        if (self.private().color_session) |session| {
            widget.addCssClass(session.getColor().cssClass());
        }
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
        if (gobject.ext.cast(Session, outer_page.getChild())) |session| {
            if (session.getSnapshotName()) |snapshot_name| {
                outer_page.setTitle(snapshot_name);
                outer_page.setTooltip(snapshot_name);
                self.syncLabel();
                priv.last_fingerprint_len = 0;
                self.updateProcessRow();
                return;
            }
        }
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
        self.syncLabel();
        if (std.mem.eql(
            u8,
            std.mem.span(outer_page.getTitle()),
            std.mem.span(title),
        )) return;
        outer_page.setTitle(title);
        priv.last_fingerprint_len = 0;
        self.updateProcessRow();
    }

    fn syncLabel(self: *Self) void {
        const priv = self.private();
        const outer_page = priv.page orelse return;
        const label = priv.session_title;
        switch (self.sessionLabel()) {
            .none => label.as(gtk.Widget).setVisible(0),
            .number => {
                var buf: [32]u8 = undefined;
                const text: [*:0]const u8 = if (sessionViewOf(outer_page)) |view| text: {
                    const value = std.fmt.bufPrintZ(
                        &buf,
                        "{d}",
                        .{view.getPagePosition(outer_page) + 1},
                    ) catch break :text outer_page.getTitle();
                    break :text value.ptr;
                } else outer_page.getTitle();
                label.setLabel(text);
                label.as(gtk.Widget).setVisible(1);
            },
            .title => {
                label.setLabel(outer_page.getTooltip() orelse outer_page.getTitle());
                label.as(gtk.Widget).setVisible(1);
            },
        }
        self.syncEmptyIndicator();
    }

    fn syncEmptyIndicator(self: *Self) void {
        const priv = self.private();
        const label_hidden = priv.session_title.as(gtk.Widget).getVisible() == 0;
        const processes_hidden = priv.process_row.as(gtk.Widget).getVisible() == 0;
        priv.empty_indicator.as(gtk.Widget).setVisible(
            @intFromBool(label_hidden and processes_hidden),
        );
    }

    fn sessionLabel(self: *Self) configpkg.Config.GtkSessionLabel {
        const window = ext.getAncestor(Window, self.as(gtk.Widget)) orelse
            return if (self.private().side) .none else .number;
        const config = window.getConfig() orelse
            return if (self.private().side) .none else .number;
        const core = config.get();
        return if (self.private().side)
            core.@"gtk-session-sidebar-label"
        else
            core.@"gtk-session-label";
    }

    fn iconConfig(self: *Self) struct {
        tui: bool = true,
        shell: bool = true,
        grid: bool = false,
        grid_width: usize = 2,
        grid_height: usize = 2,
    } {
        const window = ext.getAncestor(Window, self.as(gtk.Widget)) orelse
            return .{};
        const config = window.getConfig() orelse return .{};
        const core = config.get();
        return .{
            .tui = core.@"gtk-session-tui-icons",
            .shell = core.@"gtk-session-shell-icons",
            .grid = self.private().side and
                core.@"gtk-session-sidebar-icon-layout" == .grid,
            .grid_width = core.@"gtk-session-sidebar-icon-grid-width",
            .grid_height = core.@"gtk-session-sidebar-icon-grid-height",
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

    const ProcessLayout = struct {
        visible: usize,
        hidden: usize,
    };

    fn processLayout(
        count: usize,
        row_capacity: usize,
        grid: bool,
        grid_width: usize,
        grid_height: usize,
    ) ProcessLayout {
        const capacity: usize = if (grid)
            @max(grid_width, 1) * @max(grid_height, 1)
        else
            @max(row_capacity, 1);
        const overflow = count > capacity;
        const visible = if (grid and overflow)
            capacity - 1
        else if (overflow and capacity > 1)
            capacity - 1
        else
            @min(count, capacity);
        return .{
            .visible = visible,
            .hidden = count - visible,
        };
    }

    fn fingerprint(
        collected: Collected,
        width: c_int,
        height: c_int,
        grid: bool,
        grid_width: usize,
        grid_height: usize,
        buf: []u8,
    ) []const u8 {
        var writer: std.Io.Writer = .fixed(buf);
        writer.print("{d}x{d}:{d}:{d}:{d}x{d}", .{
            width,
            height,
            collected.count,
            @intFromBool(grid),
            grid_width,
            grid_height,
        }) catch
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

    fn appendProcessCell(
        container: *gtk.Box,
        grid_column: *?*gtk.Box,
        child: *gtk.Widget,
        grid: bool,
        grid_height: usize,
        index: usize,
    ) void {
        if (!grid) {
            container.append(child);
            return;
        }
        if (index % @max(grid_height, 1) == 0) {
            const column = gtk.Box.new(.vertical, icon_gap);
            column.as(gtk.Widget).setHalign(.center);
            column.as(gtk.Widget).setValign(.center);
            container.append(column.as(gtk.Widget));
            grid_column.* = column;
        }
        (grid_column.* orelse return).append(child);
    }

    fn updateProcessRow(self: *Self) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);
        const width = widget.getWidth();
        const height = widget.getHeight();
        const collected = self.collectProcesses();
        const icon_config = self.iconConfig();
        const grid = icon_config.grid;
        const grid_width = icon_config.grid_width;
        const grid_height = icon_config.grid_height;

        var fp_buf: [512]u8 = undefined;
        const fp = fingerprint(
            collected,
            width,
            height,
            grid,
            grid_width,
            grid_height,
            &fp_buf,
        );
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

        if (priv.page) |page| {
            if (page.getSelected() != 0) {
                if (ext.getAncestor(Window, self.as(gtk.Widget))) |window| {
                    window.syncExtendFullChrome();
                }
            }
        }

        clearRow(priv.process_row);
        priv.process_row.as(gtk.Orientable).setOrientation(
            if (grid) .horizontal else if (priv.side) .vertical else .horizontal,
        );
        priv.process_row.setSpacing(icon_gap);
        if (grid)
            priv.process_row.as(gtk.Widget).addCssClass("grid")
        else
            priv.process_row.as(gtk.Widget).removeCssClass("grid");

        const title = if (priv.page) |page| page.getTitle() else "";

        if (collected.count == 0) {
            priv.process_row.as(gtk.Widget).setVisible(0);
            self.syncEmptyIndicator();
            self.as(gtk.Widget).setTooltipText(title);
            return;
        }

        priv.process_row.as(gtk.Widget).setVisible(1);
        self.syncEmptyIndicator();
        const row_capacity = if (priv.side)
            collected.count
        else capacity: {
            const row_w = if (width > 0) width else widget.getAllocatedWidth();
            break :capacity capacityForWidth(
                if (row_w > 18) row_w - 18 else row_w,
            );
        };
        const layout = processLayout(
            collected.count,
            row_capacity,
            grid,
            grid_width,
            grid_height,
        );

        var tooltip_buf: [512]u8 = undefined;
        var tooltip_writer: std.Io.Writer = .fixed(&tooltip_buf);
        if (std.mem.span(title).len > 0) tooltip_writer.writeAll(std.mem.span(title)) catch {};

        var grid_column: ?*gtk.Box = null;
        var shown: usize = 0;
        while (shown < layout.visible) : (shown += 1) {
            const image = gtk.Image.newFromIconName(collected.icons[shown]);
            image.setPixelSize(icon_px);
            const image_w = image.as(gtk.Widget);
            image_w.addCssClass("session-tab-task-icon");
            image_w.setValign(.center);
            image_w.setTooltipText(collected.names[shown]);
            appendProcessCell(
                priv.process_row,
                &grid_column,
                image_w,
                grid,
                grid_height,
                shown,
            );
            if (tooltip_writer.buffered().len > 0)
                tooltip_writer.writeAll("\n") catch {};
            tooltip_writer.writeAll(collected.names[shown]) catch {};
        }

        if (layout.hidden > 0) {
            var overflow_buf: [16]u8 = undefined;
            const overflow_text = std.fmt.bufPrintZ(
                &overflow_buf,
                "+{d}",
                .{layout.hidden},
            ) catch "+";
            const label = gtk.Label.new(overflow_text);
            label.as(gtk.Widget).addCssClass("session-tab-overflow");
            label.as(gtk.Widget).setValign(.center);
            appendProcessCell(
                priv.process_row,
                &grid_column,
                label.as(gtk.Widget),
                grid,
                grid_height,
                shown,
            );
            if (tooltip_writer.buffered().len > 0)
                tooltip_writer.writeAll("\n") catch {};
            tooltip_writer.print("+{d} more", .{layout.hidden}) catch {};
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

    fn contextMenu(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        _ = gesture.as(gtk.Gesture).setState(.claimed);
        const session = self.private().color_session orelse return;

        const box = gtk.Box.new(.vertical, 2);
        const label = gtk.Label.new(i18n._("Session Color"));
        label.as(gtk.Widget).setHalign(.start);
        label.as(gtk.Widget).setMarginStart(6);
        label.as(gtk.Widget).setMarginEnd(6);
        label.as(gtk.Widget).setMarginTop(4);
        box.append(label.as(gtk.Widget));

        const colors = gtk.Box.new(.horizontal, 4);
        colors.as(gtk.Widget).setHalign(.start);
        colors.as(gtk.Widget).setMarginStart(6);
        colors.as(gtk.Widget).setMarginEnd(6);
        colors.as(gtk.Widget).setMarginTop(4);
        colors.as(gtk.Widget).setMarginBottom(4);
        for (std.enums.values(Color)) |color| {
            const button = gtk.Button.new();
            button.as(gtk.Widget).addCssClass("flat");
            button.as(gtk.Widget).addCssClass("tab-group-color-choice");
            button.as(gtk.Widget).addCssClass(color.cssClass());
            button.as(gtk.Widget).setTooltipText(color.label());
            button.as(gobject.Object).setData(
                "holoctty-session-color",
                @ptrFromInt(@as(usize, @intCast(@intFromEnum(color))) + 1),
            );
            _ = gtk.Button.signals.clicked.connect(
                button,
                *Session,
                setSessionColor,
                session,
                .{},
            );
            colors.append(button.as(gtk.Widget));
        }
        box.append(colors.as(gtk.Widget));

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

    fn setSessionColor(
        button: *gtk.Button,
        session: *Session,
    ) callconv(.c) void {
        const ptr = button.as(gobject.Object).getData(
            "holoctty-session-color",
        ) orelse return;
        const index: i32 = @intCast(@intFromPtr(ptr) - 1);
        const color = Color.fromIndex(index) orelse return;
        session.setColor(color);
        if (ext.getAncestor(gtk.Popover, button.as(gtk.Widget))) |popover| {
            popover.popdown();
        }
    }

    fn popoverClosed(popover: *gtk.Popover, _: *gtk.Popover) callconv(.c) void {
        popover.as(gtk.Widget).unparent();
        popover.as(gobject.Object).unref();
    }

    fn close(self: *Self) void {
        const page = self.private().page orelse return;
        const view = sessionViewOf(page) orelse return;
        view.closePage(page);
    }

    fn clicked(
        _: *gtk.GestureClick,
        press_count: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const page = self.private().page orelse return;
        const view = sessionViewOf(page) orelse return;
        view.setSelectedPage(page);

        if (press_count == 2) {
            const session = gobject.ext.cast(Session, page.getChild()) orelse return;
            const tab_page = session.getPagesTabView().getSelectedPage() orelse return;
            const tab = gobject.ext.cast(Tab, tab_page.getChild()) orelse return;
            const surface = tab.getActiveSurface() orelse return;
            const core = surface.core() orelse return;
            _ = core.performBindingAction(.scroll_to_bottom) catch |err| {
                std.log.warn("unable to scroll session to bottom err={}", .{err});
            };
        }
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
        drag: *gdk.Drag,
        self: *Self,
    ) callconv(.c) void {
        active_drag_page = self.private().page;
        const priv = self.private();
        priv.drag_cancelled = false;
        priv.drag_drop_performed = false;
        priv.drag_torn_out = false;

        // Track whether the user physically released the drop button. On
        // Wayland a drop onto a non-accepting surface is reported as a cancel
        // with reason error, but only after wl_data_source.dnd_drop_performed.
        // A plain cancel (Escape) never emits drop-performed, so this is the
        // only reliable way to tell "dropped outside" from "cancelled".
        _ = gdk.Drag.signals.drop_performed.connect(
            drag,
            *Self,
            tabDragDropPerformed,
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

    fn tabDragDropPerformed(
        _: *gdk.Drag,
        self: *Self,
    ) callconv(.c) void {
        self.private().drag_drop_performed = true;
    }

    fn tabDragEnd(
        _: *gtk.DragSource,
        _: *gdk.Drag,
        delete_data: c_int,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // The drag finished without the page being consumed by a drop target
        // and without being torn out already: the user dropped it outside
        // every window (e.g. on the desktop). Tear it out into a new window.
        if (delete_data == 0 and !priv.drag_cancelled and !priv.drag_torn_out) {
            priv.drag_torn_out = true;
            if (priv.page) |page| _ = Window.moveSessionPageToNewWindow(@intFromPtr(page));
        }

        active_drag_page = null;
        priv.drag_cancelled = false;
        priv.drag_drop_performed = false;
        priv.drag_torn_out = false;
        self.as(gtk.Widget).removeCssClass("dragging");
    }

    fn tabDragCancel(
        _: *gtk.DragSource,
        _: *gdk.Drag,
        reason: gdk.DragCancelReason,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        priv.drag_cancelled = true;

        // The drop was physically performed but every target refused it: the
        // user dropped the session outside all windows. This covers both X11
        // (reason no_target) and Wayland (cancel following drop-performed).
        const dropped_outside = reason == .no_target or
            (reason == .@"error" and priv.drag_drop_performed);
        if (dropped_outside and !priv.drag_torn_out) {
            priv.drag_torn_out = true;
            if (priv.page) |page| {
                if (Window.moveSessionPageToNewWindow(@intFromPtr(page)))
                    return @intFromBool(true);
            }
        }
        return @intFromBool(false);
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
    ) callconv(.c) c_int {
        const target = self.private().page orelse return @intFromBool(false);
        const dest = sessionViewOf(target) orelse return @intFromBool(false);
        const dragged_id = value.getUint64();
        if (findPageInView(dest, dragged_id)) |dragged| {
            if (dragged != target)
                _ = dest.reorderPage(dragged, dest.getPagePosition(target));
            return @intFromBool(true);
        }

        const found = findPageAnywhere(dragged_id) orelse
            return @intFromBool(false);
        found.view.transferPage(found.page, dest, dest.getPagePosition(target));
        return @intFromBool(true);
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
        self.disconnectColorSession();
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
            class.bindTemplateCallback("context_menu", &contextMenu);
            class.bindTemplateCallback("close", &closeClicked);
            class.bindTemplateCallback("tab_drag_prepare", &tabDragPrepare);
            class.bindTemplateCallback("tab_drag_begin", &tabDragBegin);
            class.bindTemplateCallback("tab_drag_end", &tabDragEnd);
            class.bindTemplateCallback("tab_drag_cancel", &tabDragCancel);
            class.bindTemplateCallback("tab_drop", &tabDrop);

            class.bindTemplateChildPrivate("content_box", .{});
            class.bindTemplateChildPrivate("process_row", .{});
            class.bindTemplateChildPrivate("session_title", .{});
            class.bindTemplateChildPrivate("empty_indicator", .{});
            class.bindTemplateChildPrivate("close_button", .{});
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

test "session process grid reserves its fourth cell for overflow" {
    const testing = std.testing;
    try testing.expectEqual(
        SessionTab.ProcessLayout{ .visible = 4, .hidden = 0 },
        SessionTab.processLayout(4, 1, true, 2, 2),
    );
    try testing.expectEqual(
        SessionTab.ProcessLayout{ .visible = 3, .hidden = 2 },
        SessionTab.processLayout(5, 20, true, 2, 2),
    );
    try testing.expectEqual(
        SessionTab.ProcessLayout{ .visible = 3, .hidden = 2 },
        SessionTab.processLayout(5, 4, false, 8, 8),
    );
    try testing.expectEqual(
        SessionTab.ProcessLayout{ .visible = 8, .hidden = 2 },
        SessionTab.processLayout(10, 1, true, 3, 3),
    );
    try testing.expectEqual(
        SessionTab.ProcessLayout{ .visible = 0, .hidden = 3 },
        SessionTab.processLayout(3, 1, true, 1, 1),
    );
    try testing.expectEqual(
        SessionTab.ProcessLayout{ .visible = 7, .hidden = 2 },
        SessionTab.processLayout(9, 1, true, 2, 4),
    );
}
