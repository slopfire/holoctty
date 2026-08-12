const std = @import("std");
const builtin = @import("builtin");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const global = @import("../../../global.zig");
const Tab = @import("tab.zig").Tab;

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
        process_icon_timer: ?c_uint = null,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        var drop_types = [_]gobject.Type{gobject.ext.types.uint64};
        self.private().tab_drop_target.setGtypes(&drop_types, drop_types.len);
        self.setProcessIcon("utilities-terminal-symbolic");
        self.setLocation(false);
        self.private().process_icon_timer = glib.timeoutAdd(
            1_000,
            processIconTimer,
            self,
        );
    }

    fn setLocation(self: *Self, remote: bool) void {
        const icon: [:0]const u8 = if (remote)
            "holoctty-cli-remote-server-symbolic"
        else
            "folder-symbolic";
        const name: [:0]const u8 = if (remote) "Remote Session" else "Local Folder";
        const priv = self.private();
        if (priv.location_icon) |current| {
            if (std.mem.eql(u8, current, icon)) return;
            glib.free(@ptrCast(@constCast(current)));
            glib.free(@ptrCast(@constCast(priv.location_name.?)));
        }
        priv.location_icon = glib.ext.dupeZ(u8, icon);
        priv.location_name = glib.ext.dupeZ(u8, name);
        self.as(gobject.Object).notifyByPspec(properties.@"location-icon".impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"location-name".impl.param_spec);
    }

    fn setProcessIcon(self: *Self, icon: [:0]const u8) void {
        const priv = self.private();
        if (priv.process_icon) |current| {
            if (std.mem.eql(u8, current, icon)) return;
            glib.free(@ptrCast(@constCast(current)));
        }

        priv.process_icon = glib.ext.dupeZ(u8, icon);
        if (priv.process_name) |name| glib.free(@ptrCast(@constCast(name)));
        priv.process_name = glib.ext.dupeZ(u8, processName(icon));
        self.as(gobject.Object).notifyByPspec(
            properties.@"process-icon".impl.param_spec,
        );
        self.as(gobject.Object).notifyByPspec(
            properties.@"process-name".impl.param_spec,
        );
    }

    fn processName(icon: []const u8) [:0]const u8 {
        const mappings = [_]struct {
            icon: []const u8,
            name: [:0]const u8,
        }{
            .{ .icon = "holoctty-cli-agent-codex-symbolic", .name = "Codex" },
            .{ .icon = "holoctty-cli-agent-claude-symbolic", .name = "Claude" },
            .{ .icon = "holoctty-cli-agent-gemini-symbolic", .name = "Gemini" },
            .{ .icon = "holoctty-cli-agent-opencode-symbolic", .name = "OpenCode" },
            .{ .icon = "holoctty-cli-agent-grok-symbolic", .name = "Grok" },
            .{ .icon = "holoctty-cli-agent-cursor-symbolic", .name = "Cursor" },
            .{ .icon = "holoctty-cli-agent-copilot-symbolic", .name = "Copilot" },
            .{ .icon = "holoctty-cli-agent-amp-symbolic", .name = "Amp" },
            .{ .icon = "holoctty-cli-shell-bash-symbolic", .name = "Bash" },
            .{ .icon = "holoctty-cli-shell-zsh-symbolic", .name = "Zsh" },
            .{ .icon = "holoctty-cli-shell-fish-symbolic", .name = "Fish" },
            .{ .icon = "holoctty-cli-shell-nushell-symbolic", .name = "Nushell" },
            .{ .icon = "holoctty-cli-shell-powershell-symbolic", .name = "PowerShell" },
        };
        for (mappings) |mapping| {
            if (std.mem.eql(u8, icon, mapping.icon)) return mapping.name;
        }
        return "Terminal";
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
        self.updateProcessIcon();
    }

    fn updateProcessIcon(self: *Self) void {
        const state = self.detectProcessState();
        self.setProcessIcon(state.icon);
        self.setLocation(state.remote);
        self.setRemoteHost(state.remoteHost());
    }

    const ProcessState = struct {
        icon: [:0]const u8 = "utilities-terminal-symbolic",
        remote: bool = false,
        host: [256]u8 = undefined,
        host_len: usize = 0,

        fn remoteHost(self: *const ProcessState) ?[]const u8 {
            return if (self.host_len > 0) self.host[0..self.host_len] else null;
        }
    };

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

        return processTreeState(pid, 0);
    }

    fn processTreeState(pid: u64, depth: u8) ProcessState {
        const state = processStateForPid(pid);
        if (state.remote) return state;

        // The shell integration wraps SSH as `holoctty +ssh`, so the PTY
        // foreground process can be the wrapper while ssh is its child.
        // Inspect descendants before falling back to the wrapper's icon.
        if (depth < 4) {
            var children_buf: [1024]u8 = undefined;
            if (readProcChildren(pid, &children_buf)) |children_raw| {
                var children = std.mem.tokenizeAny(u8, children_raw, &std.ascii.whitespace);
                while (children.next()) |child_raw| {
                    const child_pid = std.fmt.parseInt(u64, child_raw, 10) catch continue;
                    const child_state = processTreeState(child_pid, depth + 1);
                    if (child_state.remote) return child_state;
                    if (!std.mem.eql(u8, child_state.icon, "utilities-terminal-symbolic"))
                        return child_state;
                }
            }
        }

        return state;
    }

    fn processStateForPid(pid: u64) ProcessState {
        var cmdline_buf: [4096]u8 = undefined;
        const cmdline = readProcFile(pid, "cmdline", &cmdline_buf) orelse "";
        const state = processStateForCmdline(cmdline);
        if (state.remote or !std.mem.eql(u8, state.icon, "utilities-terminal-symbolic"))
            return state;

        var comm_buf: [256]u8 = undefined;
        if (readProcFile(pid, "comm", &comm_buf)) |comm_raw| {
            const comm = std.mem.trim(u8, comm_raw, &std.ascii.whitespace);
            if (iconForCommand(comm)) |icon| return .{ .icon = icon };
        }
        return state;
    }

    fn readProcChildren(pid: u64, buf: []u8) ?[]const u8 {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "task/{d}/children", .{pid}) catch
            return null;
        return readProcFile(pid, name, buf);
    }

    fn processStateForCmdline(cmdline: []const u8) ProcessState {
        var args = std.mem.splitScalar(u8, cmdline, 0);
        const argv0 = args.next() orelse "";
        const command = std.fs.path.basename(argv0);
        if (isRemoteClient(command)) return remoteProcessState(args);
        if (iconForCommand(command)) |icon| return .{ .icon = icon };

        if (isRuntime(command)) {
            if (args.next()) |script| {
                if (iconForWrapperPath(script)) |icon| return .{ .icon = icon };
            }
        }
        return .{};
    }

    fn isRemoteClient(command: []const u8) bool {
        return std.ascii.eqlIgnoreCase(command, "ssh") or
            std.ascii.eqlIgnoreCase(command, "mosh");
    }

    fn remoteProcessState(args: anytype) ProcessState {
        var iterator = args;
        var destination_seen = false;
        var skip_option_value = false;
        var state: ProcessState = .{ .remote = true };
        while (iterator.next()) |arg| {
            if (arg.len == 0) continue;
            if (skip_option_value) {
                skip_option_value = false;
                continue;
            }
            if (!destination_seen) {
                if (std.mem.eql(u8, arg, "--")) continue;
                if (arg[0] == '-') {
                    if (sshOptionNeedsValue(arg)) skip_option_value = true;
                    continue;
                }
                destination_seen = true;
                const at = std.mem.lastIndexOfScalar(u8, arg, '@');
                const host = if (at) |index| arg[index + 1 ..] else arg;
                const len = @min(host.len, state.host.len);
                @memcpy(state.host[0..len], host[0..len]);
                state.host_len = len;
                continue;
            }
            var words = std.mem.tokenizeAny(u8, arg, &std.ascii.whitespace);
            const command = std.fs.path.basename(words.next() orelse arg);
            if (iconForCommand(command)) |icon| state.icon = icon;
            if (iconForWrapperPath(arg)) |icon| state.icon = icon;
            return state;
        }
        return state;
    }

    fn sshOptionNeedsValue(arg: []const u8) bool {
        if (arg.len != 2) return false;
        return std.mem.indexOfScalar(u8, "bcDEeFIiJLlmOoPpQRSWw", arg[1]) != null;
    }

    fn readProcFile(
        pid: u64,
        name: []const u8,
        buf: []u8,
    ) ?[]const u8 {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/proc/{d}/{s}",
            .{ pid, name },
        ) catch return null;
        var file = std.Io.Dir.openFileAbsolute(global.io(), path, .{}) catch
            return null;
        defer file.close(global.io());
        const size = file.readPositionalAll(global.io(), buf, 0) catch
            return null;
        return buf[0..size];
    }

    fn iconForCommand(command: []const u8) ?[:0]const u8 {
        const mappings = [_]struct {
            names: []const []const u8,
            icon: [:0]const u8,
        }{
            .{ .names = &.{ "codex", "codex-cli" }, .icon = "holoctty-cli-agent-codex-symbolic" },
            .{ .names = &.{"claude"}, .icon = "holoctty-cli-agent-claude-symbolic" },
            .{ .names = &.{ "gemini", "gemini-cli" }, .icon = "holoctty-cli-agent-gemini-symbolic" },
            .{ .names = &.{ "opencode", "opencode2" }, .icon = "holoctty-cli-agent-opencode-symbolic" },
            .{ .names = &.{"grok"}, .icon = "holoctty-cli-agent-grok-symbolic" },
            .{ .names = &.{ "cursor", "cursor-agent" }, .icon = "holoctty-cli-agent-cursor-symbolic" },
            .{ .names = &.{ "copilot", "github-copilot" }, .icon = "holoctty-cli-agent-copilot-symbolic" },
            .{ .names = &.{"amp"}, .icon = "holoctty-cli-agent-amp-symbolic" },
            .{ .names = &.{"bash"}, .icon = "holoctty-cli-shell-bash-symbolic" },
            .{ .names = &.{"zsh"}, .icon = "holoctty-cli-shell-zsh-symbolic" },
            .{ .names = &.{"fish"}, .icon = "holoctty-cli-shell-fish-symbolic" },
            .{ .names = &.{ "nu", "nushell" }, .icon = "holoctty-cli-shell-nushell-symbolic" },
            .{ .names = &.{ "pwsh", "powershell" }, .icon = "holoctty-cli-shell-powershell-symbolic" },
        };

        for (mappings) |mapping| {
            for (mapping.names) |name| {
                if (std.ascii.eqlIgnoreCase(command, name)) return mapping.icon;
            }
        }
        return null;
    }

    fn isRuntime(command: []const u8) bool {
        const runtimes = [_][]const u8{
            "node", "nodejs", "bun", "deno", "python", "python3",
        };
        for (runtimes) |runtime| {
            if (std.ascii.eqlIgnoreCase(command, runtime)) return true;
        }
        return false;
    }

    fn iconForWrapperPath(path: []const u8) ?[:0]const u8 {
        const mappings = [_]struct {
            needle: []const u8,
            icon: [:0]const u8,
        }{
            .{ .needle = "@openai/codex", .icon = "holoctty-cli-agent-codex-symbolic" },
            .{ .needle = "/codex/", .icon = "holoctty-cli-agent-codex-symbolic" },
            .{ .needle = "@anthropic-ai/claude", .icon = "holoctty-cli-agent-claude-symbolic" },
            .{ .needle = "/claude-code/", .icon = "holoctty-cli-agent-claude-symbolic" },
            .{ .needle = "@google/gemini", .icon = "holoctty-cli-agent-gemini-symbolic" },
            .{ .needle = "/opencode/", .icon = "holoctty-cli-agent-opencode-symbolic" },
            .{ .needle = "/opencode2/", .icon = "holoctty-cli-agent-opencode-symbolic" },
            .{ .needle = "/grok/", .icon = "holoctty-cli-agent-grok-symbolic" },
            .{ .needle = "/cursor-agent/", .icon = "holoctty-cli-agent-cursor-symbolic" },
            .{ .needle = "/copilot/", .icon = "holoctty-cli-agent-copilot-symbolic" },
            .{ .needle = "/amp/", .icon = "holoctty-cli-agent-amp-symbolic" },
        };
        for (mappings) |mapping| {
            if (std.mem.indexOf(u8, path, mapping.needle) != null)
                return mapping.icon;
        }
        return null;
    }

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
        _: *gdk.Drag,
        self: *Self,
    ) callconv(.c) void {
        active_drag_page = self.private().page;
        const widget = self.as(gtk.Widget);
        const preview_widget = widget.getParent() orelse widget;
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

    fn tabDrop(
        _: *gtk.DropTarget,
        value: *const gobject.Value,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        self.reorderDragged(value);
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

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.process_icon_timer) |timer| {
            _ = glib.Source.remove(timer);
            priv.process_icon_timer = null;
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

            class.bindTemplateCallback("directory_name", &closureDirectoryName);
            class.bindTemplateCallback("context_label", &closureContextLabel);
            class.bindTemplateCallback("middle_click", &middleClick);
            class.bindTemplateCallback("tab_drag_prepare", &tabDragPrepare);
            class.bindTemplateCallback("tab_drag_begin", &tabDragBegin);
            class.bindTemplateCallback("tab_drag_end", &tabDragEnd);
            class.bindTemplateCallback("tab_drop", &tabDrop);
            class.bindTemplateCallback("notify_page", &propPage);

            class.bindTemplateChildPrivate("tab_drop_target", .{});

            gobject.ext.registerProperties(class, &.{
                properties.page.impl,
                properties.@"process-icon".impl,
                properties.@"process-name".impl,
                properties.@"location-icon".impl,
                properties.@"location-name".impl,
                properties.@"remote-host".impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};

test "vertical tab maps foreground CLI icons" {
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
        "holoctty-cli-shell-zsh-symbolic",
        VerticalTab.iconForCommand("zsh").?,
    );
    try std.testing.expect(VerticalTab.iconForCommand("htop") == null);

    const remote_grok = VerticalTab.processStateForCmdline("ssh\x00-p\x002222\x00user@server\x00grok\x00");
    try std.testing.expect(remote_grok.remote);
    try std.testing.expectEqualStrings("holoctty-cli-agent-grok-symbolic", remote_grok.icon);
    try std.testing.expectEqualStrings("server", remote_grok.remoteHost().?);

    const remote_bash = VerticalTab.processStateForCmdline("ssh\x00server\x00bash\x00");
    try std.testing.expect(remote_bash.remote);
    try std.testing.expectEqualStrings("holoctty-cli-shell-bash-symbolic", remote_bash.icon);

    const quoted_remote = VerticalTab.processStateForCmdline("ssh\x00server\x00grok --resume\x00");
    try std.testing.expectEqualStrings("holoctty-cli-agent-grok-symbolic", quoted_remote.icon);

    const interactive_ssh = VerticalTab.processStateForCmdline("ssh\x00server\x00");
    try std.testing.expect(interactive_ssh.remote);
    try std.testing.expectEqualStrings("utilities-terminal-symbolic", interactive_ssh.icon);
}
