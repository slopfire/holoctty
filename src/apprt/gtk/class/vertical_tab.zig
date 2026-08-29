const std = @import("std");
const builtin = @import("builtin");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const cli_process = @import("../cli_process.zig");
const folder_icon_picker = @import("../folder_icon_picker.zig");
const folder_icons = @import("../folder_icons.zig");
const git_status = @import("../git_status.zig");
const Common = @import("../class.zig").Common;
const global = @import("../../../global.zig");
const i18n = @import("../../../os/main.zig").i18n;
const Tab = @import("tab.zig").Tab;
const TabGroup = @import("tab_group.zig").TabGroup;
const Color = @import("tab_group.zig").Color;
const Window = @import("window.zig").Window;

/// A single row in the vertical tab sidebar.
pub const VerticalTab = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    var active_drag_page: ?*adw.TabPage = null;

    pub fn activeDragPage() ?*adw.TabPage {
        return active_drag_page;
    }

    pub fn getPage(self: *Self) ?*adw.TabPage {
        return self.private().page;
    }

    pub fn new(page: *adw.TabPage) *Self {
        return gobject.ext.newInstance(Self, .{ .page = page });
    }
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "HolocttyVerticalTab",
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

        pub const @"process-icon" = struct {
            pub const name = "process-icon";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("process_icon"),
                },
            );
        };

        pub const @"process-name" = struct {
            pub const name = "process-name";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("process_name"),
                },
            );
        };

        pub const @"location-icon" = struct {
            pub const name = "location-icon";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{ .default = null, .accessor = C.privateStringFieldAccessor("location_icon") },
            );
        };

        pub const @"location-name" = struct {
            pub const name = "location-name";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{ .default = null, .accessor = C.privateStringFieldAccessor("location_name") },
            );
        };

        pub const @"remote-host" = struct {
            pub const name = "remote-host";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{ .default = null, .accessor = C.privateStringFieldAccessor("remote_host") },
            );
        };

        pub const @"git-status" = struct {
            pub const name = "git-status";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{ .default = null, .accessor = C.privateStringFieldAccessor("git_status") },
            );
        };
    };

    const Private = struct {
        page: ?*adw.TabPage = null,
        tab_drop_target: *gtk.DropTarget,
        drag_x: f64 = 0,
        drag_y: f64 = 0,
        process_icon: ?[:0]const u8 = null,
        process_name: ?[:0]const u8 = null,
        location_icon: ?[:0]const u8 = null,
        location_name: ?[:0]const u8 = null,
        remote_host: ?[:0]const u8 = null,
        git_status: ?[:0]const u8 = null,
        process_icon_timer: ?c_uint = null,
        drag_cancelled: bool = false,
        drag_drop_performed: bool = false,
        drag_torn_out: bool = false,
        selected_page: ?*adw.TabPage = null,
        selected_handler: c_ulong = 0,
        title_handler: c_ulong = 0,
        meta_revealer: *gtk.Revealer,
        footer_revealer: *gtk.Revealer,
        git_status_box: *gtk.Box,
        git_dirty: *gtk.Label,
        git_staged: *gtk.Label,
        git_ahead: *gtk.Label,
        git_behind: *gtk.Label,
        title_label: *gtk.Label,
        location_theme_icon: *gtk.Image,
        location_file_icon: *gtk.Picture,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        var drop_types = [_]gobject.Type{gobject.ext.types.uint64};
        self.private().tab_drop_target.setGtypes(&drop_types, drop_types.len);
        self.setProcessIcon("utilities-terminal-symbolic");
        self.setLocation(.{});
        self.connectSelected();
        self.syncSelected();
        self.syncGroupStyle();
        self.applyTitleLines();
        self.private().process_icon_timer = glib.timeoutAdd(
            1_000,
            processIconTimer,
            self,
        );
    }

    fn setLocation(self: *Self, state: cli_process.ProcessState) void {
        const remote = state.remote;
        const pwd = self.locationPwd();
        const custom = if (remote)
            if (state.remoteHost()) |host| folder_icons.resolveRemote(host) else null
        else
            folder_icons.resolve(pwd);
        const git = !remote and pathInGitRepo(pwd);
        const default_icon: []const u8 = if (remote)
            "holoctty-cli-remote-server-symbolic"
        else if (git)
            "holoctty-cli-folder-git-symbolic"
        else
            "folder-symbolic";
        const icon = if (custom) |value| switch (value) {
            .color, .uri => "folder-symbolic",
            .tinted => |tinted| tinted.glyph.iconName(),
            .theme => |theme| theme,
        } else default_icon;
        const name: []const u8 = if (remote)
            "Remote Session"
        else if (git)
            "Git Repository"
        else
            "Local Folder";
        self.setLocationProperties(icon, name);
        self.syncLocationIcon(custom);
    }

    fn setLocationProperties(self: *Self, icon: []const u8, name: []const u8) void {
        const priv = self.private();
        if (priv.location_icon) |current| {
            if (!std.mem.eql(u8, current, icon)) {
                glib.free(@ptrCast(@constCast(current)));
                priv.location_icon = glib.ext.dupeZ(u8, icon);
                self.as(gobject.Object).notifyByPspec(
                    properties.@"location-icon".impl.param_spec,
                );
            }
        } else {
            priv.location_icon = glib.ext.dupeZ(u8, icon);
            self.as(gobject.Object).notifyByPspec(
                properties.@"location-icon".impl.param_spec,
            );
        }
        if (priv.location_name) |current| {
            if (!std.mem.eql(u8, current, name)) {
                glib.free(@ptrCast(@constCast(current)));
                priv.location_name = glib.ext.dupeZ(u8, name);
                self.as(gobject.Object).notifyByPspec(
                    properties.@"location-name".impl.param_spec,
                );
            }
        } else {
            priv.location_name = glib.ext.dupeZ(u8, name);
            self.as(gobject.Object).notifyByPspec(
                properties.@"location-name".impl.param_spec,
            );
        }
    }

    fn syncLocationIcon(self: *Self, custom: ?folder_icons.Icon) void {
        const priv = self.private();
        const theme_widget = priv.location_theme_icon.as(gtk.Widget);
        theme_widget.removeCssClass("custom-folder-icon");
        for (std.enums.values(folder_icons.Color)) |color| {
            theme_widget.removeCssClass(color.cssClass());
        }
        priv.location_file_icon.setFile(null);
        priv.location_file_icon.as(gtk.Widget).setVisible(0);
        theme_widget.setVisible(1);

        if (custom) |icon| switch (icon) {
            .color => |color| {
                theme_widget.addCssClass("custom-folder-icon");
                theme_widget.addCssClass(color.cssClass());
            },
            .tinted => |tinted| {
                theme_widget.addCssClass("custom-folder-icon");
                theme_widget.addCssClass(tinted.color.cssClass());
            },
            .theme => {},
            .uri => |uri| {
                const uri_z = glib.ext.dupeZ(u8, uri);
                defer glib.free(uri_z.ptr);
                const file = gio.File.newForUri(uri_z);
                defer file.unref();
                priv.location_file_icon.setFile(file);
                priv.location_file_icon.as(gtk.Widget).setVisible(1);
                theme_widget.setVisible(0);
            },
        };
    }

    /// Working directory used for the location icon (surface pwd when available).
    fn locationPwd(self: *Self) []const u8 {
        const page = self.private().page orelse return "";
        if (gobject.ext.cast(Tab, page.getChild())) |tab| {
            if (tab.getActiveSurface()) |surface| {
                if (surface.getPwd()) |pwd| return pwd;
            }
        }
        if (page.getTooltip()) |tooltip| return std.mem.span(tooltip);
        return "";
    }

    /// True if `pwd` or any ancestor directory contains a `.git` entry
    /// (regular repo directory or worktree gitfile).
    fn pathInGitRepo(pwd: []const u8) bool {
        var dir = std.mem.trimEnd(u8, pwd, "/");
        while (dir.len > 0) {
            var git_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const git_path = std.fmt.bufPrint(
                &git_path_buf,
                "{s}/.git",
                .{dir},
            ) catch break;
            if (std.Io.Dir.accessAbsolute(global.io(), git_path, .{})) {
                return true;
            } else |_| {}

            const parent = std.fs.path.dirname(dir) orelse break;
            if (std.mem.eql(u8, parent, dir)) break;
            dir = parent;
        }
        return false;
    }

    fn setProcessIcon(self: *Self, icon: [:0]const u8) void {
        const priv = self.private();
        if (priv.process_icon) |current| {
            if (std.mem.eql(u8, current, icon)) return;
            glib.free(@ptrCast(@constCast(current)));
        }

        priv.process_icon = glib.ext.dupeZ(u8, icon);
        if (priv.process_name) |name| glib.free(@ptrCast(@constCast(name)));
        priv.process_name = glib.ext.dupeZ(u8, cli_process.processName(icon));
        self.as(gobject.Object).notifyByPspec(
            properties.@"process-icon".impl.param_spec,
        );
        self.as(gobject.Object).notifyByPspec(
            properties.@"process-name".impl.param_spec,
        );

        // Starting or leaving an ignored TUI can keep the same sampled
        // fill, so chrome must re-evaluate from the new process.
        if (priv.page) |page| {
            if (page.getSelected() != 0) {
                if (ext.getAncestor(Window, self.as(gtk.Widget))) |window| {
                    window.syncExtendFullChrome();
                }
            }
        }
    }

    fn processIconTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse
            return @intFromBool(glib.SOURCE_REMOVE)));
        self.updateProcessIcon();
        return @intFromBool(glib.SOURCE_CONTINUE);
    }

    fn propPage(
        _: *Self,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.connectSelected();
        self.updateProcessIcon();
        self.syncSelected();
        self.syncGroupStyle();
        self.applyTitleLines();
    }

    fn connectSelected(self: *Self) void {
        const priv = self.private();
        if (priv.selected_page) |page| {
            if (priv.selected_handler != 0) {
                gobject.signalHandlerDisconnect(
                    page.as(gobject.Object),
                    priv.selected_handler,
                );
            }
            if (priv.title_handler != 0) {
                gobject.signalHandlerDisconnect(
                    page.as(gobject.Object),
                    priv.title_handler,
                );
            }
            priv.selected_handler = 0;
            priv.title_handler = 0;
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
            priv.title_handler = gobject.Object.signals.notify.connect(
                page,
                *Self,
                pageTitleChanged,
                self,
                .{ .detail = "title" },
            );
            priv.selected_page = page;
        }
    }

    fn pageSelected(
        _: *adw.TabPage,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncSelected();
    }

    fn pageTitleChanged(
        _: *adw.TabPage,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.applyTitleLines();
    }

    pub fn syncSelected(self: *Self) void {
        const selected = if (self.private().page) |page|
            page.getSelected() != 0
        else
            false;
        if (selected) {
            self.as(gtk.Widget).addCssClass("selected");
        } else {
            self.as(gtk.Widget).removeCssClass("selected");
        }
    }

    pub fn syncGroupStyle(self: *Self) void {
        const widget = self.as(gtk.Widget);
        for (std.enums.values(Color)) |color| {
            widget.removeCssClass(color.cssClass());
        }
        if (self.private().page) |page| {
            if (TabGroup.forPage(page)) |group| {
                widget.addCssClass("grouped");
                widget.addCssClass(group.getColor().cssClass());
                return;
            }
        }
        widget.removeCssClass("grouped");
    }

    pub fn setCompact(self: *Self, compact: bool) void {
        const widget = self.as(gtk.Widget);
        const priv = self.private();
        if (compact) {
            widget.addCssClass("compact");
        } else {
            widget.removeCssClass("compact");
        }
        priv.meta_revealer.setRevealChild(@intFromBool(!compact));
        priv.footer_revealer.setRevealChild(@intFromBool(!compact));
    }

    /// Wrap the middle title to the configured line count.
    /// Paths stay on one line with a middle ellipsis.
    pub fn applyTitleLines(self: *Self) void {
        const lines: c_int = self.titleLines();
        const label = self.private().title_label;
        const path = titleIsPath(self.pageTitle());
        if (lines <= 1 or path) {
            label.setWrap(0);
            label.setSingleLineMode(1);
            label.setLines(1);
            label.setEllipsize(if (path) .middle else .end);
            return;
        }
        label.setSingleLineMode(0);
        label.setWrap(1);
        label.setWrapMode(.word);
        label.setLines(lines);
        label.setEllipsize(.end);
    }

    fn titleLines(self: *Self) u8 {
        const window = ext.getAncestor(Window, self.as(gtk.Widget)) orelse
            return 2;
        const config = window.getConfig() orelse return 2;
        return config.get().@"gtk-vertical-tab-title-lines";
    }

    fn pageTitle(self: *Self) []const u8 {
        const page = self.private().page orelse return "";
        return std.mem.span(page.getTitle());
    }

    /// True when the whole title is a path and should not wrap.
    fn titleIsPath(title: []const u8) bool {
        if (title.len == 0) return false;
        if (std.mem.indexOfAny(u8, title, " \t") != null) return false;
        if (title[0] == '/' or title[0] == '~') return true;
        if (title[0] == '.' and title.len > 1) return true;
        return std.mem.indexOfAny(u8, title, "/\\") != null;
    }

    /// Keep path components on one line by forbidding breaks after `/` and `\`.
    fn gluePathBreaks(title: []const u8, buf: []u8) []const u8 {
        const joiner = "\u{2060}";
        var i: usize = 0;
        for (title) |c| {
            if (i >= buf.len) return title;
            buf[i] = c;
            i += 1;
            if (c != '/' and c != '\\') continue;
            if (i + joiner.len > buf.len) return title;
            @memcpy(buf[i..][0..joiner.len], joiner);
            i += joiner.len;
        }
        return buf[0..i];
    }

    fn selectTab(
        _: *gtk.GestureClick,
        press_count: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const page = self.private().page orelse return;
        const view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse return;
        view.setSelectedPage(page);

        if (press_count == 2) {
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
            const surface = tab.getActiveSurface() orelse return;
            const core = surface.core() orelse return;
            _ = core.performBindingAction(.scroll_to_bottom) catch |err| {
                std.log.warn("unable to scroll tab to bottom err={}", .{err});
            };
        }
    }

    fn contextMenu(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        _ = gesture.as(gtk.Gesture).setState(.claimed);
        self.popupContextMenu();
    }

    fn popupContextMenu(self: *Self) void {
        const page = self.private().page orelse return;
        const view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse return;
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
            win.setContextTabPage(page);
            win.setTabGroupContext(TabGroup.forPage(page));
        }

        const box = gtk.Box.new(.vertical, 0);
        self.appendMenuButton(box, i18n._("Change Tab Title…"), menuPromptTitle);
        const process_state = self.detectProcessState();
        if (process_state.remote) {
            if (process_state.remoteHost() != null) {
                self.appendMenuButton(box, i18n._("Set Remote Icon…"), menuLocationIcon);
            }
        } else if (self.folderIconPath() != null) {
            self.appendMenuButton(box, i18n._("Set Folder Icon…"), menuLocationIcon);
        }
        self.appendMenuButton(box, i18n._("Add Tab to New Group"), menuAddNewGroup);

        var groups: [16]*TabGroup = undefined;
        const existing = TabGroup.collectInView(view, &groups);
        for (existing) |group| {
            if (TabGroup.forPage(page) == group) continue;
            self.appendAddToGroupButton(box, group);
        }
        if (TabGroup.forPage(page) != null) {
            self.appendMenuButton(box, i18n._("Remove From Group"), menuRemoveGroup);
        }

        const popover = gtk.Popover.new();
        popover.setHasArrow(0);
        popover.setChild(box.as(gtk.Widget));
        popover.as(gtk.Widget).setParent(self.as(gtk.Widget));
        _ = gtk.Popover.signals.closed.connect(
            popover,
            *gtk.Popover,
            tabMenuClosed,
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
        button.as(gtk.Widget).addCssClass("tab-group-menu-item");
        _ = gtk.Button.signals.clicked.connect(button, *Self, callback, self, .{});
        box.append(button.as(gtk.Widget));
    }

    fn appendAddToGroupButton(self: *Self, box: *gtk.Box, group: *TabGroup) void {
        var name_buf: [128]u8 = undefined;
        var text_buf: [160]u8 = undefined;
        const text = std.fmt.bufPrintZ(
            &text_buf,
            "{s}{s}",
            .{ i18n._("Add to "), group.displayLabel(&name_buf) },
        ) catch return;
        const button = gtk.Button.newWithLabel(text);
        button.as(gtk.Widget).setHalign(.fill);
        button.as(gtk.Widget).addCssClass("flat");
        button.as(gtk.Widget).addCssClass("tab-group-menu-item");
        _ = group.ref();
        button.as(gobject.Object).setDataFull("holoctty-tab-group", group, menuGroupDestroy);
        _ = gtk.Button.signals.clicked.connect(
            button,
            *Self,
            menuAddExistingGroup,
            self,
            .{},
        );
        box.append(button.as(gtk.Widget));
    }

    fn menuGroupDestroy(data: ?*anyopaque) callconv(.c) void {
        const group: *TabGroup = @ptrCast(@alignCast(data orelse return));
        group.unref();
    }

    fn closeMenu(button: *gtk.Button) void {
        if (ext.getAncestor(gtk.Popover, button.as(gtk.Widget))) |popover| {
            popover.popdown();
        }
    }

    fn menuPromptTitle(
        button: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        closeMenu(button);
        const page = self.private().page orelse return;
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
        tab.promptTabTitle();
    }

    fn folderIconPath(self: *Self) ?[]const u8 {
        const pwd = self.locationPwd();
        if (pwd.len == 0 or !std.fs.path.isAbsolute(pwd)) return null;
        return pwd;
    }

    fn menuLocationIcon(
        button: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        closeMenu(button);
        const state = self.detectProcessState();
        if (state.remote) {
            const host = state.remoteHost() orelse return;
            folder_icon_picker.presentRemote(
                self.as(gtk.Widget),
                host,
                locationIconChanged,
                self,
            );
            return;
        }
        const path = self.folderIconPath() orelse return;
        folder_icon_picker.present(
            self.as(gtk.Widget),
            path,
            locationIconChanged,
            self,
        );
    }

    fn locationIconChanged(userdata: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return));
        self.setLocation(self.detectProcessState());
    }

    fn menuAddNewGroup(
        button: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        closeMenu(button);
        const page = self.private().page orelse return;
        const group = TabGroup.new();
        defer group.unref();
        TabGroup.bindPage(page, group);
        self.syncGroupStyle();
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
            win.syncTabGroups();
        }
    }

    fn menuAddExistingGroup(
        button: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        closeMenu(button);
        const page = self.private().page orelse return;
        const ptr = button.as(gobject.Object).getData("holoctty-tab-group") orelse
            return;
        const group: *TabGroup = @ptrCast(@alignCast(ptr));
        const view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse return;
        group.addPage(page, view);
        self.syncGroupStyle();
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
            win.syncTabGroups();
        }
    }

    fn menuRemoveGroup(
        button: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        closeMenu(button);
        const page = self.private().page orelse return;
        TabGroup.removePage(page);
        self.syncGroupStyle();
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
            win.syncTabGroups();
        }
    }

    fn tabMenuClosed(
        _: *gtk.Popover,
        popover: *gtk.Popover,
    ) callconv(.c) void {
        popover.as(gtk.Widget).unparent();
        popover.as(gobject.Object).unref();
    }

    fn updateProcessIcon(self: *Self) void {
        const state = self.detectProcessState();
        self.setProcessIcon(state.icon);
        self.setLocation(state);
        self.setRemoteHost(state.remoteHost());
        self.updateGitStatus(state);
    }

    /// Refresh live git counts for real GhosttyTab pages. The UI lab uses
    /// plain Gtk.Box fixture pages and owns their displayed status, so
    /// leave those fixture strings untouched.
    fn updateGitStatus(self: *Self, state: ProcessState) void {
        const page = self.private().page orelse return;
        if (gobject.ext.cast(Tab, page.getChild()) == null) return;

        if (state.remote) {
            self.setGitStatus("");
            return;
        }

        const pwd = self.locationPwd();
        if (pwd.len == 0 or !pathInGitRepo(pwd)) {
            self.setGitStatus("");
            return;
        }

        self.setGitStatus(git_status.statusForPwd(pwd) orelse "");
    }

    const ProcessState = cli_process.ProcessState;

    fn setRemoteHost(self: *Self, host: ?[]const u8) void {
        const priv = self.private();
        if (priv.remote_host) |current| {
            if (host) |value| {
                if (std.mem.eql(u8, current, value)) return;
            }
            glib.free(@ptrCast(@constCast(current)));
            priv.remote_host = null;
        } else if (host == null) return;

        if (host) |value| priv.remote_host = glib.ext.dupeZ(u8, value);
        self.as(gobject.Object).notifyByPspec(properties.@"remote-host".impl.param_spec);
    }

    pub fn setGitStatus(self: *Self, status: [:0]const u8) void {
        const priv = self.private();
        const parsed = parseGitStatus(status);
        setGitStatusLabel(priv.git_dirty, parsed.dirty);
        setGitStatusLabel(priv.git_staged, parsed.staged);
        setGitStatusLabel(priv.git_ahead, parsed.ahead);
        setGitStatusLabel(priv.git_behind, parsed.behind);

        if (priv.git_status) |current| {
            if (status.len > 0 and std.mem.eql(u8, current, status)) return;
            glib.free(@ptrCast(@constCast(current)));
            priv.git_status = null;
        } else if (status.len == 0) return;

        if (status.len > 0) priv.git_status = glib.ext.dupeZ(u8, status);
        self.as(gobject.Object).notifyByPspec(properties.@"git-status".impl.param_spec);
    }

    fn detectProcessState(self: *Self) ProcessState {
        if (comptime builtin.os.tag != .linux)
            return .{};

        const page = self.private().page orelse
            return .{};
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse
            return .{};
        const surface = tab.getActiveSurface() orelse
            return .{};
        const core = surface.core() orelse
            return .{};
        const pid = core.getProcessInfo(.foreground_pid) orelse
            return .{};

        return cli_process.processTreeState(pid, 0);
    }

    const iconForCommand = cli_process.iconForCommand;
    const iconForWrapperPath = cli_process.iconForWrapperPath;
    const processStateForCmdline = cli_process.processStateForCmdline;

    fn close(self: *Self) void {
        const page = self.private().page orelse return;
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse return;
        tab_view.closePage(page);
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
        // Snapshot this row only. The parent is the sidebar list, so
        // using it as the drag icon looks like every tab is moving.
        const preview_widget = widget;
        const width = preview_widget.getWidth();
        const height = preview_widget.getHeight();
        if (width > 0 and height > 0) {
            const widget_paintable = gtk.WidgetPaintable.new(preview_widget);
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
            if (priv.page) |page| _ = Window.moveTabPageToNewWindow(@intFromPtr(page));
        }

        active_drag_page = null;
        priv.drag_cancelled = false;
        priv.drag_drop_performed = false;
        priv.drag_torn_out = false;
        self.as(gtk.Widget).removeCssClass("dragging");
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
            win.syncTabGroups();
        }
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
        // user dropped the tab outside all windows. This covers both X11
        // (reason no_target) and Wayland (cancel following drop-performed).
        const dropped_outside = reason == .no_target or
            (reason == .@"error" and priv.drag_drop_performed);
        if (dropped_outside and !priv.drag_torn_out) {
            priv.drag_torn_out = true;
            if (priv.page) |page| {
                if (Window.moveTabPageToNewWindow(@intFromPtr(page)))
                    return @intFromBool(true);
            }
        }
        return @intFromBool(false);
    }

    fn reorderDragged(
        self: *Self,
        value: *const gobject.Value,
    ) void {
        const target = self.private().page orelse return;
        const view = ext.getAncestor(
            adw.TabView,
            target.getChild().as(gtk.Widget),
        ) orelse return;

        // Resolve the payload only against pages in this view. A DropTarget
        // can receive a matching integer type from another application, so
        // never dereference the payload as an arbitrary pointer.
        const dragged_id = value.getUint64();
        const dragged: *adw.TabPage = dragged: {
            var i: c_int = 0;
            while (i < view.getNPages()) : (i += 1) {
                const page = view.getNthPage(i);
                if (@intFromPtr(page) == dragged_id) break :dragged page;
            }
            return;
        };
        if (dragged == target) return;

        // Entering another row moves the dragged page directly to that row's
        // current position. This makes the rows exchange/reflow immediately,
        // matching the live behavior of AdwTabBar.
        _ = view.reorderPage(dragged, view.getPagePosition(target));
    }

    fn findPageByDragId(view: *adw.TabView, id: u64) ?*adw.TabPage {
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            const page = view.getNthPage(i);
            if (@intFromPtr(page) == id) return page;
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
        const id = value.getUint64();
        const target = self.private().page orelse return @intFromBool(false);
        const dest = ext.getAncestor(
            adw.TabView,
            target.getChild().as(gtk.Widget),
        ) orelse return @intFromBool(false);
        if (findPageByDragId(dest, id)) |dragged| {
            if (dragged != target) {
                _ = dest.reorderPage(dragged, dest.getPagePosition(target));
                TabGroup.applyDrop(dragged, target, dest);
            }
            if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
                win.syncTabGroups();
            }
            self.as(gtk.Widget).removeCssClass("drop-target");
            return @intFromBool(true);
        }
        if (Window.findTabGroup(id)) |group| {
            if (!group.swapWithPageInView(dest, target)) {
                group.moveInView(dest, dest.getPagePosition(target));
            }
            if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
                win.syncTabGroups();
            }
            self.as(gtk.Widget).removeCssClass("drop-target");
            return @intFromBool(true);
        }
        if (Window.findTabPage(id)) |found| {
            if (found.view == dest) {
                self.reorderDragged(value);
                TabGroup.applyDrop(found.page, target, dest);
            } else {
                TabGroup.splitOnTransfer(found.page, found.view);
                found.view.transferPage(
                    found.page,
                    dest,
                    dest.getPagePosition(target),
                );
                TabGroup.applyDrop(found.page, target, dest);
            }
            if (ext.getAncestor(Window, self.as(gtk.Widget))) |win| {
                win.syncTabGroups();
            }
            self.as(gtk.Widget).removeCssClass("drop-target");
            return @intFromBool(true);
        }
        const win = ext.getAncestor(Window, self.as(gtk.Widget)) orelse
            return @intFromBool(false);
        win.adoptDragIdAsTab(id, dest.getPagePosition(target));
        self.as(gtk.Widget).removeCssClass("drop-target");
        return @intFromBool(true);
    }

    fn tabDropMotion(
        tgt: *gtk.DropTarget,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) gdk.DragAction {
        const value = tgt.getValue() orelse return .{};
        const id = value.getUint64();
        const target = self.private().page orelse return .{};
        const view = ext.getAncestor(
            adw.TabView,
            target.getChild().as(gtk.Widget),
        ) orelse return .{};
        if (findPageByDragId(view, id) != null or
            Window.findSurfaceByDragId(id) != null or
            Window.findTabPage(id) != null or
            Window.findTabGroup(id) != null)
        {
            self.as(gtk.Widget).addCssClass("drop-target");
            return .{ .move = true };
        }
        return .{};
    }

    fn tabDropLeave(
        _: *gtk.DropTarget,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Widget).removeCssClass("drop-target");
    }

    fn closureTitleDisplay(
        _: *Self,
        title_: ?[*:0]const u8,
        _: *gobject.ParamSpec,
    ) callconv(.c) [*:0]const u8 {
        const title = if (title_) |value| std.mem.span(value) else "";
        var buf: [2048]u8 = undefined;
        return glib.ext.dupeZ(u8, gluePathBreaks(title, &buf));
    }

    fn closureDirectoryName(
        _: *Self,
        pwd_: ?[*:0]const u8,
        remote_host_: ?[*:0]const u8,
        _: *gobject.ParamSpec,
    ) callconv(.c) [*:0]const u8 {
        if (remote_host_) |remote_host|
            return glib.ext.dupeZ(u8, std.mem.span(remote_host));
        const pwd = if (pwd_) |pwd| std.mem.span(pwd) else "";
        const trimmed = std.mem.trimEnd(u8, pwd, "/");
        const name = if (trimmed.len == 0)
            if (pwd.len == 0) "Terminal" else "/"
        else
            std.fs.path.basename(trimmed);

        return glib.ext.dupeZ(u8, name);
    }

    fn closureContextLabel(
        _: *Self,
        pwd_: ?[*:0]const u8,
        _: *gobject.ParamSpec,
    ) callconv(.c) [*:0]const u8 {
        const pwd = if (pwd_) |value| std.mem.span(value) else "";
        var dir = std.mem.trimEnd(u8, pwd, "/");

        while (dir.len > 0) {
            var head_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const head_path = std.fmt.bufPrint(
                &head_path_buf,
                "{s}/.git/HEAD",
                .{dir},
            ) catch break;

            if (std.Io.Dir.openFileAbsolute(global.io(), head_path, .{})) |file| {
                defer file.close(global.io());

                var head_buf: [512]u8 = undefined;
                const size = file.readPositionalAll(
                    global.io(),
                    &head_buf,
                    0,
                ) catch break;
                const head = std.mem.trim(u8, head_buf[0..size], &std.ascii.whitespace);
                const prefix = "ref: refs/heads/";
                const branch = if (std.mem.startsWith(u8, head, prefix))
                    head[prefix.len..]
                else
                    head[0..@min(head.len, 8)];
                if (branch.len > 0) return glib.ext.dupeZ(u8, branch);
                break;
            } else |_| {}

            const parent = std.fs.path.dirname(dir) orelse break;
            if (std.mem.eql(u8, parent, dir)) break;
            dir = parent;
        }

        return glib.ext.dupeZ(u8, if (pwd.len > 0) pwd else "Terminal");
    }

    const GitStatus = struct {
        dirty: ?[]const u8 = null,
        staged: ?[]const u8 = null,
        ahead: ?[]const u8 = null,
        behind: ?[]const u8 = null,
    };

    /// Split the space-separated git status into one token per label.
    /// A dirty token is either a bare `*` or a `*` followed by a count.
    fn parseGitStatus(status: []const u8) GitStatus {
        var parsed = GitStatus{};
        var tokens = std.mem.tokenizeScalar(u8, status, ' ');
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "*") or
                std.mem.startsWith(u8, token, "*"))
            {
                parsed.dirty = token;
            } else if (std.mem.startsWith(u8, token, "+")) {
                parsed.staged = token;
            } else if (std.mem.startsWith(u8, token, "↑")) {
                parsed.ahead = token;
            } else if (std.mem.startsWith(u8, token, "↓")) {
                parsed.behind = token;
            }
        }
        return parsed;
    }

    fn setGitStatusLabel(label: *gtk.Label, token: ?[]const u8) void {
        if (token) |text| {
            const text_z = glib.ext.dupeZ(u8, text);
            defer glib.free(@ptrCast(@constCast(text_z)));
            label.setLabel(text_z);
        } else {
            label.setLabel("");
        }
        label.as(gtk.Widget).setVisible(@intFromBool(token != null));
    }

    fn closureGitStatusVisible(
        _: *Self,
        status_: ?[*:0]const u8,
    ) callconv(.c) c_int {
        const status = status_ orelse return @intFromBool(false);
        return @intFromBool(std.mem.span(status).len > 0);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.process_icon_timer) |timer| {
            _ = glib.Source.remove(timer);
            priv.process_icon_timer = null;
        }
        if (priv.selected_page) |page| {
            if (priv.selected_handler != 0) {
                gobject.signalHandlerDisconnect(
                    page.as(gobject.Object),
                    priv.selected_handler,
                );
            }
            if (priv.title_handler != 0) {
                gobject.signalHandlerDisconnect(
                    page.as(gobject.Object),
                    priv.title_handler,
                );
            }
            priv.selected_handler = 0;
            priv.title_handler = 0;
            priv.selected_page = null;
        }
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

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.process_icon) |icon| {
            glib.free(@ptrCast(@constCast(icon)));
            priv.process_icon = null;
        }
        if (priv.process_name) |name| {
            glib.free(@ptrCast(@constCast(name)));
            priv.process_name = null;
        }
        if (priv.location_icon) |icon| glib.free(@ptrCast(@constCast(icon)));
        if (priv.location_name) |name| glib.free(@ptrCast(@constCast(name)));
        if (priv.remote_host) |host| glib.free(@ptrCast(@constCast(host)));
        if (priv.git_status) |status| glib.free(@ptrCast(@constCast(status)));
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
                    .name = "vertical-tab",
                }),
            );

            class.bindTemplateCallback("title_display", &closureTitleDisplay);
            class.bindTemplateCallback("directory_name", &closureDirectoryName);
            class.bindTemplateCallback("context_label", &closureContextLabel);
            class.bindTemplateCallback("git_status_visible", &closureGitStatusVisible);
            class.bindTemplateCallback("middle_click", &middleClick);
            class.bindTemplateCallback("select_tab", &selectTab);
            class.bindTemplateCallback("context_menu", &contextMenu);
            class.bindTemplateCallback("tab_drag_prepare", &tabDragPrepare);
            class.bindTemplateCallback("tab_drag_begin", &tabDragBegin);
            class.bindTemplateCallback("tab_drag_end", &tabDragEnd);
            class.bindTemplateCallback("tab_drag_cancel", &tabDragCancel);
            class.bindTemplateCallback("tab_drop", &tabDrop);
            class.bindTemplateCallback("tab_drop_motion", &tabDropMotion);
            class.bindTemplateCallback("tab_drop_leave", &tabDropLeave);
            class.bindTemplateCallback("notify_page", &propPage);

            class.bindTemplateChildPrivate("tab_drop_target", .{});
            class.bindTemplateChildPrivate("meta_revealer", .{});
            class.bindTemplateChildPrivate("footer_revealer", .{});
            class.bindTemplateChildPrivate("git_status_box", .{});
            class.bindTemplateChildPrivate("git_dirty", .{});
            class.bindTemplateChildPrivate("git_staged", .{});
            class.bindTemplateChildPrivate("git_ahead", .{});
            class.bindTemplateChildPrivate("git_behind", .{});
            class.bindTemplateChildPrivate("title_label", .{});
            class.bindTemplateChildPrivate("location_theme_icon", .{});
            class.bindTemplateChildPrivate("location_file_icon", .{});

            gobject.ext.registerProperties(class, &.{
                properties.page.impl,
                properties.@"process-icon".impl,
                properties.@"process-name".impl,
                properties.@"location-icon".impl,
                properties.@"location-name".impl,
                properties.@"remote-host".impl,
                properties.@"git-status".impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};

test "vertical tab path titles stay on one line" {
    try std.testing.expect(VerticalTab.titleIsPath("/home/sfire/Projects/holoctty"));
    try std.testing.expect(VerticalTab.titleIsPath("~/src/foo"));
    try std.testing.expect(VerticalTab.titleIsPath("src/apprt/gtk/vertical_tab.zig"));
    try std.testing.expect(VerticalTab.titleIsPath("./build.zig"));
    try std.testing.expect(!VerticalTab.titleIsPath("nvim src/foo.zig"));
    try std.testing.expect(!VerticalTab.titleIsPath("Codex"));
    try std.testing.expect(!VerticalTab.titleIsPath("VeryLongTitleWithoutSlashes"));

    var buf: [64]u8 = undefined;
    const glued = VerticalTab.gluePathBreaks("nvim /home/foo", &buf);
    try std.testing.expectEqualStrings("nvim /\u{2060}home/\u{2060}foo", glued);
}

test "git status helper is process-free in tests" {
    // The live path must never spawn `git` from a test process.
    try std.testing.expectEqualStrings("", git_status.statusForPwd("") orelse "");
}

test "vertical tab maps foreground CLI icons" {
    {
        const parsed = VerticalTab.parseGitStatus("*5 +2 ↑1");
        try std.testing.expectEqualStrings("*5", parsed.dirty.?);
        try std.testing.expectEqualStrings("+2", parsed.staged.?);
        try std.testing.expectEqualStrings("↑1", parsed.ahead.?);
        try std.testing.expect(parsed.behind == null);
    }
    {
        const parsed = VerticalTab.parseGitStatus("↓2");
        try std.testing.expect(parsed.dirty == null);
        try std.testing.expect(parsed.staged == null);
        try std.testing.expect(parsed.ahead == null);
        try std.testing.expectEqualStrings("↓2", parsed.behind.?);
    }
    {
        const parsed = VerticalTab.parseGitStatus("");
        try std.testing.expect(parsed.dirty == null);
        try std.testing.expect(parsed.staged == null);
        try std.testing.expect(parsed.ahead == null);
        try std.testing.expect(parsed.behind == null);
    }
    {
        const parsed = VerticalTab.parseGitStatus("*");
        try std.testing.expectEqualStrings("*", parsed.dirty.?);
        try std.testing.expect(parsed.staged == null);
        try std.testing.expect(parsed.ahead == null);
        try std.testing.expect(parsed.behind == null);
    }

    try std.testing.expectEqualStrings(
        "holoctty-cli-agent-codex-symbolic",
        VerticalTab.iconForCommand("codex").?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-agent-claude-symbolic",
        VerticalTab.iconForWrapperPath(
            "/opt/node_modules/@anthropic-ai/claude-code/cli.js",
        ).?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-agent-opencode-symbolic",
        VerticalTab.iconForCommand("opencode2").?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-agent-pi-symbolic",
        VerticalTab.iconForCommand("pi").?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-agent-omp-symbolic",
        VerticalTab.iconForCommand("omp").?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-agent-omp-symbolic",
        VerticalTab.iconForWrapperPath(
            "/home/user/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js",
        ).?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-agent-devin-symbolic",
        VerticalTab.iconForCommand("devin").?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-agent-devin-symbolic",
        VerticalTab.iconForWrapperPath(
            "/home/user/.local/share/devin/cli/_versions/current/bin/devin",
        ).?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-agent-aider-symbolic",
        VerticalTab.iconForCommand("aider").?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-agent-goose-symbolic",
        VerticalTab.iconForCommand("goose").?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-agent-crush-symbolic",
        VerticalTab.iconForCommand("crush").?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-agent-hermes-symbolic",
        VerticalTab.iconForCommand("hermes").?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-agent-hermes-symbolic",
        VerticalTab.iconForWrapperPath(
            "/home/user/.hermes/hermes-agent/run_agent.py",
        ).?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-shell-zsh-symbolic",
        VerticalTab.iconForCommand("zsh").?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-tui-btop-symbolic",
        VerticalTab.iconForCommand("htop").?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-tui-lazygit-symbolic",
        VerticalTab.iconForCommand("lazygit").?,
    );
    try std.testing.expectEqualStrings(
        "holoctty-cli-tui-nvim-symbolic",
        VerticalTab.iconForCommand("nvim").?,
    );
    try std.testing.expect(VerticalTab.iconForCommand("unknown-binary-xyz") == null);

    // Git repo detection walks ancestors for a `.git` entry.
    try std.testing.expect(!VerticalTab.pathInGitRepo(""));
    try std.testing.expect(!VerticalTab.pathInGitRepo("/proc"));
    {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "project/src");
        try tmp.dir.writeFile(io, .{
            .sub_path = "project/.git",
            .data = "gitdir: /tmp/fake\n",
        });

        var project_buf: [std.fs.max_path_bytes]u8 = undefined;
        const project = project_buf[0..try tmp.dir.realPathFile(io, "project", &project_buf)];
        var nested_buf: [std.fs.max_path_bytes]u8 = undefined;
        const nested = nested_buf[0..try tmp.dir.realPathFile(io, "project/src", &nested_buf)];
        try std.testing.expect(VerticalTab.pathInGitRepo(project));
        try std.testing.expect(VerticalTab.pathInGitRepo(nested));
    }

    const remote_grok = VerticalTab.processStateForCmdline("ssh\x00-p\x002222\x00user@server\x00grok\x00");
    try std.testing.expect(remote_grok.remote);
    try std.testing.expectEqualStrings("holoctty-cli-agent-grok-symbolic", remote_grok.icon);
    try std.testing.expectEqualStrings("server", remote_grok.remoteHost().?);

    const remote_bash = VerticalTab.processStateForCmdline("ssh\x00server\x00bash\x00");
    try std.testing.expect(remote_bash.remote);
    try std.testing.expectEqualStrings("holoctty-cli-shell-bash-symbolic", remote_bash.icon);

    const remote_devin = VerticalTab.processStateForCmdline("ssh\x00user@box\x00devin\x00");
    try std.testing.expect(remote_devin.remote);
    try std.testing.expectEqualStrings("holoctty-cli-agent-devin-symbolic", remote_devin.icon);

    const quoted_remote = VerticalTab.processStateForCmdline("ssh\x00server\x00grok --resume\x00");
    try std.testing.expectEqualStrings("holoctty-cli-agent-grok-symbolic", quoted_remote.icon);

    const interactive_ssh = VerticalTab.processStateForCmdline("ssh\x00server\x00");
    try std.testing.expect(interactive_ssh.remote);
    try std.testing.expectEqualStrings("utilities-terminal-symbolic", interactive_ssh.icon);
}
